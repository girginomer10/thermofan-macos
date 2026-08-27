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
        case helperMissing
        case recoveryRequired(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFanIdentifier(let id): "Invalid fan identifier '\(id)'."
            case .helperMissing: "The authenticated Hardware Helper is not ready."
            case .recoveryRequired(let message): message
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

    func applyCommandWithPersistentHelper(fanIndex: Int, mode: FanMode, rpm: Int?) -> ApplyResult {
        guard mode == .automatic, rpm == nil else {
            return .failed(
                "Fixed and curve one-shot commands are disabled because a command-line process cannot maintain the authenticated watchdog lease. Use the ThermoFan app instead."
            )
        }
        return map(client.apply(fanIndex: fanIndex, mode: .automatic, rpm: nil))
    }

    func returnAllToAutomatic() -> ApplyResult {
        map(client.returnAllToAutomatic())
    }

    static func classifyProcessFailure(
        status: Int32,
        output: String,
        errorOutput: String,
        recoveryExitCode: Int32?
    ) -> FanControlError {
        let message = errorOutput.isEmpty ? output : errorOutput
        if let recoveryExitCode, status == recoveryExitCode {
            return .recoveryRequired(
                message.isEmpty
                    ? "Automatic fan recovery could not be verified."
                    : message
            )
        }
        return .processFailed(message)
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
