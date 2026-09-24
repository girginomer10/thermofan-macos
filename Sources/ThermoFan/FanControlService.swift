import FanControlXPC
import Foundation

/// Application-facing facade for the authenticated SMAppService LaunchDaemon.
/// The root daemon, not this process, owns all bounds checks, SMC writes,
/// durable ownership, watchdog leases, and rollback verification.
///
/// Every member except `cachedHelperState`, `onLeaseLost`, and
/// `returnAllToAutomatic(timeout:)` blocks on launchd or XPC and must run on
/// the store's control queue, never on the main actor.
final class FanControlService: @unchecked Sendable {
    /// The daemon's recovery-required status, still referenced by the C
    /// ownership-policy tests in `HardwareCompatibilityTests`.
    static let recoveryRequiredExitCode: Int32 = Int32(ThermoFanXPC.recoveryRequiredStatus)

    static let legacyManualControlMessage =
        "Security upgrade required: an older privileged ThermoFan helper is still installed. Manual fan control stays blocked until the authenticated Hardware Helper migration removes it. No hardware write was attempted."

    enum ApplyResult {
        case applied(String)
        case failed(String)
        case recoveryRequired(String)
    }

    enum FanControlError: Error, LocalizedError {
        case invalidFanIdentifier(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFanIdentifier(let id): "Invalid fan identifier '\(id)'."
            case .processFailed(let message): message
            }
        }
    }

    private let client: PrivilegedFanClient
    private static let legacyHelperPaths = [
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version"
    ]

    // Guarded by `cacheLock`.
    private let cacheLock = NSLock()
    private var cachedState: HardwareHelperState = .missing
    private var leaseLostHandler: (@Sendable ([String], String) -> Void)?

    /// Invoked asynchronously, off the main actor, with the fan IDs
    /// (`fan{i}`) whose privileged manual lease ended: heartbeat expiry, XPC
    /// interruption, daemon restart, console-user change, a lease-ending
    /// status from the daemon, an uncertain result, or a verified
    /// `returnAllToAutomatic`/`retryAutomaticRecovery` that returned fans the
    /// app still held. The reason says which. The store must reconcile its UI;
    /// the notification may arrive before or after the result of the call
    /// that caused it.
    var onLeaseLost: (@Sendable ([String], String) -> Void)? {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return leaseLostHandler
        }
        set {
            cacheLock.lock()
            leaseLostHandler = newValue
            cacheLock.unlock()
            guard let handler = newValue else {
                client.onLeaseLost = nil
                return
            }
            client.onLeaseLost = { indexes, reason in
                handler(indexes.sorted().map { "fan\($0)" }, reason)
            }
        }
    }

    init(client: PrivilegedFanClient = PrivilegedFanClient()) {
        self.client = client
    }

    /// Blocking: performs the `SMAppService` and handshake checks (the code
    /// signature checks are cached per process). Call only from the control
    /// queue, never from the main actor.
    var persistentHelperState: HardwareHelperState {
        let resolved = Self.resolvedState(client.serviceState, hasLegacyHelper: hasLegacyPrivilegedHelper)
        cacheLock.lock()
        cachedState = resolved
        cacheLock.unlock()
        return resolved
    }

    /// Blocking refresh that also updates `cachedHelperState`.
    func refreshHelperState() -> HardwareHelperState {
        persistentHelperState
    }

    /// Non-blocking snapshot of the last computed helper state. Safe to read
    /// from the main actor on every refresh tick.
    var cachedHelperState: HardwareHelperState {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedState
    }

    /// A leftover setuid helper takes precedence only over states that the
    /// registration action can resolve. Build, location, session, and
    /// recovery states stay visible because registering cannot fix them.
    static func resolvedState(_ state: HardwareHelperState, hasLegacyHelper: Bool) -> HardwareHelperState {
        guard hasLegacyHelper else { return state }
        switch state {
        case .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired, .ready, .unreachable:
            return .legacyCleanupRequired
        case .recoveryBlocked, .monitoringOnly, .wrongLocation, .inactiveSession:
            return state
        }
    }

    /// Asks the daemon to retry verified automatic recovery. This never
    /// unregisters, re-registers, or writes a manual target.
    func retryAutomaticRecovery() -> ApplyResult {
        map(client.retryAutomaticRecovery())
    }

    /// Blocking; see `persistentHelperState`.
    var isPersistentHelperInstalled: Bool {
        persistentHelperState == .ready
    }

    func installPersistentHelper() -> ApplyResult {
        map(client.registerOrUpdateService())
    }

    func unregisterPersistentHelper() -> ApplyResult {
        map(client.unregisterService())
    }

    var hasLegacyPrivilegedHelper: Bool {
        Self.legacyHelperPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Arms the daemon's crash watchdog for `fan` before a manual write. The
    /// target is validated first so a rejected target never leaves a lease or
    /// heartbeat running.
    ///
    /// - Parameter parentPID: Informational only. The daemon derives the
    ///   protected process identity (PID plus start time) from the
    ///   kernel-owned XPC connection and never trusts a caller-supplied PID.
    ///   Kept for source compatibility with `ThermalStore`.
    func startWatchdog(for fan: FanDevice, parentPID: Int32) throws {
        if hasLegacyPrivilegedHelper {
            throw FanControlError.processFailed(Self.legacyManualControlMessage)
        }
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            throw FanControlError.invalidFanIdentifier(fan.id)
        }
        let mode = Self.xpcMode(fan.mode)
        if let rejection = PrivilegedFanClient.targetRejection(mode: mode, rpm: Self.requestedRPM(fan)) {
            throw FanControlError.processFailed(rejection)
        }
        try client.armWatchdog(fanIndex: fanIndex)
    }

    func applyWithPersistentHelper(_ fan: FanDevice) -> ApplyResult {
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            return .failed(FanControlError.invalidFanIdentifier(fan.id).localizedDescription)
        }
        let mode = Self.xpcMode(fan.mode)
        // Auto requests stay allowed so a leftover legacy helper can never
        // prevent a return to firmware control.
        if mode != .automatic, hasLegacyPrivilegedHelper {
            return .failed(Self.legacyManualControlMessage)
        }
        return map(client.apply(fanIndex: fanIndex, mode: mode, rpm: Self.requestedRPM(fan)))
    }

    /// Asks the daemon to return every ThermoFan-owned fan to Auto and reports
    /// its verified answer. `timeout` bounds the whole call, including waiting
    /// for an in-flight operation, so it is safe from the main thread at quit
    /// (the daemon's process-exit watch remains the safety net). `nil` keeps
    /// the default per-step waits and must stay off the main actor.
    func returnAllToAutomatic(timeout: TimeInterval? = nil) -> ApplyResult {
        map(client.returnAllToAutomatic(timeout: timeout))
    }

    private func map(_ result: PrivilegedFanClient.Result) -> ApplyResult {
        switch result {
        case .applied(let message): .applied(message)
        case .failed(let message): .failed(message)
        case .recoveryRequired(let message): .recoveryRequired(message)
        }
    }

    private static func xpcMode(_ mode: FanMode) -> ThermoFanXPC.Mode {
        switch mode {
        case .automatic: .automatic
        case .fixed: .fixed
        case .curve: .curve
        }
    }

    private static func requestedRPM(_ fan: FanDevice) -> Int? {
        fan.mode == .automatic ? nil : fan.targetRPM
    }

    private static func fanIndex(from id: String) -> Int? {
        guard id.hasPrefix("fan"), let index = Int(id.dropFirst(3)),
              (0...ThermoFanXPC.maximumFanIndex).contains(index)
        else {
            return nil
        }
        return index
    }
}
