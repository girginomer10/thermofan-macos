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

    init(client: PrivilegedFanClient = PrivilegedFanClient()) {
        self.client = client
    }

    var persistentHelperState: HardwareHelperState {
        let state = client.serviceState
        if hasLegacyPrivilegedHelper, state != .recoveryBlocked {
            return .legacyCleanupRequired
        }
        return state
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
