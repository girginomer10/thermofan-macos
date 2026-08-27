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
    let id: UUID
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

private final class DaemonCoordinator: @unchecked Sendable {
    typealias StatusReply = @Sendable (Int, String) -> Void

    private let queue = DispatchQueue(label: "io.github.girginomer10.ThermoFan.helper.engine")
    private let clock = ContinuousClock()
    private var session: ActiveSession?
    private var recoveryAttempts = 0
    private var nextRecoveryAttempt: ContinuousClock.Instant?
    private var startupStatus: Int
    private var shuttingDown = false
    private var retiring = false
    private let healthTimer: DispatchSourceTimer

    init(startupStatus: Int) {
        self.startupStatus = startupStatus
        if startupStatus != 0 {
            recoveryAttempts = 1
            nextRecoveryAttempt = clock.now.advanced(by: .seconds(2))
        }
        healthTimer = DispatchSource.makeTimerSource(queue: queue)
        healthTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        healthTimer.setEventHandler { [weak self] in
            self?.performHealthCheck()
        }
        healthTimer.activate()
    }

    func handshake(
        peer: PeerMetadata,
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    ) {
        queue.async {
            guard protocolVersion == ThermoFanXPC.protocolVersion else {
                reply(
                    ThermoFanXPC.protocolVersion,
                    ThermoFanXPC.implementationRevision,
                    1,
                    "The app and Hardware Helper protocols do not match. Update ThermoFan before controlling fans."
                )
                return
            }
            guard !self.retiring else {
                reply(
                    ThermoFanXPC.protocolVersion,
                    ThermoFanXPC.implementationRevision,
                    self.startupStatus == 0 ? 1 : ThermoFanXPC.recoveryRequiredStatus,
                    self.startupStatus == 0
                        ? "The Hardware Helper has verified recovery and is waiting to be unregistered."
                        : "The Hardware Helper is waiting for verified automatic recovery before it can be unregistered."
                )
                return
            }
            guard self.peerIsCurrentConsoleUser(peer) else {
                reply(
                    ThermoFanXPC.protocolVersion,
                    ThermoFanXPC.implementationRevision,
                    1,
                    "Privileged fan control is restricted to the active console user."
                )
                return
            }
            guard self.startupStatus == 0 else {
                reply(
                    ThermoFanXPC.protocolVersion,
                    ThermoFanXPC.implementationRevision,
                    ThermoFanXPC.recoveryRequiredStatus,
                    "The Hardware Helper is blocked until durable fan ownership can be recovered safely."
                )
                return
            }
            reply(
                ThermoFanXPC.protocolVersion,
                ThermoFanXPC.implementationRevision,
                0,
                "Authenticated Hardware Helper protocol is ready."
            )
        }
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

            if let existing = self.session, existing.peer.id != peer.id {
                reply(1, "Fan control is already owned by another authenticated ThermoFan session.")
                return
            }

            if self.session == nil {
                var identity = peer.identity.cValue
                let descriptor = thermofan_engine_open_process_exit_watch(&identity)
                guard descriptor >= 0 else {
                    reply(1, "The Hardware Helper could not arm its process-exit watchdog. No hardware write was attempted.")
                    return
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
                let sessionID = peer.id
                source.setEventHandler { [weak self] in
                    self?.processExited(sessionID: sessionID)
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
            guard var current = self.session else {
                reply(
                    ThermoFanXPC.leaseLostStatus,
                    "The previous watchdog lease ended; re-arm it before another manual write."
                )
                return
            }
            guard current.peer.id == peer.id else {
                reply(1, "The heartbeat does not own the active fan session.")
                return
            }
            current.lastHeartbeat = self.clock.now
            self.session = current
            reply(0, "Heartbeat accepted.")
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
            if requestedMode == .automatic {
                guard rpm == 0 else {
                    reply(1, "Automatic mode does not accept an RPM target.")
                    return
                }
            } else {
                guard rpm > 0, rpm <= ThermoFanXPC.maximumRPM else {
                    reply(1, "The Hardware Helper rejected an unsafe RPM target.")
                    return
                }
                guard var current = self.session,
                      current.peer.id == peer.id,
                      (current.armedMask & (UInt32(1) << UInt32(fanIndex))) != 0
                else {
                    reply(
                        ThermoFanXPC.leaseLostStatus,
                        "Manual fan control was blocked because this connection no longer has a verified watchdog lease."
                    )
                    return
                }
                guard revision > current.lastRevision else {
                    reply(1, "A stale or duplicate hardware command was rejected.")
                    return
                }
                let now = self.clock.now
                if let lastApply = current.lastManualApply[fanIndex],
                   lastApply.duration(to: now) < .milliseconds(100) {
                    reply(1, "Fan commands are arriving too quickly; the duplicate burst was rejected.")
                    return
                }
                current.lastRevision = revision
                current.lastHeartbeat = now
                current.lastManualApply[fanIndex] = now
                self.session = current
            }

            if let current = self.session, current.peer.id != peer.id {
                reply(1, "Another authenticated ThermoFan session owns fan control.")
                return
            }

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
            if var current = self.session, current.peer.id == peer.id {
                current.lastHeartbeat = self.clock.now
                self.session = current
            }

            var responseStatus = status
            if status == ThermoFanXPC.recoveryRequiredStatus,
               let current = self.session, current.peer.id == peer.id {
                let recoveryStatus = self.recover(current, reason: "unverified fan write")
                responseStatus = recoveryStatus == 0 ? 1 : ThermoFanXPC.recoveryRequiredStatus
            }

            if responseStatus == 0, requestedMode == .automatic,
               var current = self.session, current.peer.id == peer.id {
                current.armedMask &= ~(UInt32(1) << UInt32(fanIndex))
                if current.armedMask == 0 {
                    self.cancelWatch(current)
                    self.session = nil
                } else {
                    current.lastHeartbeat = self.clock.now
                    self.session = current
                }
            }
            reply(
                responseStatus,
                self.message(status: responseStatus, mode: requestedMode, fanIndex: fanIndex, rpm: rpm)
            )
        }
    }

    func returnAll(peer: PeerMetadata, protocolVersion: Int, reply: @escaping StatusReply) {
        queue.async {
            if let failure = self.validationFailure(peer: peer, protocolVersion: protocolVersion) {
                reply(failure.status, failure.message)
                return
            }
            guard let current = self.session else {
                reply(0, "No ThermoFan-owned manual fans require recovery.")
                return
            }
            guard current.peer.id == peer.id else {
                reply(1, "Another authenticated ThermoFan session owns fan control.")
                return
            }
            let status = self.recover(current, reason: "explicit automatic recovery")
            reply(
                status,
                status == 0
                    ? "All ThermoFan-owned fans were verified back in automatic control."
                    : "Automatic recovery could not be verified; privileged control remains blocked."
            )
        }
    }

    func retryAutomaticRecovery(
        peer: PeerMetadata,
        protocolVersion: Int,
        reply: @escaping StatusReply
    ) {
        queue.async {
            guard !self.shuttingDown,
                  protocolVersion == ThermoFanXPC.protocolVersion,
                  self.peerIsCurrentConsoleUser(peer)
            else {
                reply(1, "The recovery request was not authorized for the active console session.")
                return
            }
            if let current = self.session {
                guard current.peer.id == peer.id else {
                    reply(1, "Another authenticated ThermoFan session owns the recovery lease.")
                    return
                }
                let status = self.recover(current, reason: "user-requested recovery retry")
                reply(
                    status,
                    status == 0
                        ? "ThermoFan-owned fans were verified back in automatic control."
                        : "Automatic recovery is still unverified; manual writes remain blocked."
                )
                return
            }

            let status = self.retryStartupBoundary()
            if status == 0 {
                reply(0, "Automatic hardware control and the v9 service boundary were verified.")
            } else {
                reply(
                    ThermoFanXPC.recoveryRequiredStatus,
                    "Automatic recovery or legacy-helper cleanup is still unverified; manual writes remain blocked."
                )
            }
        }
    }

    func prepareForServiceRemoval(peer: PeerMetadata, reply: @escaping StatusReply) {
        queue.async {
            guard !self.shuttingDown, self.peerIsCurrentConsoleUser(peer) else {
                reply(1, "Only the active local console user may prepare the Hardware Helper for removal.")
                return
            }

            // Block every subsequent write before recovery begins. This also
            // covers another still-running ThermoFan instance during an update.
            self.retiring = true
            let status: Int
            if let current = self.session {
                status = self.recover(current, reason: "service update or removal")
            } else if self.startupStatus != 0 {
                status = self.retryStartupBoundary()
            } else {
                status = 0
            }
            reply(
                status,
                status == 0
                    ? "Automatic control is verified; the Hardware Helper may now be unregistered."
                    : "The Hardware Helper was not unregistered because automatic recovery is still unverified."
            )
        }
    }

    func recoveryHandshake(
        peer: PeerMetadata,
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    ) {
        queue.async {
            guard !self.shuttingDown, self.peerIsCurrentConsoleUser(peer) else {
                reply(
                    ThermoFanXPC.protocolVersion,
                    ThermoFanXPC.stableRecoveryProtocolVersion,
                    1,
                    "Stable recovery is restricted to the active local console user."
                )
                return
            }
            reply(
                ThermoFanXPC.protocolVersion,
                ThermoFanXPC.stableRecoveryProtocolVersion,
                self.startupStatus == 0 ? 0 : ThermoFanXPC.recoveryRequiredStatus,
                self.startupStatus == 0
                    ? "Stable protocol 9 recovery is available."
                    : "Stable protocol 9 recovery is available and automatic recovery is required."
            )
        }
    }

    func connectionEnded(peerID: UUID) {
        queue.async {
            guard let current = self.session, current.peer.id == peerID else { return }
            _ = self.recover(current, reason: "XPC connection ended")
        }
    }

    func shutDown(completion: @escaping @Sendable (Int) -> Void) {
        queue.async {
            self.shuttingDown = true
            self.healthTimer.cancel()
            let result: Int
            if let current = self.session {
                result = self.recover(current, reason: "daemon termination")
            } else if self.startupStatus != 0 {
                result = self.retryStartupBoundary()
            } else {
                result = self.startupStatus
            }
            completion(result)
        }
    }

    private func validationFailure(
        peer: PeerMetadata,
        protocolVersion: Int
    ) -> (status: Int, message: String)? {
        guard !shuttingDown else {
            return (1, "The Hardware Helper is shutting down safely.")
        }
        guard !retiring else {
            return (1, "The Hardware Helper is waiting to be unregistered after verified recovery.")
        }
        guard protocolVersion == ThermoFanXPC.protocolVersion else {
            return (1, "The app and Hardware Helper protocols do not match.")
        }
        guard startupStatus == 0 else {
            return (
                ThermoFanXPC.recoveryRequiredStatus,
                "Privileged control is blocked until automatic recovery succeeds."
            )
        }
        guard peerIsCurrentConsoleUser(peer) else {
            return (1, "Privileged fan control is restricted to the active console user.")
        }
        return nil
    }

    private func peerIsCurrentConsoleUser(_ peer: PeerMetadata) -> Bool {
        guard peer.identity.pid > 1, peer.userID != 0,
              Self.peerHasLocalGraphicSession(peer),
              let consoleUID = Self.activeConsoleUserID()
        else {
            return false
        }
        return peer.userID == consoleUID
    }

    private static func peerHasLocalGraphicSession(_ peer: PeerMetadata) -> Bool {
        var resolvedSessionID: SecuritySessionId = 0
        var attributes: SessionAttributeBits = []
        let status = SessionGetInfo(
            SecuritySessionId(peer.auditSessionID),
            &resolvedSessionID,
            &attributes
        )
        return status == errSecSuccess
            && resolvedSessionID == SecuritySessionId(peer.auditSessionID)
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

    private func processExited(sessionID: UUID) {
        guard let current = session, current.peer.id == sessionID else { return }
        guard thermofan_engine_consume_process_exit_watch(current.processWatchDescriptor) == 0 else {
            _ = recover(current, reason: "process-watch failure")
            return
        }
        _ = recover(current, reason: "client process exited")
    }

    private func performHealthCheck() {
        if let current = session {
            if !peerIsCurrentConsoleUser(current.peer) {
                _ = recover(current, reason: "console user changed")
                return
            }
            if current.lastHeartbeat.duration(to: clock.now) > .seconds(ThermoFanXPC.heartbeatTimeout) {
                _ = recover(current, reason: "heartbeat lease expired")
                return
            }
        } else if startupStatus != 0,
                  nextRecoveryAttempt.map({ $0 <= clock.now }) ?? true {
            _ = retryStartupBoundary()
        }
    }

    @discardableResult
    private func recover(_ current: ActiveSession, reason: String) -> Int {
        cancelWatch(current)
        session = nil
        var identity = current.peer.identity.cValue
        let status = Int(thermofan_engine_return_all(&identity))
        if status == 0 {
            startupStatus = 0
            recoveryAttempts = 0
            nextRecoveryAttempt = nil
        } else {
            startupStatus = status == ThermoFanXPC.recoveryRequiredStatus
                ? status
                : ThermoFanXPC.recoveryRequiredStatus
            recoveryAttempts += 1
            scheduleNextRecoveryAttempt()
            fputs("ThermoFanHelper: \(reason) recovery remains unverified.\n", stderr)
        }
        return startupStatus
    }

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

    private func message(status: Int, mode: ThermoFanXPC.Mode, fanIndex: Int, rpm: Int) -> String {
        if status == 0 {
            return mode == .automatic
                ? "Fan \(fanIndex + 1) returned to automatic hardware control."
                : "Fan \(fanIndex + 1) target was verified on hardware at \(rpm) RPM."
        }
        if status == ThermoFanXPC.recoveryRequiredStatus {
            return "The fan write failed and automatic rollback could not be verified. Recovery remains active."
        }
        return "The privileged fan operation was rejected; no unverified result was accepted."
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
        guard let identity = EngineIdentity(pid), pid > 1 else {
            return false
        }
        let metadata = PeerMetadata(
            id: UUID(),
            identity: identity,
            userID: connection.effectiveUserIdentifier,
            auditSessionID: connection.auditSessionIdentifier
        )
        let session = PeerSession(metadata: metadata, coordinator: coordinator)
        connection.exportedInterface = NSXPCInterface(with: ThermoFanDaemonProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak coordinator] in
            coordinator?.connectionEnded(peerID: metadata.id)
        }
        connection.interruptionHandler = { [weak coordinator] in
            coordinator?.connectionEnded(peerID: metadata.id)
        }
        connection.activate()
        return true
    }
}

guard geteuid() == 0 else {
    fputs("ThermoFanHelper must be launched by macOS as a root LaunchDaemon.\n", stderr)
    exit(1)
}

guard let clientRequirement = ThermoFanXPC.peerRequirement(
    identifier: ThermoFanXPC.appIdentifier,
    currentIdentifier: ThermoFanXPC.helperIdentifier
) else {
    fputs("ThermoFanHelper requires a Developer ID Application signature; ad-hoc builds remain monitoring-only.\n", stderr)
    exit(78)
}

var startupStatus = Int(thermofan_engine_recover_startup())
if startupStatus == 0 {
    if thermofan_engine_remove_legacy_helpers() != 0 {
        // A known setuid v8 binary would preserve the bypassed CLI surface.
        // Keep all new manual writes blocked until it is safely gone.
        startupStatus = ThermoFanXPC.recoveryRequiredStatus
    }
}
private let coordinator = DaemonCoordinator(startupStatus: startupStatus)
private let delegate = ListenerDelegate(coordinator: coordinator)
private let listener = NSXPCListener(machServiceName: ThermoFanXPC.helperIdentifier)
listener.setConnectionCodeSigningRequirement(clientRequirement)
listener.delegate = delegate

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
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

listener.activate()
dispatchMain()
