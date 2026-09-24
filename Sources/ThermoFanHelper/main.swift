import Darwin
import FanControlEngine
import FanControlXPC
import Foundation
import Security
import SystemConfiguration

private struct EngineIdentity: Sendable, Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    init?(_ pid: pid_t) {
        var value = ThermoFanProcessIdentity()
        guard thermofan_engine_read_process_identity(pid, &value) == 0 else {
            return nil
        }
        self.pid = value.pid
        self.startSeconds = value.start_seconds
        self.startMicroseconds = value.start_microseconds
    }

    var cValue: ThermoFanProcessIdentity {
        ThermoFanProcessIdentity(
            pid: pid,
            start_seconds: startSeconds,
            start_microseconds: startMicroseconds
        )
    }
}

private struct PeerMetadata: Sendable {
    /// Monotonic per-daemon connection sequence number; a larger value is a
    /// newer connection. It lets a reconnecting process replace its own stale
    /// lease instead of being rejected by it.
    let connectionID: UInt64
    let identity: EngineIdentity
    let userID: uid_t
    let auditSessionID: au_asid_t
}

private struct ActiveSession {
    let peer: PeerMetadata
    var armedMask: UInt32
    var lastHeartbeat: ContinuousClock.Instant
    var lastRevision: UInt64
    var lastManualApply: [Int: ContinuousClock.Instant]
    var processWatchDescriptor: Int32
    var processWatchSource: (any DispatchSourceRead)?
}

/// Lock-protected copy of the state the side-effect-free handshakes report,
/// so they never wait behind a long SMC transaction on the coordinator queue.
private struct HandshakeSnapshot: Sendable {
    var startupStatus: Int
    var retiring: Bool
    var shuttingDown: Bool
    var hasSession: Bool
}

/// Owns every lease, recovery, and hardware transaction. The startup barrier,
/// all state-mutating RPCs, the health timer, process-exit watches, and
/// shutdown run on one serial queue. Only `handshake` and `recoveryHandshake`
/// answer off-queue, from `HandshakeSnapshot`; every write re-validates on the
/// queue.
///
/// Reply statuses: 0 success; 1 generic failure, protocol mismatch, or
/// shutdown in progress; 75 recovery required (writes blocked until the
/// recovery supervisor verifies Auto); 76 the daemon ended the caller's lease
/// (heartbeat expiry, console change, unverified write, a newer connection
/// from the same process, or service removal requested by another
/// connection); 77 the caller is not the active local graphical console user;
/// 78 Auto was verified for service removal and writes are refused until the
/// daemon is unregistered (or the retirement lapses).
private final class DaemonCoordinator: @unchecked Sendable {
    typealias StatusReply = @Sendable (Int, String) -> Void
    typealias HandshakeReply = @Sendable (Int, Int, Int, String) -> Void

    private enum SessionAccess {
        /// The caller's connection holds the active lease.
        case owner(ActiveSession)
        /// No lease is active and the caller has no pending lease-ended notice.
        case unowned
        /// The daemon ended this connection's lease; the notice is consumed.
        case leaseEnded(reason: String)
        /// Another process identity, or a newer connection of the caller's
        /// process, holds the lease.
        case otherOwner
        /// Recovering the superseded lease of the caller's own process could
        /// not be verified; writes are now blocked.
        case takeoverFailed
    }

    /// A retirement that the client never completes by unregistering the
    /// daemon lapses after this long, and normal service resumes.
    private static let retiringTimeout: Duration = .seconds(60)
    private static let legacyCheckInterval: Duration = .seconds(30)
    private static let endedLeaseNoticeLimit = 16
    /// The four exact paths `thermofan_engine_remove_legacy_helpers` retires.
    private static let legacyHelperPaths = [
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version"
    ]
    private static let shuttingDownMessage =
        "The Hardware Helper is shutting down and returning ThermoFan-owned fans to automatic control."
    private static let takeoverFailedMessage =
        "The previous watchdog lease of this ThermoFan process could not be verified back in automatic control; privileged control remains blocked."
    private static let noLeaseMessage =
        "Manual fan control was blocked because this connection no longer has a verified watchdog lease."
    private static let recoveryFailedMessage =
        "The fan write failed and automatic rollback could not be verified. Recovery remains active."

    private let queue = DispatchQueue(label: "io.github.girginomer10.ThermoFan.helper.engine")
    private let clock = ContinuousClock()
    private let healthTimer: DispatchSourceTimer

    // Guarded by `sharedStateLock`. Written only from `queue` (snapshot) or
    // the listener (connection IDs); read off-queue by the handshakes.
    private let sharedStateLock = NSLock()
    private var snapshot = HandshakeSnapshot(
        startupStatus: ThermoFanXPC.recoveryRequiredStatus,
        retiring: false,
        shuttingDown: false,
        hasSession: false
    )
    private var lastConnectionID: UInt64 = 0

    // Everything below is owned by `queue`.
    private var session: ActiveSession? = nil {
        didSet {
            if (oldValue == nil) != (session == nil) {
                publishSnapshot()
            }
        }
    }
    /// Starts blocked. Only the full startup barrier (`runStartupBarrier` or
    /// `retryStartupBoundary`) returns it to 0, because only that path
    /// re-opens the engine's manual-write gate.
    private var startupStatus = ThermoFanXPC.recoveryRequiredStatus {
        didSet {
            if oldValue != startupStatus {
                publishSnapshot()
            }
        }
    }
    private var shuttingDown = false {
        didSet { publishSnapshot() }
    }
    /// Non-nil while retiring: set only after `prepareForServiceRemoval`
    /// verified Auto; cleared by a verified recovery retry, a failed removal
    /// preparation, or `retiringTimeout`.
    private var retiringSince: ContinuousClock.Instant? = nil {
        didSet { publishSnapshot() }
    }
    /// One-shot lease-ended (76) notices for connections whose lease the
    /// daemon ended on its own. Removed when delivered or when the
    /// connection ends.
    private var endedLeaseNotices: [UInt64: String] = [:]
    private var startupComplete = false
    private var recoveryAttempts = 0
    private var nextRecoveryAttempt: ContinuousClock.Instant?
    private var nextLegacyCheck: ContinuousClock.Instant?

    private var retiring: Bool { retiringSince != nil }

    init() {
        healthTimer = DispatchSource.makeTimerSource(queue: queue)
        healthTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        healthTimer.setEventHandler { [weak self] in
            self?.performHealthCheck()
        }
        // The handler is inert until the startup barrier completes, which
        // also keeps a mis-signed binary from reaching legacy cleanup.
        healthTimer.activate()
    }

    func nextConnectionID() -> UInt64 {
        sharedStateLock.lock()
        defer { sharedStateLock.unlock() }
        lastConnectionID &+= 1
        return lastConnectionID
    }

    /// Runs the fail-closed startup barrier on the coordinator queue, so a
    /// SIGTERM/SIGINT shutdown requested meanwhile is serialized around it.
    /// Returns the client code-signing requirement. A helper that is not
    /// Developer ID signed exits with 78 only after durable ownership was
    /// recovered; that recovery only ever sets Auto.
    func runStartupBarrier() -> String {
        queue.sync {
            let recoveryStatus = Int(thermofan_engine_recover_startup())
            guard let requirement = ThermoFanXPC.peerRequirement(
                identifier: ThermoFanXPC.appIdentifier,
                currentIdentifier: ThermoFanXPC.helperIdentifier
            ) else {
                if recoveryStatus != 0 {
                    fputs("ThermoFanHelper: startup recovery of durable fan ownership remains unverified.\n", stderr)
                }
                fputs("ThermoFanHelper requires a Developer ID Application signature; ad-hoc builds remain monitoring-only.\n", stderr)
                exit(78)
            }
            var status = recoveryStatus == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus
            if status == 0, thermofan_engine_remove_legacy_helpers() != 0 {
                // A known setuid v8 binary would preserve the bypassed CLI surface.
                // Keep all new manual writes blocked until it is safely gone.
                status = ThermoFanXPC.recoveryRequiredStatus
            }
            startupStatus = status
            if status != 0 {
                recoveryAttempts = 1
                scheduleNextRecoveryAttempt()
            }
            nextLegacyCheck = clock.now.advanced(by: Self.legacyCheckInterval)
            startupComplete = true
            return requirement
        }
    }

    /// Side-effect free and answered from the snapshot without waiting on the
    /// queue, so a client's bounded handshake never times out behind a long
    /// engine transaction.
    func handshake(
        peer: PeerMetadata,
        protocolVersion: Int,
        reply: HandshakeReply
    ) {
        let installedProtocol = ThermoFanXPC.protocolVersion
        let revision = ThermoFanXPC.implementationRevision
        guard protocolVersion == installedProtocol else {
            reply(
                installedProtocol,
                revision,
                1,
                "The app and Hardware Helper protocols do not match. Update ThermoFan before controlling fans."
            )
            return
        }
        let state = currentSnapshot()
        guard !state.shuttingDown else {
            reply(installedProtocol, revision, 1, Self.shuttingDownMessage)
            return
        }
        // Checked before recovery state so a background login session learns
        // it is inactive rather than being offered a recovery it cannot run.
        guard Self.peerIsCurrentConsoleUser(peer) else {
            reply(
                installedProtocol,
                revision,
                ThermoFanXPC.notConsoleUserStatus,
                "Privileged fan control is restricted to the active local console user."
            )
            return
        }
        guard state.startupStatus == 0 else {
            reply(
                installedProtocol,
                revision,
                ThermoFanXPC.recoveryRequiredStatus,
                "The Hardware Helper is blocked until durable fan ownership can be recovered safely."
            )
            return
        }
        guard !state.retiring else {
            reply(
                installedProtocol,
                revision,
                ThermoFanXPC.retiringStatus,
                "The Hardware Helper verified automatic control and is waiting to be unregistered; fan writes are refused."
            )
            return
        }
        reply(
            installedProtocol,
            revision,
            0,
            state.hasSession
                ? "Authenticated Hardware Helper protocol is ready; a fan-control watchdog lease is active."
                : "Authenticated Hardware Helper protocol is ready."
        )
    }

    func arm(
        peer: PeerMetadata,
        protocolVersion: Int,
        fanIndex: Int,
        reply: @escaping StatusReply
    ) {
        queue.async {
            if let failure = self.validationFailure(peer: peer, protocolVersion: protocolVersion) {
                reply(failure.status, failure.message)
                return
            }
            guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex) else {
                reply(1, "The Hardware Helper rejected an invalid fan index.")
                return
            }

            switch self.sessionAccess(for: peer) {
            case .takeoverFailed:
                reply(ThermoFanXPC.recoveryRequiredStatus, Self.takeoverFailedMessage)
                return
            case .leaseEnded(let reason):
                // Deliver the notice before a new lease so the client
                // reconciles every fan it still believes is leased.
                reply(ThermoFanXPC.leaseLostStatus, Self.leaseEndedMessage(reason))
                return
            case .otherOwner:
                reply(1, "Fan control is already owned by another authenticated ThermoFan session.")
                return
            case .owner:
                break
            case .unowned:
                var identity = peer.identity.cValue
                let descriptor = thermofan_engine_open_process_exit_watch(&identity)
                guard descriptor >= 0 else {
                    reply(1, "The Hardware Helper could not arm its process-exit watchdog. No hardware write was attempted.")
                    return
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
                let connectionID = peer.connectionID
                source.setEventHandler { [weak self] in
                    self?.processExitWatchFired(connectionID: connectionID)
                }
                source.setCancelHandler {
                    Darwin.close(descriptor)
                }
                self.session = ActiveSession(
                    peer: peer,
                    armedMask: 0,
                    lastHeartbeat: self.clock.now,
                    lastRevision: 0,
                    lastManualApply: [:],
                    processWatchDescriptor: descriptor,
                    processWatchSource: source
                )
                // The C engine registered EVFILT_PROC/NOTE_EXIT synchronously;
                // activating the drain source completes the server-side lease.
                source.activate()
            }

            self.session?.armedMask |= UInt32(1) << UInt32(fanIndex)
            self.session?.lastHeartbeat = self.clock.now
            reply(0, "Crash watchdog armed for fan \(fanIndex + 1).")
        }
    }

    func heartbeat(peer: PeerMetadata, protocolVersion: Int, reply: @escaping StatusReply) {
        queue.async {
            if let failure = self.validationFailure(peer: peer, protocolVersion: protocolVersion) {
                reply(failure.status, failure.message)
                return
            }
            // A heartbeat presupposes a lease, so every non-owner answer is
            // lease-lost: the caller's lease cannot still exist.
            switch self.sessionAccess(for: peer) {
            case .owner(var current):
                current.lastHeartbeat = self.clock.now
                self.session = current
                reply(0, "Heartbeat accepted.")
            case .takeoverFailed:
                reply(ThermoFanXPC.recoveryRequiredStatus, Self.takeoverFailedMessage)
            case .leaseEnded(let reason):
                reply(ThermoFanXPC.leaseLostStatus, Self.leaseEndedMessage(reason))
            case .otherOwner:
                reply(
                    ThermoFanXPC.leaseLostStatus,
                    "This connection holds no watchdog lease; another authenticated ThermoFan session owns fan control."
                )
            case .unowned:
                reply(
                    ThermoFanXPC.leaseLostStatus,
                    "The previous watchdog lease ended; re-arm it before another manual write."
                )
            }
        }
    }

    func apply(
        peer: PeerMetadata,
        protocolVersion: Int,
        fanIndex: Int,
        mode: Int,
        rpm: Int,
        revision: UInt64,
        reply: @escaping StatusReply
    ) {
        queue.async {
            if let failure = self.validationFailure(peer: peer, protocolVersion: protocolVersion) {
                reply(failure.status, failure.message)
                return
            }
            guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex),
                  let requestedMode = ThermoFanXPC.Mode(rawValue: mode)
            else {
                reply(1, "The Hardware Helper rejected an invalid fan command.")
                return
            }
            let isAutomatic = requestedMode == .automatic
            if isAutomatic {
                guard rpm == 0 else {
                    reply(1, "Automatic mode does not accept an RPM target.")
                    return
                }
            } else {
                guard rpm > 0, rpm <= ThermoFanXPC.maximumRPM else {
                    reply(1, "The Hardware Helper rejected an unsafe RPM target.")
                    return
                }
            }

            let ownedSession: ActiveSession?
            switch self.sessionAccess(for: peer) {
            case .takeoverFailed:
                reply(ThermoFanXPC.recoveryRequiredStatus, Self.takeoverFailedMessage)
                return
            case .leaseEnded(let reason):
                reply(ThermoFanXPC.leaseLostStatus, Self.leaseEndedMessage(reason))
                return
            case .otherOwner:
                if isAutomatic {
                    reply(1, "Another authenticated ThermoFan session owns fan control.")
                } else {
                    reply(ThermoFanXPC.leaseLostStatus, Self.noLeaseMessage)
                }
                return
            case .owner(let current):
                ownedSession = current
            case .unowned:
                ownedSession = nil
            }

            let fanBit = UInt32(1) << UInt32(fanIndex)
            if !isAutomatic {
                guard let current = ownedSession, (current.armedMask & fanBit) != 0 else {
                    reply(ThermoFanXPC.leaseLostStatus, Self.noLeaseMessage)
                    return
                }
            }
            // Every request under an active lease, Auto included, must carry a
            // strictly newer revision. Auto without a lease stays allowed: it
            // is the safe direction and releases nothing ThermoFan owns.
            if var current = ownedSession {
                guard revision > current.lastRevision else {
                    reply(1, "A stale or duplicate hardware command was rejected.")
                    return
                }
                let now = self.clock.now
                if !isAutomatic {
                    if let lastApply = current.lastManualApply[fanIndex],
                       lastApply.duration(to: now) < .milliseconds(100) {
                        reply(1, "Fan commands are arriving too quickly; the duplicate burst was rejected.")
                        return
                    }
                    current.lastManualApply[fanIndex] = now
                }
                current.lastRevision = revision
                current.lastHeartbeat = now
                self.session = current
            }
            let fanWasLeased = ownedSession.map { ($0.armedMask & fanBit) != 0 } ?? false

            var identity = peer.identity.cValue
            let status = Int(thermofan_engine_apply(
                Int32(fanIndex),
                Int32(mode),
                Int32(rpm),
                &identity,
                0
            ))
            // The serialized C transaction can legitimately take longer than a
            // heartbeat interval on firmware that needs the Ftst unlock path.
            // Refresh activity after it returns before queued health checks run.
            if var current = self.session, current.peer.connectionID == peer.connectionID {
                current.lastHeartbeat = self.clock.now
                self.session = current
            }

            if status == ThermoFanXPC.recoveryRequiredStatus {
                if let current = self.session, current.peer.connectionID == peer.connectionID {
                    // The daemon, not the client, ends this lease. When the
                    // recovery verifies Auto, 76 makes the client drop every
                    // fan it still believes is leased.
                    let recoveryStatus = self.recover(current, reason: "a fan write could not be verified", notifyOwner: false)
                    if recoveryStatus == 0 {
                        reply(
                            ThermoFanXPC.leaseLostStatus,
                            "Fan \(fanIndex + 1)'s command could not be verified, so every ThermoFan-owned fan was verified back in automatic control and this watchdog lease ended. Re-arm before another manual write."
                        )
                    } else {
                        reply(ThermoFanXPC.recoveryRequiredStatus, Self.recoveryFailedMessage)
                    }
                } else {
                    // No lease to recover: hand the unverified durable
                    // ownership to the recovery supervisor and block writes.
                    self.enterRecoveryRequired(reason: "an unleased automatic request could not be verified")
                    reply(ThermoFanXPC.recoveryRequiredStatus, Self.recoveryFailedMessage)
                }
                return
            }
            guard status == 0 else {
                reply(1, "The privileged fan operation was rejected; no unverified result was accepted.")
                return
            }
            guard isAutomatic else {
                // The engine clamps the target to the SMC-reported range before
                // writing and reads back the clamped value, so the requested
                // RPM is not asserted as the verified value.
                reply(
                    0,
                    "Fan \(fanIndex + 1): requested manual target \(rpm) RPM was applied and read back within the fan's hardware range."
                )
                return
            }
            if var current = self.session, current.peer.connectionID == peer.connectionID {
                current.armedMask &= ~fanBit
                if current.armedMask == 0 {
                    self.cancelWatch(current)
                    self.session = nil
                } else {
                    current.lastHeartbeat = self.clock.now
                    self.session = current
                }
            }
            reply(
                0,
                fanWasLeased
                    ? "Fan \(fanIndex + 1) returned to automatic hardware control and its ThermoFan lease was released."
                    : "Fan \(fanIndex + 1) was not ThermoFan-owned (no watchdog lease covered it); automatic mode was requested and the SMC reported automatic control."
            )
        }
    }

    func returnAll(peer: PeerMetadata, protocolVersion: Int, reply: @escaping StatusReply) {
        queue.async {
            if let failure = self.validationFailure(peer: peer, protocolVersion: protocolVersion) {
                reply(failure.status, failure.message)
                return
            }
            switch self.sessionAccess(for: peer) {
            case .owner(let current):
                let status = self.recover(current, reason: "explicit automatic recovery", notifyOwner: false)
                reply(
                    status,
                    status == 0
                        ? "All ThermoFan-owned fans were verified back in automatic control."
                        : "Automatic recovery could not be verified; privileged control remains blocked."
                )
            case .takeoverFailed:
                reply(ThermoFanXPC.recoveryRequiredStatus, Self.takeoverFailedMessage)
            case .leaseEnded(let reason):
                reply(ThermoFanXPC.leaseLostStatus, Self.leaseEndedMessage(reason))
            case .otherOwner:
                reply(1, "Another authenticated ThermoFan session owns fan control.")
            case .unowned:
                // Validation proved startupStatus == 0, and every lease end
                // that is not verified blocks writes, so nothing is owned.
                reply(0, "No ThermoFan-owned manual fans require recovery.")
            }
        }
    }

    func retryAutomaticRecovery(
        peer: PeerMetadata,
        protocolVersion: Int,
        reply: @escaping StatusReply
    ) {
        queue.async {
            // Deliberately not blocked by recovery-required or retiring state:
            // this is the recovery path, and a verified retry ends retirement.
            guard !self.shuttingDown else {
                reply(1, Self.shuttingDownMessage)
                return
            }
            guard protocolVersion == ThermoFanXPC.protocolVersion else {
                reply(1, "The app and Hardware Helper protocols do not match.")
                return
            }
            guard Self.peerIsCurrentConsoleUser(peer) else {
                reply(
                    ThermoFanXPC.notConsoleUserStatus,
                    "The recovery request was not authorized for the active local console session."
                )
                return
            }

            let status: Int
            let successMessage: String
            let failureMessage: String
            switch self.sessionAccess(for: peer) {
            case .takeoverFailed:
                reply(ThermoFanXPC.recoveryRequiredStatus, Self.takeoverFailedMessage)
                return
            case .otherOwner:
                reply(1, "Another authenticated ThermoFan session owns the recovery lease.")
                return
            case .leaseEnded(let reason) where self.session != nil:
                // Another process holds the only lease; this caller has
                // nothing left to recover.
                reply(ThermoFanXPC.leaseLostStatus, Self.leaseEndedMessage(reason))
                return
            case .owner(let current):
                status = self.recover(current, reason: "user-requested recovery retry", notifyOwner: false)
                successMessage = "ThermoFan-owned fans were verified back in automatic control."
                failureMessage = "Automatic recovery is still unverified; manual writes remain blocked."
            case .leaseEnded, .unowned:
                status = self.retryStartupBoundary()
                successMessage = "Automatic hardware control and the v9 service boundary were verified."
                failureMessage = "Automatic recovery or legacy-helper cleanup is still unverified; manual writes remain blocked."
            }
            if status == 0 {
                // The console user chose to keep using this daemon.
                self.retiringSince = nil
                reply(0, successMessage)
            } else {
                reply(ThermoFanXPC.recoveryRequiredStatus, failureMessage)
            }
        }
    }

    func prepareForServiceRemoval(peer: PeerMetadata, reply: @escaping StatusReply) {
        queue.async {
            // Stable protocol-9 boundary: intentionally not blocked by
            // recovery-required or retiring state, so a retried update can
            // always re-prove Auto.
            guard !self.shuttingDown else {
                reply(1, Self.shuttingDownMessage)
                return
            }
            guard Self.peerIsCurrentConsoleUser(peer) else {
                reply(
                    ThermoFanXPC.notConsoleUserStatus,
                    "Only the active local console user may prepare the Hardware Helper for removal."
                )
                return
            }

            // Every write is serialized behind this block, so no write can
            // slip in between the recovery and the retirement decision. This
            // also ends a lease held by another running ThermoFan instance.
            let status: Int
            if let current = self.session {
                let endedByAnotherConnection = current.peer.connectionID != peer.connectionID
                status = self.recover(
                    current,
                    reason: endedByAnotherConnection
                        ? "another ThermoFan connection prepared the Hardware Helper for update or removal"
                        : "service update or removal",
                    notifyOwner: endedByAnotherConnection
                )
            } else {
                // Re-verify durable ownership instead of trusting memory. The
                // full barrier also re-opens the engine's manual-write gate that
                // startup recovery closes, so a lapsed retirement cannot strand
                // the daemon with every manual write failing.
                status = self.retryStartupBoundary()
            }
            // Retire only after Auto was verified; on failure the
            // recovery-required state already blocks writes.
            self.retiringSince = status == 0 ? self.clock.now : nil
            reply(
                status,
                status == 0
                    ? "Automatic control is verified; the Hardware Helper may now be unregistered."
                    : "The Hardware Helper was not unregistered because automatic recovery or legacy-helper cleanup is still unverified."
            )
        }
    }

    /// Stable protocol-9 selector, answered from the snapshot. Its status is
    /// only ever 0 or 75 for an authorized caller (never 78), because every
    /// app version gates `prepareForServiceRemoval` on exactly those values.
    func recoveryHandshake(
        peer: PeerMetadata,
        reply: HandshakeReply
    ) {
        let state = currentSnapshot()
        guard !state.shuttingDown else {
            reply(
                ThermoFanXPC.protocolVersion,
                ThermoFanXPC.stableRecoveryProtocolVersion,
                1,
                Self.shuttingDownMessage
            )
            return
        }
        guard Self.peerIsCurrentConsoleUser(peer) else {
            reply(
                ThermoFanXPC.protocolVersion,
                ThermoFanXPC.stableRecoveryProtocolVersion,
                ThermoFanXPC.notConsoleUserStatus,
                "Stable recovery is restricted to the active local console user."
            )
            return
        }
        reply(
            ThermoFanXPC.protocolVersion,
            ThermoFanXPC.stableRecoveryProtocolVersion,
            state.startupStatus == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus,
            state.startupStatus == 0
                ? "Stable protocol 9 recovery is available."
                : "Stable protocol 9 recovery is available and automatic recovery is required."
        )
    }

    func connectionEnded(connectionID: UInt64) {
        queue.async {
            self.endedLeaseNotices.removeValue(forKey: connectionID)
            guard let current = self.session, current.peer.connectionID == connectionID else { return }
            self.recover(current, reason: "the XPC connection ended", notifyOwner: false)
        }
    }

    func shutDown(completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            self.shuttingDown = true
            self.healthTimer.cancel()
            let result: Int
            if let current = self.session {
                result = self.recover(current, reason: "daemon termination", notifyOwner: false)
            } else {
                // Re-verify durable ownership instead of trusting memory. This
                // also covers a signal delivered before startup completed.
                result = thermofan_engine_recover_startup() == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus
            }
            completion(result)
        }
    }

    private func validationFailure(
        peer: PeerMetadata,
        protocolVersion: Int
    ) -> (status: Int, message: String)? {
        guard !shuttingDown else {
            return (1, Self.shuttingDownMessage)
        }
        guard protocolVersion == ThermoFanXPC.protocolVersion else {
            return (1, "The app and Hardware Helper protocols do not match.")
        }
        // Checked before recovery state so a background session gets 77, not 75.
        guard Self.peerIsCurrentConsoleUser(peer) else {
            return (
                ThermoFanXPC.notConsoleUserStatus,
                "Privileged fan control is restricted to the active local console user."
            )
        }
        guard startupStatus == 0 else {
            return (
                ThermoFanXPC.recoveryRequiredStatus,
                "Privileged control is blocked until automatic recovery succeeds."
            )
        }
        guard !retiring else {
            return (
                ThermoFanXPC.retiringStatus,
                "The Hardware Helper verified automatic control and is waiting to be unregistered; fan writes are refused."
            )
        }
        return nil
    }

    /// Resolves the caller's relation to the single active lease. A request
    /// from a newer connection of the same process identity (PID plus start
    /// time) first ends the older connection's lease exactly as
    /// `connectionEnded` would, synchronously on this queue. This happens on
    /// the newer connection's first state-mutating request rather than at
    /// accept time, because the listener's code-signing requirement is
    /// enforced per message. A different identity, or an older connection of
    /// the same process, is never allowed to take the lease. A pending
    /// lease-ended notice is consumed here.
    private func sessionAccess(for peer: PeerMetadata) -> SessionAccess {
        if let current = session {
            if current.peer.connectionID == peer.connectionID {
                return .owner(current)
            }
            if current.peer.identity == peer.identity,
               peer.connectionID > current.peer.connectionID {
                let status = recover(
                    current,
                    reason: "a newer connection from the same ThermoFan process replaced it",
                    notifyOwner: true
                )
                guard status == 0 else {
                    return .takeoverFailed
                }
            }
        }
        if let reason = endedLeaseNotices.removeValue(forKey: peer.connectionID) {
            return .leaseEnded(reason: reason)
        }
        return session == nil ? .unowned : .otherOwner
    }

    private static func leaseEndedMessage(_ reason: String) -> String {
        "The Hardware Helper ended this connection's watchdog lease because \(reason), and ThermoFan-owned fans were verified back in automatic control. Re-arm before another manual write."
    }

    private func recordEndedLeaseNotice(connectionID: UInt64, reason: String) {
        endedLeaseNotices[connectionID] = reason
        // Notices are removed when delivered or when the connection ends; the
        // cap only bounds the map if neither ever happens.
        while endedLeaseNotices.count > Self.endedLeaseNoticeLimit,
              let oldest = endedLeaseNotices.keys.min() {
            endedLeaseNotices.removeValue(forKey: oldest)
        }
    }

    /// Stateless; safe on any thread (the handshakes call it off-queue).
    private static func peerIsCurrentConsoleUser(_ peer: PeerMetadata) -> Bool {
        guard peer.identity.pid > 1, peer.userID != 0,
              peerHasLocalGraphicSession(peer),
              let consoleUID = activeConsoleUserID()
        else {
            return false
        }
        return peer.userID == consoleUID
    }

    private static func peerHasLocalGraphicSession(_ peer: PeerMetadata) -> Bool {
        // A negative audit session ID is never a graphical login session, and
        // converting it to the unsigned SecuritySessionId would trap (-1 would
        // otherwise alias callerSecuritySession, the daemon's own session).
        guard peer.auditSessionID >= 0 else {
            return false
        }
        let sessionID = SecuritySessionId(peer.auditSessionID)
        var resolvedSessionID: SecuritySessionId = 0
        var attributes: SessionAttributeBits = []
        let status = SessionGetInfo(sessionID, &resolvedSessionID, &attributes)
        return status == errSecSuccess
            && resolvedSessionID == sessionID
            && attributes.contains(.sessionHasGraphicAccess)
            && !attributes.contains(.sessionIsRemote)
            && !attributes.contains(.sessionIsRoot)
    }

    private static func activeConsoleUserID() -> uid_t? {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &userID, &groupID) as String?,
              name != "loginwindow", name != "_mbsetupuser", userID != 0, userID != uid_t.max
        else {
            return nil
        }
        return userID
    }

    private static func legacyHelperPathExists() -> Bool {
        legacyHelperPaths.contains { path in
            var attributes = stat()
            if lstat(path, &attributes) == 0 {
                return true
            }
            // Anything but a clean "does not exist" is treated as present so
            // the engine's fail-closed barrier decides.
            return errno != ENOENT
        }
    }

    private func processExitWatchFired(connectionID: UInt64) {
        guard let current = session, current.peer.connectionID == connectionID else { return }
        // Only a 0 result proves that the exact leased process exited. Any
        // other result, including the engine's bounded-wait timeout, leaves the
        // lease and the watch armed; the heartbeat lease still bounds a client
        // that stops responding.
        guard thermofan_engine_consume_process_exit_watch(current.processWatchDescriptor) == 0 else {
            fputs("ThermoFanHelper: the process-exit watch fired without a confirmed exact-process exit; the lease remains armed.\n", stderr)
            return
        }
        recover(current, reason: "the client process exited", notifyOwner: false)
    }

    private func performHealthCheck() {
        guard startupComplete, !shuttingDown else { return }
        let now = clock.now
        if let since = retiringSince, since.duration(to: now) > Self.retiringTimeout {
            // The client gave up unregistering; resume normal service.
            retiringSince = nil
            fputs("ThermoFanHelper: service removal did not complete in time; retirement was cleared.\n", stderr)
        }
        if let current = session {
            if !Self.peerIsCurrentConsoleUser(current.peer) {
                recover(current, reason: "the active console user changed", notifyOwner: true)
                return
            }
            if current.lastHeartbeat.duration(to: now) > .seconds(ThermoFanXPC.heartbeatTimeout) {
                recover(current, reason: "the heartbeat lease expired", notifyOwner: true)
                return
            }
        } else if startupStatus != 0 {
            if nextRecoveryAttempt.map({ $0 <= now }) ?? true {
                _ = retryStartupBoundary()
            }
        } else if nextLegacyCheck.map({ $0 <= now }) ?? true {
            nextLegacyCheck = now.advanced(by: Self.legacyCheckInterval)
            if Self.legacyHelperPathExists() {
                // Same barrier as startup: writes stay blocked until the
                // reappeared legacy helper is retired and Auto is re-verified.
                fputs("ThermoFanHelper: a legacy helper path reappeared; manual writes are blocked until it is retired again.\n", stderr)
                _ = retryStartupBoundary()
            }
        }
    }

    /// Ends `current` and returns its durably owned fans to Auto. Returns 0
    /// when the engine verified Auto; otherwise 75, and writes stay blocked
    /// until the recovery supervisor's full startup barrier succeeds. With
    /// `notifyOwner`, the session's connection receives a one-shot
    /// lease-ended (76) notice on its next lease-scoped request because the
    /// daemon, not that client, ended the lease.
    @discardableResult
    private func recover(_ current: ActiveSession, reason: String, notifyOwner: Bool) -> Int {
        cancelWatch(current)
        session = nil
        if notifyOwner {
            recordEndedLeaseNotice(connectionID: current.peer.connectionID, reason: reason)
        }
        var identity = current.peer.identity.cValue
        guard thermofan_engine_return_all(&identity) == 0 else {
            enterRecoveryRequired(reason: reason)
            return ThermoFanXPC.recoveryRequiredStatus
        }
        return 0
    }

    private func enterRecoveryRequired(reason: String) {
        startupStatus = ThermoFanXPC.recoveryRequiredStatus
        recoveryAttempts += 1
        scheduleNextRecoveryAttempt()
        fputs("ThermoFanHelper: automatic recovery remains unverified (\(reason)).\n", stderr)
    }

    /// The full fail-closed barrier: unconditional durable Auto recovery,
    /// then legacy-helper retirement, which re-opens the engine's manual-write
    /// gate that `thermofan_engine_recover_startup` closes. Startup recovery
    /// is unconditional, so this runs only while no lease is active.
    private func retryStartupBoundary() -> Int {
        recoveryAttempts += 1
        var status = Int(thermofan_engine_recover_startup())
        if status == 0, thermofan_engine_remove_legacy_helpers() != 0 {
            status = ThermoFanXPC.recoveryRequiredStatus
        }
        if status == 0 {
            startupStatus = 0
            recoveryAttempts = 0
            nextRecoveryAttempt = nil
        } else {
            startupStatus = ThermoFanXPC.recoveryRequiredStatus
            scheduleNextRecoveryAttempt()
        }
        return startupStatus
    }

    private func scheduleNextRecoveryAttempt() {
        let delays = [2, 5, 10, 30, 60]
        let index = min(max(recoveryAttempts - 1, 0), delays.count - 1)
        nextRecoveryAttempt = clock.now.advanced(by: .seconds(delays[index]))
    }

    private func cancelWatch(_ current: ActiveSession) {
        current.processWatchSource?.cancel()
    }

    /// Called on `queue` whenever handshake-visible state changes.
    private func publishSnapshot() {
        let current = HandshakeSnapshot(
            startupStatus: startupStatus,
            retiring: retiring,
            shuttingDown: shuttingDown,
            hasSession: session != nil
        )
        sharedStateLock.lock()
        snapshot = current
        sharedStateLock.unlock()
    }

    private func currentSnapshot() -> HandshakeSnapshot {
        sharedStateLock.lock()
        defer { sharedStateLock.unlock() }
        return snapshot
    }
}

private final class PeerSession: NSObject, ThermoFanDaemonProtocol, @unchecked Sendable {
    private let metadata: PeerMetadata
    private let coordinator: DaemonCoordinator

    init(metadata: PeerMetadata, coordinator: DaemonCoordinator) {
        self.metadata = metadata
        self.coordinator = coordinator
    }

    func handshake(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    ) {
        coordinator.handshake(peer: metadata, protocolVersion: protocolVersion, reply: reply)
    }

    func armWatchdog(
        protocolVersion: Int,
        fanIndex: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.arm(peer: metadata, protocolVersion: protocolVersion, fanIndex: fanIndex, reply: reply)
    }

    func heartbeat(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.heartbeat(peer: metadata, protocolVersion: protocolVersion, reply: reply)
    }

    func applyFan(
        protocolVersion: Int,
        fanIndex: Int,
        mode: Int,
        rpm: Int,
        revision: UInt64,
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.apply(
            peer: metadata,
            protocolVersion: protocolVersion,
            fanIndex: fanIndex,
            mode: mode,
            rpm: rpm,
            revision: revision,
            reply: reply
        )
    }

    func returnAllFansToAutomatic(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.returnAll(peer: metadata, protocolVersion: protocolVersion, reply: reply)
    }

    func retryAutomaticRecovery(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.retryAutomaticRecovery(
            peer: metadata,
            protocolVersion: protocolVersion,
            reply: reply
        )
    }

    func prepareForServiceRemoval(
        reply: @escaping @Sendable (Int, String) -> Void
    ) {
        coordinator.prepareForServiceRemoval(peer: metadata, reply: reply)
    }

    func recoveryHandshake(
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    ) {
        coordinator.recoveryHandshake(peer: metadata, reply: reply)
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let coordinator: DaemonCoordinator

    init(coordinator: DaemonCoordinator) {
        self.coordinator = coordinator
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        guard pid > 1, let identity = EngineIdentity(pid) else {
            return false
        }
        let metadata = PeerMetadata(
            connectionID: coordinator.nextConnectionID(),
            identity: identity,
            userID: connection.effectiveUserIdentifier,
            auditSessionID: connection.auditSessionIdentifier
        )
        let session = PeerSession(metadata: metadata, coordinator: coordinator)
        connection.exportedInterface = NSXPCInterface(with: ThermoFanDaemonProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak coordinator] in
            coordinator?.connectionEnded(connectionID: metadata.connectionID)
        }
        // Listener-side connections are invalidated rather than interrupted;
        // should one ever be interrupted, recover exactly as for invalidation.
        connection.interruptionHandler = { [weak coordinator] in
            coordinator?.connectionEnded(connectionID: metadata.connectionID)
        }
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    fputs("ThermoFanHelper must be launched by macOS as a root LaunchDaemon.\n", stderr)
    exit(1)
}

// launchd (PID 1) is the parent of every LaunchDaemon. Refuse any other
// launch before anything touches the SMC or legacy helper files.
guard getppid() == 1 else {
    fputs("ThermoFanHelper must be launched by launchd as a registered SMAppService LaunchDaemon.\n", stderr)
    exit(78)
}

// Signal handling is installed before the startup barrier. Shutdown recovery
// runs on the coordinator queue, so a signal delivered during startup still
// returns durable ownership to Auto, before or after the barrier.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
private let coordinator = DaemonCoordinator()
let signalQueue = DispatchQueue(label: "io.github.girginomer10.ThermoFan.helper.signals")
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
terminationSource.setEventHandler {
    coordinator.shutDown { status in
        exit(Int32(status == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus))
    }
}
terminationSource.activate()
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
interruptSource.setEventHandler {
    coordinator.shutDown { status in
        exit(Int32(status == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus))
    }
}
interruptSource.activate()

// Recovers durable ownership first, then exits 78 unless this helper is
// Developer ID signed, then retires legacy helpers.
private let clientRequirement = coordinator.runStartupBarrier()
private let delegate = ListenerDelegate(coordinator: coordinator)
private let listener = NSXPCListener(machServiceName: ThermoFanXPC.helperIdentifier)
listener.setConnectionCodeSigningRequirement(clientRequirement)
listener.delegate = delegate

listener.activate()
dispatchMain()
