import AppKit
import FanControlXPC
import Foundation
import ServiceManagement

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

        var isCurrent: Bool {
            protocolVersion == ThermoFanXPC.protocolVersion
                && implementationRevision == ThermoFanXPC.implementationRevision
                && status == 0
        }
    }

    private enum TransportError: Error, LocalizedError, Sendable {
        case unavailable(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let message), .timeout(let message): message
            }
        }
    }

    private struct RPCResponse: Sendable {
        let status: Int
        let message: String
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
            guard semaphore.wait(timeout: .now() + seconds) == .success else {
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
    private var connection: NSXPCConnection?
    private var connectionGeneration: UInt64 = 0
    private var armedFans: Set<Int> = []
    private var revision: UInt64 = 0
    private var heartbeatTimer: DispatchSourceTimer?

    /// Called off the main actor with the fan indexes whose lease ended
    /// without an app-initiated Auto, plus a human-readable reason.
    var onLeaseLost: (@Sendable (Set<Int>, String) -> Void)?

    deinit {
        invalidateTransport()
    }

    var serviceState: HardwareHelperState {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard Self.bundleContainsDaemon else { return .updateRequired }
        guard Self.isRunningFromApplications else { return .updateRequired }
        guard ThermoFanXPC.currentCodeIsDeveloperID(identifier: ThermoFanXPC.appIdentifier) else {
            return .updateRequired
        }

        switch Self.service.status {
        case .notRegistered:
            return .missing
        case .requiresApproval:
            return .approvalRequired
        case .notFound:
            return .updateRequired
        case .enabled:
            do {
                let handshake = try ensureHandshake()
                if handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                    return .recoveryBlocked
                }
                return handshake.isCurrent ? .ready : .updateRequired
            } catch {
                return .updateRequired
            }
        @unknown default:
            return .updateRequired
        }
    }

    func registerOrUpdateService() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard Self.bundleContainsDaemon else {
            return .failed("The signed app bundle is missing its LaunchDaemon payload. Reinstall ThermoFan from the release disk image.")
        }
        guard Self.isRunningFromApplications else {
            return .failed("Move ThermoFan to Applications before enabling fan control. The Hardware Helper cannot be registered from a disk image or temporary folder.")
        }
        guard ThermoFanXPC.currentCodeIsDeveloperID(identifier: ThermoFanXPC.appIdentifier) else {
            return .failed("Privileged runtime authorization requires a Developer ID signed ThermoFan app in Applications. Public downloads must also be notarized; this ad-hoc build remains monitoring-only.")
        }

        let service = Self.service
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return .failed("Approve ThermoFan under System Settings → General → Login Items, then return and try again. No hardware write was attempted.")
        }

        if service.status == .enabled {
            var helperIsCurrent = false
            do {
                helperIsCurrent = try ensureHandshake().isCurrent
            } catch {
                // A future daemon may change the normal handshake. The stable
                // protocol-9 removal selector below deliberately does not
                // depend on that versioned readiness message.
                invalidateTransport()
            }
            if helperIsCurrent {
                return .applied("Authenticated Hardware Helper is ready.")
            }
            do {
                let preparation = try sendPrepareForRemoval()
                guard preparation.status == 0 else {
                    return classify(preparation)
                }
                invalidateTransport()
                do {
                    try unregisterAndWait(service)
                } catch {
                    return .failed("The old Hardware Helper could not be safely unregistered: \(error.localizedDescription)")
                }
            } catch {
                return .recoveryRequired(
                    "The registered Hardware Helper could not prove automatic control through the stable recovery boundary. It was left registered to avoid interrupting an unknown fan state: \(error.localizedDescription)"
                )
            }
        }

        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return .failed("macOS registered the Hardware Helper, but an administrator must approve it in System Settings → General → Login Items.")
            }
            return .failed("Hardware Helper registration failed: \(error.localizedDescription)")
        }

        switch service.status {
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return .failed("Hardware Helper registration is waiting for administrator approval in System Settings → General → Login Items. No hardware write was attempted.")
        case .enabled:
            invalidateTransport()
            do {
                let handshake = try ensureHandshake()
                if handshake.isCurrent {
                    return .applied("Authenticated Hardware Helper is registered and ready.")
                }
                if handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                    return .recoveryRequired(handshake.message)
                }
                return .failed("Hardware Helper registration completed, but its authenticated protocol does not match this app.")
            } catch {
                return .failed("Hardware Helper was registered but did not complete its authenticated readiness handshake: \(error.localizedDescription)")
            }
        case .notRegistered, .notFound:
            return .failed("macOS did not retain the Hardware Helper registration. Reinstall the notarized app in Applications and try again.")
        @unknown default:
            return .failed("macOS returned an unknown Hardware Helper registration state.")
        }
    }

    func unregisterService() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        let service = Self.service
        switch service.status {
        case .notRegistered:
            invalidateTransport()
            return .applied("The Hardware Helper is not registered.")
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
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
                invalidateTransport()
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

    func armWatchdog(fanIndex: Int) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex) else {
            throw TransportError.unavailable("Invalid fan index.")
        }
        let activeConnection = try currentReadyConnection()
        stateLock.lock()
        let generation = connectionGeneration
        let transportIsCurrent = connection.map { $0 === activeConnection } ?? false
        stateLock.unlock()
        guard transportIsCurrent else {
            throw TransportError.unavailable("The authenticated Hardware Helper connection ended before the watchdog could be armed.")
        }
        let waiter = Waiter<RPCResponse>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
        }
        proxy.armWatchdog(protocolVersion: ThermoFanXPC.protocolVersion, fanIndex: fanIndex) { status, message in
            waiter.finish(.success(RPCResponse(status: status, message: message)))
        }
        let response: RPCResponse
        do {
            response = try waiter.wait(seconds: 5, operation: "arm the crash watchdog")
        } catch {
            invalidateTransport(generation: generation)
            throw error
        }
        guard response.status == 0 else {
            throw TransportError.unavailable(response.message)
        }
        stateLock.lock()
        guard generation == connectionGeneration,
              let currentConnection = connection,
              currentConnection === activeConnection
        else {
            stateLock.unlock()
            throw TransportError.unavailable(
                "The Hardware Helper connection ended while the watchdog was being armed; automatic recovery remains authoritative."
            )
        }
        armedFans.insert(fanIndex)
        startHeartbeatLocked()
        stateLock.unlock()
    }

    func apply(fanIndex: Int, mode: ThermoFanXPC.Mode, rpm: Int?) -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard (0...ThermoFanXPC.maximumFanIndex).contains(fanIndex) else {
            return .failed("The Hardware Helper rejected an invalid fan index.")
        }
        if mode != .automatic, !isFanArmed(fanIndex) {
            return .failed("Hardware write was blocked because no verified crash watchdog lease is active for fan \(fanIndex + 1).")
        }
        let target = rpm ?? 0
        if mode == .automatic {
            guard rpm == nil || rpm == 0 else {
                return .failed("Automatic mode does not accept an RPM target.")
            }
        } else if target <= 0 || target > ThermoFanXPC.maximumRPM {
            return .failed("The RPM target is outside the Hardware Helper safety envelope.")
        }

        do {
            let activeConnection = try currentReadyConnection()
            stateLock.lock()
            revision &+= 1
            let requestRevision = revision
            stateLock.unlock()
            let waiter = Waiter<RPCResponse>()
            guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
                waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
            }) as? ThermoFanDaemonProtocol else {
                throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
            }
            proxy.applyFan(
                protocolVersion: ThermoFanXPC.protocolVersion,
                fanIndex: fanIndex,
                mode: mode.rawValue,
                rpm: target,
                revision: requestRevision
            ) { status, message in
                waiter.finish(.success(RPCResponse(status: status, message: message)))
            }
            let response: RPCResponse
            do {
                response = try waiter.wait(seconds: 25, operation: "verify the fan command")
            } catch {
                // The request may have reached hardware. Invalidating the
                // connection forces daemon-side Auto recovery; never report an
                // uncertain transport failure as a verified non-write.
                invalidateTransport()
                return .recoveryRequired("The fan command result became uncertain, so the watchdog connection was closed to force automatic recovery: \(error.localizedDescription)")
            }
            if response.status == ThermoFanXPC.leaseLostStatus {
                // The daemon has already abandoned this lease and recovered (or
                // is recovering) its durable state. Drop every local lease bit
                // so the next manual request must re-arm server-side first.
                invalidateTransport()
            } else if response.status == 0, mode == .automatic {
                disarmFanAfterVerifiedAutomatic(fanIndex)
            }
            return classify(response)
        } catch {
            if mode == .automatic || isFanArmed(fanIndex) {
                invalidateTransport()
                return .recoveryRequired("The authenticated Hardware Helper connection failed; automatic recovery was requested: \(error.localizedDescription)")
            }
            return .failed("Hardware Helper connection failed before a watchdog lease was armed: \(error.localizedDescription)")
        }
    }

    /// Retries the daemon's verified automatic recovery without touching
    /// service registration. Safe in `.recoveryBlocked`.
    func retryAutomaticRecovery() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            let response = try sendRecoveryRetry()
            if response.status == 0 {
                clearArmedState()
            }
            return classify(response)
        } catch {
            invalidateTransport()
            return .recoveryRequired("The automatic recovery retry result became uncertain; the connection was closed and the daemon recovery supervisor remains authoritative: \(error.localizedDescription)")
        }
    }

    func returnAllToAutomatic() -> Result {
        operationLock.lock()
        defer { operationLock.unlock() }
        do {
            let handshake = try ensureHandshake()
            if handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                let response = try sendRecoveryRetry()
                if response.status == 0 {
                    clearArmedState()
                }
                return classify(response)
            }
            guard handshake.isCurrent else {
                return .failed(handshake.message)
            }
            guard hasArmedFans else {
                return .applied("No ThermoFan-owned manual fans require recovery.")
            }
            let response = try sendReturnAll(requireCurrentRevision: true)
            if response.status == 0 {
                clearArmedState()
            }
            return classify(response)
        } catch {
            invalidateTransport()
            return .recoveryRequired("The all-fan automatic recovery result became uncertain; the connection was closed and the daemon recovery supervisor remains authoritative: \(error.localizedDescription)")
        }
    }

    static func helperState(
        serviceStatus: SMAppService.Status,
        hasDeveloperIDTeam: Bool,
        isInApplications: Bool,
        bundleContainsDaemon: Bool,
        handshake: Handshake?
    ) -> HardwareHelperState {
        guard hasDeveloperIDTeam, isInApplications, bundleContainsDaemon else {
            return .updateRequired
        }
        switch serviceStatus {
        case .notRegistered: return .missing
        case .notFound: return .updateRequired
        case .requiresApproval: return .approvalRequired
        case .enabled:
            guard let handshake else { return .updateRequired }
            if handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                return .recoveryBlocked
            }
            return handshake.isCurrent ? .ready : .updateRequired
        @unknown default: return .updateRequired
        }
    }

    private static var service: SMAppService {
        SMAppService.daemon(plistName: ThermoFanXPC.daemonPlistName)
    }

    private static var isRunningFromApplications: Bool {
        Bundle.main.bundleURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path == "/Applications/ThermoFan.app"
    }

    private static var bundleContainsDaemon: Bool {
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/ThermoFanHelper", isDirectory: false)
        let plist = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(ThermoFanXPC.daemonPlistName, isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: helper.path)
            && FileManager.default.fileExists(atPath: plist.path)
    }

    private func ensureHandshake() throws -> Handshake {
        let activeConnection = try ensureTransport()

        let waiter = Waiter<Handshake>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            invalidateTransport()
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
            return try waiter.wait(seconds: 5, operation: "authenticate the Hardware Helper")
        } catch {
            invalidateTransport()
            throw error
        }
    }

    private func ensureTransport() throws -> NSXPCConnection {
        guard let requirement = ThermoFanXPC.peerRequirement(
            identifier: ThermoFanXPC.helperIdentifier,
            currentIdentifier: ThermoFanXPC.appIdentifier
        ) else {
            throw TransportError.unavailable("Privileged fan control requires a Developer ID signed release; ad-hoc builds are monitoring-only.")
        }
        guard Self.service.status == .enabled else {
            throw TransportError.unavailable("The Hardware Helper is not enabled by macOS.")
        }

        stateLock.lock()
        let existingConnection = connection
        let existingGeneration = connectionGeneration
        stateLock.unlock()

        let activeConnection: NSXPCConnection
        let generation: UInt64
        if let existingConnection {
            activeConnection = existingConnection
            generation = existingGeneration
        } else {
            let newConnection = NSXPCConnection(
                machServiceName: ThermoFanXPC.helperIdentifier,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(with: ThermoFanDaemonProtocol.self)
            newConnection.setCodeSigningRequirement(requirement)

            stateLock.lock()
            connectionGeneration &+= 1
            generation = connectionGeneration
            connection = newConnection
            stateLock.unlock()

            newConnection.interruptionHandler = { [weak self] in
                self?.transportEnded(generation: generation)
            }
            newConnection.invalidationHandler = { [weak self] in
                self?.transportEnded(generation: generation)
            }
            newConnection.activate()
            activeConnection = newConnection
        }
        return activeConnection
    }

    private func currentReadyConnection() throws -> NSXPCConnection {
        let handshake = try ensureHandshake()
        guard handshake.isCurrent else {
            if handshake.status == ThermoFanXPC.recoveryRequiredStatus {
                throw TransportError.unavailable(handshake.message)
            }
            throw TransportError.unavailable("The app and Hardware Helper versions do not match.")
        }
        stateLock.lock()
        let activeConnection = connection
        stateLock.unlock()
        guard let activeConnection else {
            throw TransportError.unavailable("The authenticated Hardware Helper connection ended.")
        }
        return activeConnection
    }

    private func sendReturnAll(requireCurrentRevision: Bool) throws -> RPCResponse {
        let handshake = try ensureHandshake()
        guard handshake.protocolVersion == ThermoFanXPC.protocolVersion else {
            throw TransportError.unavailable("The installed helper cannot negotiate safe automatic recovery with this protocol.")
        }
        if requireCurrentRevision, !handshake.isCurrent {
            throw TransportError.unavailable("The Hardware Helper implementation does not match this app.")
        }
        stateLock.lock()
        let activeConnection = connection
        stateLock.unlock()
        guard let activeConnection else {
            throw TransportError.unavailable("The authenticated Hardware Helper connection ended.")
        }
        let waiter = Waiter<RPCResponse>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
        }
        proxy.returnAllFansToAutomatic(protocolVersion: ThermoFanXPC.protocolVersion) { status, message in
            waiter.finish(.success(RPCResponse(status: status, message: message)))
        }
        return try waiter.wait(seconds: 90, operation: "return all owned fans to automatic control")
    }

    private func sendRecoveryRetry() throws -> RPCResponse {
        let handshake = try ensureHandshake()
        guard handshake.protocolVersion == ThermoFanXPC.protocolVersion else {
            throw TransportError.unavailable("The installed helper cannot negotiate this recovery protocol.")
        }
        stateLock.lock()
        let activeConnection = connection
        stateLock.unlock()
        guard let activeConnection else {
            throw TransportError.unavailable("The authenticated Hardware Helper connection ended.")
        }
        let waiter = Waiter<RPCResponse>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper XPC protocol is unavailable.")
        }
        proxy.retryAutomaticRecovery(protocolVersion: ThermoFanXPC.protocolVersion) { status, message in
            waiter.finish(.success(RPCResponse(status: status, message: message)))
        }
        return try waiter.wait(seconds: 90, operation: "retry verified automatic recovery")
    }

    private func sendPrepareForRemoval() throws -> RPCResponse {
        // Always use a fresh authenticated transport so the permanent recovery
        // handshake is the first outgoing message even when a future helper's
        // normal versioned handshake is no longer compatible with this app.
        invalidateTransport()
        let activeConnection = try ensureTransport()
        let stableWaiter = Waiter<(Int, Int, Int, String)>()
        guard let stableProxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            stableWaiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
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
            seconds: 5,
            operation: "authenticate the stable Hardware Helper recovery boundary"
        )
        guard stable.0 >= ThermoFanXPC.stableRecoveryProtocolVersion,
              stable.1 == ThermoFanXPC.stableRecoveryProtocolVersion,
              stable.2 == 0 || stable.2 == ThermoFanXPC.recoveryRequiredStatus
        else {
            throw TransportError.unavailable(stable.3)
        }

        let waiter = Waiter<RPCResponse>()
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ error in
            waiter.finish(.failure(TransportError.unavailable(error.localizedDescription)))
        }) as? ThermoFanDaemonProtocol else {
            throw TransportError.unavailable("The Hardware Helper recovery protocol is unavailable.")
        }
        proxy.prepareForServiceRemoval { status, message in
            waiter.finish(.success(RPCResponse(status: status, message: message)))
        }
        return try waiter.wait(seconds: 90, operation: "verify automatic control before service removal")
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
        _ = try waiter.wait(seconds: 20, operation: "unregister the previous Hardware Helper")
        guard service.status == .notRegistered else {
            throw TransportError.unavailable(
                "macOS completed the unregister callback but did not report the Hardware Helper as not registered."
            )
        }
    }

    private func classify(_ response: RPCResponse) -> Result {
        if response.status == 0 {
            return .applied(response.message)
        }
        if response.status == ThermoFanXPC.recoveryRequiredStatus {
            return .recoveryRequired(response.message)
        }
        return .failed(response.message)
    }

    private var hasArmedFans: Bool {
        stateLock.lock()
        let result = !armedFans.isEmpty
        stateLock.unlock()
        return result
    }

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

    private func clearArmedState() {
        stateLock.lock()
        armedFans.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        stateLock.unlock()
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
        let hasLease = !armedFans.isEmpty
        stateLock.unlock()
        guard hasLease, let activeConnection else { return }
        guard let proxy = activeConnection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.invalidateTransport(generation: generation)
        }) as? ThermoFanDaemonProtocol else {
            invalidateTransport(generation: generation)
            return
        }
        proxy.heartbeat(protocolVersion: ThermoFanXPC.protocolVersion) { [weak self] status, _ in
            if status != 0 {
                self?.invalidateTransport(generation: generation)
            }
        }
    }

    private func transportEnded(generation: UInt64) {
        stateLock.lock()
        guard generation == connectionGeneration else {
            stateLock.unlock()
            return
        }
        connection = nil
        armedFans.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        stateLock.unlock()
    }

    private func invalidateTransport(generation expectedGeneration: UInt64? = nil) {
        stateLock.lock()
        if let expectedGeneration, expectedGeneration != connectionGeneration {
            stateLock.unlock()
            return
        }
        connectionGeneration &+= 1
        let oldConnection = connection
        connection = nil
        armedFans.removeAll()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        stateLock.unlock()
        oldConnection?.invalidate()
    }
}
