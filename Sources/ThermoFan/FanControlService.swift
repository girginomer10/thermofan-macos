import FanControlXPC
import Foundation

/// Application-facing facade for the authenticated SMAppService LaunchDaemon.
/// The root daemon, not this process, owns all bounds checks, SMC writes,
/// durable ownership, watchdog leases, and rollback verification.
final class FanControlService: @unchecked Sendable {
    static let expectedHelperVersion = "\(ThermoFanXPC.protocolVersion)"
    static let compatibleLegacyHelperVersion: String? = nil
    static let recoveryRequiredExitCode: Int32 = Int32(ThermoFanXPC.recoveryRequiredStatus)

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

    private let cacheLock = NSLock()
    private var cachedState: HardwareHelperState = .missing

    /// Invoked off the main actor whenever the privileged lease for the given
    /// fan IDs (`fan{i}`) ends without the app asking for it: heartbeat
    /// expiry, XPC interruption, daemon restart, console-user change, or a
    /// lease-lost status from the daemon. The store must reconcile its UI.
    var onLeaseLost: (@Sendable ([String], String) -> Void)? {
        didSet {
            guard let handler = onLeaseLost else {
                client.onLeaseLost = nil
                return
            }
            let bridged: @Sendable (Set<Int>, String) -> Void = { indexes, reason in
                let identifiers = indexes.sorted().map { "fan\($0)" }
                handler(identifiers, reason)
            }
            client.onLeaseLost = bridged
        }
    }

    init(client: PrivilegedFanClient = PrivilegedFanClient()) {
        self.client = client
    }

    /// Blocking: performs the code-signature, `SMAppService`, and handshake
    /// checks. Call only from the control queue, never from the main actor.
    var persistentHelperState: HardwareHelperState {
        let state = client.serviceState
        let resolved: HardwareHelperState
        if hasLegacyPrivilegedHelper, state != .recoveryBlocked {
            resolved = .legacyCleanupRequired
        } else {
            resolved = state
        }
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

    /// Asks the daemon to retry verified automatic recovery. This never
    /// unregisters, re-registers, or writes a manual target.
    func retryAutomaticRecovery() -> ApplyResult {
        map(client.retryAutomaticRecovery())
    }

    var isPersistentHelperInstalled: Bool {
        persistentHelperState == .ready
    }

    func installPersistentHelper() -> ApplyResult {
        return map(client.registerOrUpdateService())
    }

    func unregisterPersistentHelper() -> ApplyResult {
        map(client.unregisterService())
    }

    var hasLegacyPrivilegedHelper: Bool {
        Self.legacyHelperPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    func startWatchdog(for fan: FanDevice, parentPID: Int32) throws {
        guard parentPID == ProcessInfo.processInfo.processIdentifier else {
            throw FanControlError.processFailed("The watchdog may only protect the current ThermoFan process.")
        }
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            throw FanControlError.invalidFanIdentifier(fan.id)
        }
        try client.armWatchdog(fanIndex: fanIndex)
    }

    func applyWithPersistentHelper(_ fan: FanDevice) -> ApplyResult {
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            return .failed(FanControlError.invalidFanIdentifier(fan.id).localizedDescription)
        }
        let mode: ThermoFanXPC.Mode
        switch fan.mode {
        case .automatic: mode = .automatic
        case .fixed: mode = .fixed
        case .curve: mode = .curve
        }
        let rpm = fan.mode == .automatic ? nil : fan.targetRPM
        return map(client.apply(fanIndex: fanIndex, mode: mode, rpm: rpm))
    }

    func returnAllToAutomatic() -> ApplyResult {
        map(client.returnAllToAutomatic())
    }

    private func map(_ result: PrivilegedFanClient.Result) -> ApplyResult {
        switch result {
        case .applied(let message): .applied(message)
        case .failed(let message): .failed(message)
        case .recoveryRequired(let message): .recoveryRequired(message)
        }
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
