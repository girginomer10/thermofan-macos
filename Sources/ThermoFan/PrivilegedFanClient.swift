import AppKit
import FanControlXPC
import Foundation
import ServiceManagement

/// App-side client for the root `SMAppService` LaunchDaemon.
///
/// Threading and lock ordering:
/// - `operationLock` serializes every blocking operation (service
///   registration, status polling, arm, apply, recovery). It is held across
///   bounded semaphore waits, so it must only be taken off the main actor.
///   The single exception is `returnAllToAutomatic(timeout:)`, which acquires
///   it with a deadline and is safe to call from the main thread at quit.
/// - `stateLock` guards the transport, lease, heartbeat, and callback state.
///   It is a leaf lock: it may be taken while `operationLock` is held, never
///   the other way around. It is never held across a wait, while calling
///   `NSXPCConnection.invalidate()`, or while invoking a callback.
/// - XPC reply blocks, interruption/invalidation handlers, and the heartbeat
///   only ever take `stateLock`, so they cannot deadlock with an operation
///   that is waiting for them.
/// - `onLeaseLost` is always delivered asynchronously on a private serial
///   queue, never on the caller's thread and never under a lock.
final class PrivilegedFanClient: @unchecked Sendable {
    enum Result: Sendable {
        case applied(String)
        case failed(String)
        case recoveryRequired(String)
    }

    struct Handshake: Sendable {
        let protocolVersion: Int
        let implementationRevision: Int
        let status: Int
        let message: String

        /// Protocol and implementation revision both match this app. This says
        /// nothing about whether the daemon currently accepts writes.
        var isVersionCurrent: Bool {
            protocolVersion == ThermoFanXPC.protocolVersion
                && implementationRevision == ThermoFanXPC.implementationRevision
        }

        /// Version-current and accepting privileged requests from this session.
        var isReady: Bool {
            isVersionCurrent && status == 0
        }
    }

    enum TransportError: Error, LocalizedError, Sendable {
        /// A local precondition failed before anything was sent to the daemon.
        case unavailable(String)
        /// NSXPC reported a failure through the proxy error handler: the
        /// connection was interrupted or invalidated, or the daemon does not
        /// implement the selector.
        case connection(String)
        /// The daemon did not answer within the bounded wait.
        case timeout(String)
        /// The daemon answered the versioned handshake but is not ready.
        case notReady(Handshake)
        /// The daemon answered a request with a non-zero status.
        case refused(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .connection(let message), .timeout(let message):
                message
            case .notReady(let handshake):
                PrivilegedFanClient.readinessMessage(for: handshake)
            case .refused(_, let message):
                message
            }
        }
    }

    static let approvalRequiredMessage =
        "Approval required: approve ThermoFan under System Settings → General → Login Items, then return and try again. No hardware write was attempted."
    static let inactiveSessionMessage =
        "Privileged fan control is available only to the active local console user. Monitoring continues in this login session; no hardware write was attempted."

    private enum Timing {
        /// Handshake wait for operations (register, arm, apply, recovery).
        static let handshake: TimeInterval = 5
        /// Shorter handshake wait for helper-state polling.
        static let statusHandshake: TimeInterval = 3
        static let arm: TimeInterval = 5
        static let apply: TimeInterval = 25
        static let recovery: TimeInterval = 90
        static let unregister: TimeInterval = 20
        /// The daemon runs startup recovery plus a legacy-helper drain of up to
        /// 5 s before it activates its listener.
        static let postRegisterReadiness: TimeInterval = 30
        static let postRegisterPollInterval: TimeInterval = 2
    }

    private struct RPCResponse: Sendable {
        let status: Int
        let message: String
    }

    /// An authenticated transport plus the handshake it answered. Only used
    /// within a single operation while `operationLock` is held.
    private struct Link {
        let connection: NSXPCConnection
        let generation: UInt64
        let handshake: Handshake
    }

    /// Monotonic time budget for an operation. `nil` keeps each step's own
    /// default wait.
    private struct Deadline {
        private let end: TimeInterval?

        init(timeout: TimeInterval?) {
            end = timeout.map { ProcessInfo.processInfo.systemUptime + max(0, $0) }
        }

        var remaining: TimeInterval {
            guard let end else { return .infinity }
            return max(0, end - ProcessInfo.processInfo.systemUptime)
        }

        func budget(_ step: TimeInterval) -> TimeInterval {
            min(step, remaining)
        }

        var lockLimit: Date? {
            end == nil ? nil : Date(timeIntervalSinceNow: remaining)
        }
    }

    private final class Waiter<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var value: Swift.Result<Value, Error>?

        func finish(_ result: Swift.Result<Value, Error>) {
            lock.lock()
            guard value == nil else {
                lock.unlock()
                return
            }
            value = result
            lock.unlock()
            semaphore.signal()
        }

        func wait(seconds: TimeInterval, operation: String) throws -> Value {
            guard semaphore.wait(timeout: .now() + max(0, seconds)) == .success else {
                throw TransportError.timeout("Timed out while waiting for the authenticated Hardware Helper to \(operation).")
            }
            lock.lock()
            let result = value
            lock.unlock()
            guard let result else {
                throw TransportError.unavailable("The Hardware Helper returned no result.")
            }
            return try result.get()
        }
    }

    private let operationLock = NSLock()
    private let stateLock = NSLock()
    private let heartbeatQueue = DispatchQueue(label: "io.github.girginomer10.ThermoFan.heartbeat", qos: .utility)
    private let notificationQueue = DispatchQueue(label: "io.github.girginomer10.ThermoFan.lease-lost", qos: .utility)

    // Guarded by `stateLock`.
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0
    private var armedFans: Set<Int> = []
    /// Incremented on every successful `armWatchdog`, so a heartbeat reply
    /// that was in flight before a fresh lease cannot end that lease.
    private var leaseGeneration: UInt64 = 0
    private var revision: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var leaseLostHandler: (@Sendable (Set<Int>, String) -> Void)?

    /// Called asynchronously, off the main actor, with the fan indexes whose
    /// manual lease this client held and that are no longer leased, plus a
    /// human-readable reason. Fires when the transport is interrupted or
    /// closed, a heartbeat is rejected, the daemon reports a lease-ending
    /// status (75/76/77/78), a result becomes uncertain, or a
    /// `returnAllToAutomatic`/`retryAutomaticRecovery` succeeds while fans
    /// were still leased. A successful single-fan Auto `apply` does not fire
    /// it because its own result already reports that fan. The notification
    /// may arrive before or after the result of the operation that caused it.
    var onLeaseLost: (@Sendable (Set<Int>, String) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return leaseLostHandler
        }
        set {
            stateLock.lock()
            leaseLostHandler = newValue
            stateLock.unlock()
        }
    }

    deinit {
        invalidateTransport(leaseLostReason: nil)
    }

    // MARK: - Helper state

    /// Blocking: one `SMAppService.status` query plus, for an enabled service,
    /// an authenticated handshake bounded to 3 s. Call only off the main actor.
    var serviceState: HardwareHelperState {
        operationLock.lock()
        defer { operationLock.unlock() }

        let isDeveloperID = Self.isDeveloperIDBuild
        let containsDaemon = Self.bundleContainsDaemon
        let inApplications = Self.isRunningFromApplications
        guard isDeveloperID, containsDaemon, inApplications else {
            // Build-level states never depend on launchd or the daemon, so the
            // placeholder service status below is never consulted.
            return Self.deriveState(
                bundleContainsDaemon: containsDaemon,
                isRunningFromApplications: inApplications,
                isDeveloperID: isDeveloperID,
                status: .notRegistered,
                handshake: nil
            )
        }

        let status = Self.service.status
        var handshake: Swift.Result<Handshake, Error>?
        if status == .enabled {
            handshake = Swift.Result {
                try ensureHandshake(timeout: Timing.statusHandshake).handshake
            }
        }
        return Self.deriveState(
            bundleContainsDaemon: containsDaemon,
            isRunningFromApplications: inApplications,
            isDeveloperID: isDeveloperID,
            status: status,
            handshake: handshake
        )
    }

    /// Pure mapping from the observed build, launchd, and daemon facts to the
    /// helper state shown in the UI. `handshake` is `nil` when none was
    /// attempted and `.failure` when it timed out or the transport failed.
    static func deriveState(
        bundleContainsDaemon: Bool,
        isRunningFromApplications: Bool,
        isDeveloperID: Bool,
        status: SMAppService.Status,
        handshake: Swift.Result<Handshake, Error>?
    ) -> HardwareHelperState {
        guard isDeveloperID, bundleContainsDaemon else { return .monitoringOnly }
        guard isRunningFromApplications else { return .wrongLocation }

        switch status {
        case .notRegistered:
            return .missing
        case .requiresApproval:
            return .approvalRequired
        case .notFound:
            return .monitoringOnly
        case .enabled:
            guard case .success(let reply) = handshake else {
                // No live answer: timeout, NSXPC failure, or not attempted.
                return .unreachable
            }
            guard reply.isVersionCurrent else { return .updateRequired }
            switch reply.status {
            case 0:
                return .ready
            case ThermoFanXPC.recoveryRequiredStatus:
                return .recoveryBlocked
            case ThermoFanXPC.notConsoleUserStatus:
                return .inactiveSession
            case ThermoFanXPC.retiringStatus:
                return .updateRequired
            default:
                return .unreachable
            }
        @unknown default:
            return .unreachable
        }
    }

    /// User-facing explanation for a handshake that is not ready.
    static func readinessMessage(for handshake: Handshake) -> String {
        guard handshake.isVersionCurrent else {
            return "The registered Hardware Helper (protocol \(handshake.protocolVersion), revision \(handshake.implementationRevision)) does not match this app (protocol \(ThermoFanXPC.protocolVersion), revision \(ThermoFanXPC.implementationRevision)). Update the Hardware Helper before controlling fans."
        }
        switch handshake.status {
        case ThermoFanXPC.notConsoleUserStatus:
            return inactiveSessionMessage
        case ThermoFanXPC.retiringStatus:
            return "The Hardware Helper verified automatic control and is waiting to be replaced. Update the Hardware Helper before controlling fans."
        default:
            return handshake.message
        }
    }

    /// Validates a fan target against the daemon's safety envelope before any
    /// lease or hardware work. Returns a user-facing rejection, or `nil`.
    static func targetRejection(mode: ThermoFanXPC.Mode, rpm: Int?) -> String? {
        switch mode {
        case .automatic:
            guard rpm == nil || rpm == 0 else {
                return "Automatic mode does not accept an RPM target."
            }
            return nil
        case .fixed, .curve:
            guard let rpm else {
                return "A manual fan mode requires an RPM target. No hardware write was attempted."
            }
            guard (1...ThermoFanXPC.maximumRPM).contains(rpm) else {
                return "The RPM target \(rpm) is outside the Hardware Helper safety envelope (1–\(ThermoFanXPC.maximumRPM) RPM). No hardware write was attempted."
            }
            return nil
        }
    }

    // MARK: - Service registration

    func registerOrUpdateService() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard Self.bundleContainsDaemon else {
            return .failed("The signed app bundle is missing its LaunchDaemon payload. Reinstall ThermoFan from the release disk image.")
        }
        guard Self.isDeveloperIDBuild else {
            return .failed("Privileged runtime authorization requires a Developer ID signed ThermoFan app in Applications. Public downloads must also be notarized; this ad-hoc build remains monitoring-only.")
        }
        guard Self.isRunningFromApplications else {
            return .failed("Move ThermoFan to Applications before enabling fan control. The Hardware Helper cannot be registered from a disk image or temporary folder.")
        }

        let service = Self.service
        switch service.status {
        case .requiresApproval:
            Self.openLoginItemsSettings()
            return .failed(Self.approvalRequiredMessage)
        case .enabled:
            if let result = updateEnabledService(service) {
                return result
            }
            // The previous registration proved Auto and was removed.
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        return registerAndAwaitReadiness(service)
    }

    func unregisterService() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        let service = Self.service
        switch service.status {
        case .notRegistered:
            invalidateTransport(leaseLostReason: "The Hardware Helper is not registered.")
            return .applied("The Hardware Helper is not registered.")
        case .requiresApproval:
            Self.openLoginItemsSettings()
            return .recoveryRequired(
                "Re-enable ThermoFan in Login Items first so the daemon can prove automatic control; then retry Unregister."
            )
        case .notFound:
            return .recoveryRequired(
                "macOS could not resolve the Hardware Helper registration. Repair or re-register the notarized app before attempting verified removal."
            )
        case .enabled:
            do {
                let preparation = try sendPrepareForRemoval()
                guard preparation.status == 0 else {
                    return classify(preparation)
                }
                invalidateTransport(leaseLostReason: preparation.message)
                try unregisterAndWait(service)
                return .applied("Automatic control was verified and the Hardware Helper was unregistered.")
            } catch {
                return .recoveryRequired(
                    "The Hardware Helper remains registered because verified automatic recovery or unregister did not complete: \(error.localizedDescription)"
                )
            }
        @unknown default:
            return .failed("macOS returned an unknown Hardware Helper registration state.")
        }
    }

    /// Handles an already-enabled registration. Returns the final result, or
    /// `nil` when the previous daemon proved Auto and was unregistered so the
    /// caller must register the bundled daemon.
    private func updateEnabledService(_ service: SMAppService) -> Result? {
        let link: Link
        do {
            link = try handshakeForUpdate()
        } catch TransportError.timeout {
            // A busy daemon (startup recovery, legacy cleanup, or a long
            // hardware transaction) must never be unregistered.
            return .failed(
                "The registered Hardware Helper did not answer its authenticated handshake in time (helper busy, try again). It was left registered and no hardware write was attempted."
            )
        } catch TransportError.connection {
            // Only an NSXPC-level failure can mean that a future daemon
            // replaced the versioned handshake. The stable protocol-9 removal
            // path does not depend on that message.
            return retireThroughStableBoundary(service)
        } catch {
            return .failed(
                "The registered Hardware Helper could not be contacted: \(error.localizedDescription) It was left registered."
            )
        }

        let handshake = link.handshake
        guard handshake.isVersionCurrent else {
            return retireThroughStableBoundary(service)
        }
        switch handshake.status {
        case 0:
            return .applied("Authenticated Hardware Helper is ready.")
        case ThermoFanXPC.recoveryRequiredStatus:
            // Never remove a daemon whose Auto recovery is unverified; the
            // explicit recovery retry is the only path forward.
            return .recoveryRequired(
                "\(handshake.message) Retry verified automatic recovery; the Hardware Helper was left registered."
            )
        case ThermoFanXPC.notConsoleUserStatus:
            return .failed(Self.inactiveSessionMessage)
        case ThermoFanXPC.retiringStatus:
            // The daemon already verified Auto for a service-removal request
            // and refuses every write until it is unregistered.
            invalidateTransport(leaseLostReason: Self.readinessMessage(for: handshake))
            do {
                try unregisterAndWait(service)
            } catch {
                return .failed("The retiring Hardware Helper could not be unregistered: \(error.localizedDescription)")
            }
            return nil
        default:
            return .failed(handshake.message)
        }
    }

    /// Versioned handshake for an enabled registration. A daemon relaunch also
    /// interrupts the first connection, so an NSXPC-level failure is retried
    /// once on a fresh connection before it is treated as a changed protocol.
    private func handshakeForUpdate() throws -> Link {
        do {
            return try ensureHandshake(timeout: Timing.handshake)
        } catch TransportError.connection {
            return try ensureHandshake(timeout: Timing.handshake)
        }
    }

    /// Proves Auto through the permanent protocol-9 selectors, then
    /// unregisters. Returns `nil` after a verified removal.
    private func retireThroughStableBoundary(_ service: SMAppService) -> Result? {
        do {
            let preparation = try sendPrepareForRemoval()
            guard preparation.status == 0 else {
                return classify(preparation)
            }
            invalidateTransport(leaseLostReason: preparation.message)
        } catch {
            return .recoveryRequired(
                "The registered Hardware Helper could not prove automatic control through the stable recovery boundary. It was left registered to avoid interrupting an unknown fan state: \(error.localizedDescription)"
            )
        }
        do {
            try unregisterAndWait(service)
        } catch {
            return .failed("The old Hardware Helper could not be safely unregistered: \(error.localizedDescription)")
        }
        return nil
    }

    private func registerAndAwaitReadiness(_ service: SMAppService) -> Result {
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                Self.openLoginItemsSettings()
                return .failed("Approval required: macOS registered the Hardware Helper, but an administrator must approve it in System Settings → General → Login Items.")
            }
            return .failed("Hardware Helper registration failed: \(error.localizedDescription)")
        }

        switch service.status {
        case .requiresApproval:
            Self.openLoginItemsSettings()
            return .failed("Approval required: Hardware Helper registration is waiting for administrator approval in System Settings → General → Login Items. No hardware write was attempted.")
        case .enabled:
            return awaitRegisteredHelperReadiness()
        case .notRegistered, .notFound:
            return .failed("macOS did not retain the Hardware Helper registration. Reinstall the notarized app in Applications and try again.")
        @unknown default:
            return .failed("macOS returned an unknown Hardware Helper registration state.")
        }
    }

    /// Polls the handshake every 2 s for up to 30 s after registration.
    private func awaitRegisteredHelperReadiness() -> Result {
        invalidateTransport(leaseLostReason: "The Hardware Helper was re-registered.")
        let deadline = Deadline(timeout: Timing.postRegisterReadiness)
        var lastError: Error?
        while deadline.remaining > 0 {
            let attemptStart = ProcessInfo.processInfo.systemUptime
            do {
                let handshake = try ensureHandshake(timeout: deadline.budget(Timing.handshake)).handshake
                guard handshake.isVersionCurrent else {
                    return .failed("Hardware Helper registration completed, but its authenticated protocol does not match this app.")
                }
                switch handshake.status {
                case 0:
                    return .applied("Authenticated Hardware Helper is registered and ready.")
                case ThermoFanXPC.recoveryRequiredStatus:
                    return .recoveryRequired(handshake.message)
                default:
                    return .failed(Self.readinessMessage(for: handshake))
                }
            } catch TransportError.unavailable(let message) {
                // A local precondition cannot be fixed by waiting.
                return .failed("Hardware Helper was registered but cannot be contacted: \(message)")
            } catch {
                lastError = error
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - attemptStart
            let pause = min(max(0, Timing.postRegisterPollInterval - elapsed), deadline.remaining)
            if pause > 0 {
                Thread.sleep(forTimeInterval: pause)
            }
        }
        let detail = lastError?.localizedDescription ?? "No handshake answer was received."
        return .failed(
            "Hardware Helper was registered but did not complete its authenticated readiness handshake within \(Int(Timing.postRegisterReadiness)) seconds: \(detail) It remains registered; try again shortly."
        )
    }

    // MARK: - Leases and fan commands

    func armWatchdog(fanIndex: Int) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex) else {
            throw TransportError.unavailable("Invalid fan index.")
        }

        let link: Link
        do {
            link = try readyLink()
        } catch TransportError.notReady(let handshake) {
            // The daemon will not honor any other lease in this state either.
            invalidateTransport(onlyIfLeased: true, leaseLostReason: Self.readinessMessage(for: handshake))
            throw TransportError.notReady(handshake)
        }
        stateLock.lock()
        let transportIsCurrent = link.generation == connectionGeneration
        stateLock.unlock()
        guard transportIsCurrent else {
            throw TransportError.unavailable("The authenticated Hardware Helper connection ended before the watchdog could be armed.")
        }

        let response: RPCResponse
        do {
            response = try sendRPC(link.connection, timeout: Timing.arm, operation: "arm the crash watchdog") { proxy, reply in
                proxy.armWatchdog(protocolVersion: ThermoFanXPC.protocolVersion, fanIndex: fanIndex, reply: reply)
            }
        } catch {
            // The daemon may have armed a session; closing the connection makes
            // it recover that session instead of trusting an unknown lease.
            invalidateTransport(
                generation: link.generation,
                leaseLostReason: "Arming the crash watchdog became uncertain, so the connection was closed and the daemon returns ThermoFan-owned fans to automatic control."
            )
            throw error
        }
        guard response.status == 0 else {
            if Self.endsSession(response.status) {
                invalidateTransport(generation: link.generation, leaseLostReason: response.message)
            }
            throw TransportError.refused(status: response.status, message: response.message)
        }

        stateLock.lock()
        guard link.generation == connectionGeneration,
              let currentConnection = connection,
              currentConnection === link.connection
        else {
            stateLock.unlock()
            throw TransportError.unavailable(
                "The Hardware Helper connection ended while the watchdog was being armed; automatic recovery remains authoritative."
            )
        }
        armedFans.insert(fanIndex)
        leaseGeneration &+= 1
        startHeartbeatLocked()
        stateLock.unlock()
    }

    func apply(fanIndex: Int, mode: ThermoFanXPC.Mode, rpm: Int?) -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex) else {
            return .failed("The Hardware Helper rejected an invalid fan index.")
        }
        if let rejection = Self.targetRejection(mode: mode, rpm: rpm) {
            return .failed(rejection)
        }
        // Captured before the handshake: a transport failure during the
        // handshake clears the local lease bits, and a dropped lease must be
        // reported as uncertain, never as "no lease was armed".
        let wasArmed = isFanArmed(fanIndex)
        if mode != .automatic, !wasArmed {
            return .failed("Hardware write was blocked because no verified crash watchdog lease is active for fan \(fanIndex + 1).")
        }
        let target = mode == .automatic ? 0 : (rpm ?? 0)

        let link: Link
        do {
            link = try readyLink()
        } catch TransportError.notReady(let handshake) {
            let message = Self.readinessMessage(for: handshake)
            // The daemon will not honor an existing lease in this state.
            invalidateTransport(onlyIfLeased: true, leaseLostReason: message)
            if handshake.isVersionCurrent, handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                return .recoveryRequired(message)
            }
            return .failed(message)
        } catch TransportError.unavailable(let message) where !wasArmed {
            // Nothing was sent and no lease exists: a definitive local refusal.
            return .failed(message)
        } catch {
            if wasArmed || mode == .automatic {
                invalidateTransport(
                    leaseLostReason: "The authenticated Hardware Helper connection failed, so the daemon returns ThermoFan-owned fans to automatic control: \(error.localizedDescription)"
                )
                return .recoveryRequired("The authenticated Hardware Helper connection failed; automatic recovery was requested: \(error.localizedDescription)")
            }
            return .failed("Hardware Helper connection failed before a watchdog lease was armed: \(error.localizedDescription)")
        }

        stateLock.lock()
        let transportIsCurrent = link.generation == connectionGeneration
        let leaseIsIntact = mode == .automatic || armedFans.contains(fanIndex)
        revision &+= 1
        let requestRevision = revision
        stateLock.unlock()
        guard transportIsCurrent, leaseIsIntact else {
            // The heartbeat or transport handlers ended the lease while the
            // handshake was in flight and already reported it.
            return .recoveryRequired(
                "The Hardware Helper connection ended before the fan command was sent; the daemon returns ThermoFan-owned fans to automatic control."
            )
        }

        let response: RPCResponse
        do {
            response = try sendRPC(link.connection, timeout: Timing.apply, operation: "verify the fan command") { proxy, reply in
                proxy.applyFan(
                    protocolVersion: ThermoFanXPC.protocolVersion,
                    fanIndex: fanIndex,
                    mode: mode.rawValue,
                    rpm: target,
                    revision: requestRevision,
                    reply: reply
                )
            }
        } catch {
            // The request may have reached hardware. Closing the connection
            // forces daemon-side Auto recovery; never report an uncertain
            // transport failure as a verified non-write.
            invalidateTransport(
                generation: link.generation,
                leaseLostReason: "A fan command result became uncertain, so the connection was closed and the daemon returns ThermoFan-owned fans to automatic control."
            )
            return .recoveryRequired("The fan command result became uncertain, so the watchdog connection was closed to force automatic recovery: \(error.localizedDescription)")
        }

        if response.status == 0 {
            if mode == .automatic {
                disarmFanAfterVerifiedAutomatic(fanIndex)
            }
        } else if Self.endsSession(response.status) {
            // The daemon has ended (or refuses) this connection's session.
            // Drop every local lease bit so the next manual request re-arms on
            // a fresh connection.
            invalidateTransport(generation: link.generation, leaseLostReason: response.message)
        }
        return classify(response)
    }

    /// Retries the daemon's verified automatic recovery without touching
    /// service registration. Safe in `.recoveryBlocked` and while retiring.
    func retryAutomaticRecovery() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            let link = try ensureHandshake(timeout: Timing.handshake)
            guard link.handshake.protocolVersion == ThermoFanXPC.protocolVersion else {
                return .failed(Self.readinessMessage(for: link.handshake))
            }
            let response = try sendRPC(link.connection, timeout: Timing.recovery, operation: "retry verified automatic recovery") { proxy, reply in
                proxy.retryAutomaticRecovery(protocolVersion: ThermoFanXPC.protocolVersion, reply: reply)
            }
            return finishRecovery(response, link: link)
        } catch TransportError.unavailable(let message) {
            return .failed(message)
        } catch {
            invalidateTransport(
                leaseLostReason: "The automatic recovery retry became uncertain, so the connection was closed and the daemon recovery supervisor remains authoritative."
            )
            return .recoveryRequired("The automatic recovery retry result became uncertain; the connection was closed and the daemon recovery supervisor remains authoritative: \(error.localizedDescription)")
        }
    }

    /// Asks the daemon to return every fan this session owns to Auto and
    /// reports the daemon's verified answer, even when no local lease is
    /// known. `timeout` bounds the whole call, including waiting for another
    /// in-flight operation; `nil` keeps the default per-step waits.
    func returnAllToAutomatic(timeout: TimeInterval? = nil) -> Result {
        let deadline = Deadline(timeout: timeout)
        if let lockLimit = deadline.lockLimit {
            guard operationLock.lock(before: lockLimit) else {
                return .recoveryRequired(
                    "Another Hardware Helper operation was still running, so automatic recovery could not be requested in time. The daemon's process-exit watchdog and recovery supervisor remain authoritative."
                )
            }
        } else {
            operationLock.lock()
        }
        defer { operationLock.unlock() }

        var attempt = 0
        while true {
            attempt += 1
            do {
                let link = try ensureHandshake(timeout: deadline.budget(Timing.handshake))
                let handshake = link.handshake
                if handshake.protocolVersion == ThermoFanXPC.protocolVersion,
                   handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                    let response = try sendRPC(link.connection, timeout: deadline.budget(Timing.recovery), operation: "retry verified automatic recovery") { proxy, reply in
                        proxy.retryAutomaticRecovery(protocolVersion: ThermoFanXPC.protocolVersion, reply: reply)
                    }
                    return finishRecovery(response, link: link)
                }
                guard handshake.isReady else {
                    // Inactive session, retiring, or version mismatch: the
                    // daemon will not honor a session-scoped request here.
                    let message = Self.readinessMessage(for: handshake)
                    invalidateTransport(generation: link.generation, onlyIfLeased: true, leaseLostReason: message)
                    return .failed(message)
                }
                let response = try sendRPC(link.connection, timeout: deadline.budget(Timing.recovery), operation: "return all owned fans to automatic control") { proxy, reply in
                    proxy.returnAllFansToAutomatic(protocolVersion: ThermoFanXPC.protocolVersion, reply: reply)
                }
                if response.status == ThermoFanXPC.leaseLostStatus, attempt == 1 {
                    // The daemon already ended this connection's session. Ask
                    // once more on a fresh connection so the answer covers the
                    // daemon's current ownership rather than the stale session.
                    invalidateTransport(generation: link.generation, leaseLostReason: response.message)
                    continue
                }
                return finishRecovery(response, link: link)
            } catch TransportError.unavailable(let message) {
                return .failed(message)
            } catch {
                invalidateTransport(
                    leaseLostReason: "The all-fan automatic recovery result became uncertain, so the connection was closed and the daemon recovery supervisor remains authoritative."
                )
                return .recoveryRequired("The all-fan automatic recovery result became uncertain; the connection was closed and the daemon recovery supervisor remains authoritative: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Transport

    private static var service: SMAppService {
        SMAppService.daemon(plistName: ThermoFanXPC.daemonPlistName)
    }

    /// Strict `SecStaticCodeCheckValidity` results for this process. The
    /// running binary's signature cannot change underneath it, so both are
    /// evaluated once instead of on every helper-state refresh.
    private static let isDeveloperIDBuild: Bool =
        ThermoFanXPC.currentCodeIsDeveloperID(identifier: ThermoFanXPC.appIdentifier)
    private static let helperPeerRequirement: String? = ThermoFanXPC.peerRequirement(
        identifier: ThermoFanXPC.helperIdentifier,
        currentIdentifier: ThermoFanXPC.appIdentifier
    )

    /// `Bundle.main.bundleURL` is fixed for the process lifetime.
    private static let isRunningFromApplications: Bool = Bundle.main.bundleURL
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path == "/Applications/ThermoFan.app"

    private static var bundleContainsDaemon: Bool {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ThermoFanHelper", isDirectory: false)
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(ThermoFanXPC.daemonPlistName, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: helper.path)
            && FileManager.default.fileExists(atPath: plist.path)
    }

    private static func openLoginItemsSettings() {
        DispatchQueue.main.async {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Statuses after which the daemon no longer honors this connection's
    /// lease: recovery required, lease lost, inactive console session, or
    /// retiring for service removal.
    private static func endsSession(_ status: Int) -> Bool {
        status == ThermoFanXPC.recoveryRequiredStatus
            || status == ThermoFanXPC.leaseLostStatus
            || status == ThermoFanXPC.notConsoleUserStatus
            || status == ThermoFanXPC.retiringStatus
    }

    /// Requires `operationLock`.
    private func ensureHandshake(timeout: TimeInterval) throws -> Link {
        guard timeout > 0 else {
            throw TransportError.timeout("The time budget ended before the Hardware Helper could be authenticated.")
        }
        let (activeConnection, generation) = try ensureTransport()

        let waiter = Waiter<Handshake>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.connection(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            invalidateTransport(generation: generation, leaseLostReason: "The Hardware Helper XPC protocol is unavailable.")
            throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
        }
        // This first normal-protocol message is intentionally side-effect free.
        // The stable service-removal selector uses the authenticated transport
        // directly and does not depend on this versioned handshake.
        proxy.handshake(protocolVersion: ThermoFanXPC.protocolVersion) {
            protocolVersion, implementationRevision, status, message in
            waiter.finish(.success(Handshake(
                protocolVersion: protocolVersion,
                implementationRevision: implementationRevision,
                status: status,
                message: message
            )))
        }

        do {
            let handshake = try waiter.wait(seconds: timeout, operation: "authenticate the Hardware Helper")
            return Link(connection: activeConnection, generation: generation, handshake: handshake)
        } catch {
            invalidateTransport(
                generation: generation,
                leaseLostReason: "The Hardware Helper did not complete its authenticated handshake, so the connection was closed and the daemon returns ThermoFan-owned fans to automatic control: \(error.localizedDescription)"
            )
            throw error
        }
    }

    /// Requires `operationLock`. Throws `.notReady` when the daemon answered
    /// but does not accept privileged requests from this session.
    private func readyLink() throws -> Link {
        let link = try ensureHandshake(timeout: Timing.handshake)
        guard link.handshake.isReady else {
            throw TransportError.notReady(link.handshake)
        }
        return link
    }

    /// Requires `operationLock`: connections are only created by operations,
    /// never by handlers or the heartbeat.
    private func ensureTransport() throws -> (NSXPCConnection, UInt64) {
        stateLock.lock()
        if let existingConnection = connection {
            let generation = connectionGeneration
            stateLock.unlock()
            return (existingConnection, generation)
        }
        stateLock.unlock()

        guard let requirement = Self.helperPeerRequirement else {
            throw TransportError.unavailable("Privileged fan control requires a Developer ID signed release; ad-hoc builds are monitoring-only.")
        }
        guard Self.service.status == .enabled else {
            throw TransportError.unavailable("The Hardware Helper is not enabled by macOS.")
        }

        let newConnection = NSXPCConnection(
            machServiceName: ThermoFanXPC.helperIdentifier,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: ThermoFanDaemonProtocol.self)
        newConnection.setCodeSigningRequirement(requirement)

        stateLock.lock()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connection = newConnection
        stateLock.unlock()

        newConnection.interruptionHandler = { [weak self] in
            self?.transportEnded(generation: generation)
        }
        newConnection.invalidationHandler = { [weak self] in
            self?.transportEnded(generation: generation)
        }
        newConnection.activate()
        return (newConnection, generation)
    }

    private func sendRPC(
        _ activeConnection: NSXPCConnection,
        timeout: TimeInterval,
        operation: String,
        _ invoke: (ThermoFanDaemonProtocol, @escaping @Sendable (Int, String) -> Void) -> Void
    ) throws -> RPCResponse {
        guard timeout > 0 else {
            throw TransportError.timeout("The time budget ended before the Hardware Helper could \(operation).")
        }
        let waiter = Waiter<RPCResponse>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.connection(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
        }
        invoke(proxy) { status, message in
            waiter.finish(.success(RPCResponse(status: status, message: message)))
        }
        return try waiter.wait(seconds: timeout, operation: operation)
    }

    private func sendPrepareForRemoval() throws -> RPCResponse {
        // Always use a fresh authenticated transport so the permanent recovery
        // handshake is the first outgoing message even when a future helper's
        // normal versioned handshake is no longer compatible with this app.
        invalidateTransport(
            leaseLostReason: "The Hardware Helper connection was reset to verify automatic control before service removal; the daemon returns ThermoFan-owned fans to automatic control."
        )
        let (activeConnection, _) = try ensureTransport()
        let stableWaiter = Waiter<(Int, Int, Int, String)>()
        guard let stableProxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            stableWaiter.finish(.failure(TransportError.connection(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper stable recovery protocol is unavailable.")
        }
        // This harmless stable handshake must remain the first outgoing message
        // on a newly authenticated transport; removal is attempted only after
        // the daemon proves that it implements the permanent protocol-9 floor.
        stableProxy.recoveryHandshake { installedProtocol, stableFloor, status, message in
            stableWaiter.finish(.success((installedProtocol, stableFloor, status, message)))
        }
        let stable = try stableWaiter.wait(
            seconds: Timing.handshake,
            operation: "authenticate the stable Hardware Helper recovery boundary"
        )
        guard stable.0 >= ThermoFanXPC.stableRecoveryProtocolVersion,
              stable.1 == ThermoFanXPC.stableRecoveryProtocolVersion
        else {
            throw TransportError.unavailable(stable.3)
        }
        switch stable.2 {
        case 0, ThermoFanXPC.recoveryRequiredStatus, ThermoFanXPC.retiringStatus:
            break
        case ThermoFanXPC.notConsoleUserStatus:
            // A definitive refusal, not an uncertain fan state.
            return RPCResponse(status: stable.2, message: Self.inactiveSessionMessage)
        default:
            throw TransportError.unavailable(stable.3)
        }

        return try sendRPC(activeConnection, timeout: Timing.recovery, operation: "verify automatic control before service removal") { proxy, reply in
            proxy.prepareForServiceRemoval(reply: reply)
        }
    }

    private func unregisterAndWait(_ service: SMAppService) throws {
        let waiter = Waiter<Bool>()
        service.unregister { error in
            if let error {
                waiter.finish(.failure(error))
            } else {
                waiter.finish(.success(true))
            }
        }
        _ = try waiter.wait(seconds: Timing.unregister, operation: "unregister the previous Hardware Helper")
        guard service.status == .notRegistered else {
            throw TransportError.unavailable(
                "macOS completed the unregister callback but did not report the Hardware Helper as not registered."
            )
        }
    }

    /// 0 is verified; 75 (recovery required) and 76 (lease lost) are
    /// uncertain and need reconciliation; everything else (1, 77 inactive
    /// session, 78 retiring) is a definitive refusal.
    private func classify(_ response: RPCResponse) -> Result {
        switch response.status {
        case 0:
            .applied(response.message)
        case ThermoFanXPC.recoveryRequiredStatus, ThermoFanXPC.leaseLostStatus:
            .recoveryRequired(response.message)
        default:
            .failed(response.message)
        }
    }

    /// Applies the lease consequences of a recovery or return-to-Auto reply.
    private func finishRecovery(_ response: RPCResponse, link: Link) -> Result {
        if response.status == 0 {
            clearArmedState(leaseLostReason: response.message)
        } else if Self.endsSession(response.status) {
            invalidateTransport(generation: link.generation, leaseLostReason: response.message)
        }
        return classify(response)
    }

    // MARK: - Lease state

    private func isFanArmed(_ fanIndex: Int) -> Bool {
        stateLock.lock()
        let result = armedFans.contains(fanIndex)
        stateLock.unlock()
        return result
    }

    private func disarmFanAfterVerifiedAutomatic(_ fanIndex: Int) {
        stateLock.lock()
        armedFans.remove(fanIndex)
        if armedFans.isEmpty {
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
        }
        stateLock.unlock()
    }

    /// Drops every local lease bit after the daemon verified Auto, and tells
    /// the store which fans were returned.
    private func clearArmedState(leaseLostReason: String) {
        stateLock.lock()
        let returnedFans = armedFans
        armedFans.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        let handler = leaseLostHandler
        stateLock.unlock()
        deliverLeaseLost(returnedFans, reason: leaseLostReason, handler: handler)
    }

    private func startHeartbeatLocked() {
        guard heartbeatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now() + ThermoFanXPC.heartbeatInterval,
            repeating: ThermoFanXPC.heartbeatInterval,
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            // Routing through the main queue deliberately makes a hung UI stop
            // renewing the root daemon's lease.
            DispatchQueue.main.async { [weak self] in
                self?.sendHeartbeatAsynchronously()
            }
        }
        heartbeatTimer = timer
        timer.activate()
    }

    private func sendHeartbeatAsynchronously() {
        stateLock.lock()
        let activeConnection = connection
        let generation = connectionGeneration
        let lease = leaseGeneration
        let hasLease = !armedFans.isEmpty
        stateLock.unlock()
        guard hasLease, let activeConnection else { return }
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.heartbeatFailed(
                generation: generation,
                leaseGeneration: lease,
                reason: "The watchdog heartbeat could not reach the Hardware Helper, so the daemon returns ThermoFan-owned fans to automatic control: \(error.localizedDescription)"
            )
        }) as? ThermoFanDaemonProtocol else {
            heartbeatFailed(
                generation: generation,
                leaseGeneration: lease,
                reason: "The Hardware Helper XPC protocol is unavailable for the watchdog heartbeat."
            )
            return
        }
        proxy.heartbeat(protocolVersion: ThermoFanXPC.protocolVersion) { [weak self] status, message in
            guard status != 0 else { return }
            self?.heartbeatFailed(
                generation: generation,
                leaseGeneration: lease,
                reason: "The Hardware Helper ended the watchdog lease: \(message)"
            )
        }
    }

    /// Ignores a stale failure: the connection was already replaced, a fresh
    /// lease was armed after the heartbeat was sent, or nothing is leased.
    private func heartbeatFailed(generation: UInt64, leaseGeneration: UInt64, reason: String) {
        invalidateTransport(
            generation: generation,
            leaseGeneration: leaseGeneration,
            onlyIfLeased: true,
            leaseLostReason: reason
        )
    }

    private func transportEnded(generation: UInt64) {
        // Also invalidates an interrupted connection so it is not leaked; the
        // generation bump makes its own invalidation callback a no-op.
        invalidateTransport(
            generation: generation,
            leaseLostReason: "The Hardware Helper connection was interrupted or invalidated; the daemon returns ThermoFan-owned fans to automatic control."
        )
    }

    /// Drops the transport and every local lease bit, then invalidates the old
    /// connection outside the lock. Each guard makes the call a no-op:
    /// `generation` when the transport was already replaced, `leaseGeneration`
    /// when a newer lease was armed, `onlyIfLeased` when no fan is leased.
    /// When `leaseLostReason` is non-nil and fans were leased, `onLeaseLost`
    /// fires with them.
    private func invalidateTransport(
        generation expectedGeneration: UInt64? = nil,
        leaseGeneration expectedLeaseGeneration: UInt64? = nil,
        onlyIfLeased: Bool = false,
        leaseLostReason: String?
    ) {
        stateLock.lock()
        if let expectedGeneration, expectedGeneration != connectionGeneration {
            stateLock.unlock()
            return
        }
        if let expectedLeaseGeneration, expectedLeaseGeneration != leaseGeneration {
            stateLock.unlock()
            return
        }
        if onlyIfLeased, armedFans.isEmpty {
            stateLock.unlock()
            return
        }
        connectionGeneration &+= 1
        let oldConnection = connection
        connection = nil
        let lostFans = armedFans
        armedFans.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        let handler = leaseLostHandler
        stateLock.unlock()

        oldConnection?.invalidate()
        if let leaseLostReason {
            deliverLeaseLost(lostFans, reason: leaseLostReason, handler: handler)
        }
    }

    private func deliverLeaseLost(
        _ fans: Set<Int>,
        reason: String,
        handler: (@Sendable (Set<Int>, String) -> Void)?
    ) {
        guard !fans.isEmpty, let handler else { return }
        notificationQueue.async {
            handler(fans, reason)
        }
    }
}
