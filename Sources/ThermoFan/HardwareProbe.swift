import Foundation
import Security

struct SensorPreference: Codable, Hashable {
    var isFavorite: Bool
    var isHidden: Bool
}

struct PersistedState: Codable {
    var preferences: AppPreferences
    var presets: [FanPreset]
    var sensorPreferences: [String: SensorPreference]
    var fanSettings: [String: FanPresetSetting]
    var customIndexes: [ThermalIndex]

    init(
        preferences: AppPreferences,
        presets: [FanPreset],
        sensorPreferences: [String: SensorPreference],
        fanSettings: [String: FanPresetSetting],
        customIndexes: [ThermalIndex]
    ) {
        self.preferences = preferences
        self.presets = presets
        self.sensorPreferences = sensorPreferences
        self.fanSettings = fanSettings
        self.customIndexes = customIndexes
    }

    private enum CodingKeys: String, CodingKey {
        case preferences
        case presets
        case sensorPreferences
        case fanSettings
        case customIndexes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try container.decode(AppPreferences.self, forKey: .preferences)
        presets = try container.decode([FanPreset].self, forKey: .presets)
        sensorPreferences = try container.decode([String: SensorPreference].self, forKey: .sensorPreferences)
        fanSettings = try container.decode([String: FanPresetSetting].self, forKey: .fanSettings)
        customIndexes = try container.decodeIfPresent([ThermalIndex].self, forKey: .customIndexes) ?? []
    }
}

final class PersistenceController: @unchecked Sendable {
    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = support.appendingPathComponent("ThermoFan", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("state.json")
    }

    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    func save(_ state: PersistedState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

final class FanControlService: @unchecked Sendable {
    private let installedHelperPath = "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper"
    private let installedHelperVersionPath = "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.version"
    private let legacyHelperPath = "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper"
    private let legacyHelperVersionPath = "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version"
    private let legacyHelperPaths = [
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version"
    ]
    private static let expectedHelperVersion = "5"
    private static let compatibleLegacyHelperVersion = "4"

    enum ApplyResult {
        case applied(String)
        case failed(String)
    }

    var persistentHelperState: HardwareHelperState {
        if helperIsValid(
            at: installedHelperPath,
            versionPath: installedHelperVersionPath,
            expectedVersion: Self.expectedHelperVersion
        ) {
            return .ready
        }

        if helperIsValid(
            at: legacyHelperPath,
            versionPath: legacyHelperVersionPath,
            expectedVersion: Self.compatibleLegacyHelperVersion
        ) {
            return .legacyCompatible
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: installedHelperPath)
            || fileManager.fileExists(atPath: legacyHelperPath) {
            return .updateRequired
        }
        return .missing
    }

    var isPersistentHelperInstalled: Bool {
        activeHelperPath != nil
    }

    func installPersistentHelper() -> ApplyResult {
        guard let bundledHelperPath = bundledHelperPath() else {
            return .failed("Bundled hardware helper was not found. Rebuild the app bundle first.")
        }

        if let problem = Self.verifyBundledHelper(at: bundledHelperPath) {
            return .failed(problem)
        }

        do {
            let bundledVersion = try Self.runProcess(executable: bundledHelperPath, arguments: ["--version"])
            guard bundledVersion == Self.expectedHelperVersion else {
                return .failed(
                    "Bundled Hardware Helper version \(bundledVersion) does not match the required version \(Self.expectedHelperVersion)."
                )
            }
            let stagedHelperPath = "\(installedHelperPath).installing"
            let command = [
                "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
                "/bin/rm -f \(Self.shellQuoted(stagedHelperPath))",
                "/usr/bin/install -o root -g wheel -m 4755 \(Self.shellQuoted(bundledHelperPath)) \(Self.shellQuoted(stagedHelperPath))",
                "/usr/bin/codesign --verify --strict \(Self.shellQuoted(stagedHelperPath))",
                "/bin/test \"$(\(Self.shellQuoted(stagedHelperPath)) --version)\" = \(Self.shellQuoted(Self.expectedHelperVersion))",
                "/bin/mv -f \(Self.shellQuoted(stagedHelperPath)) \(Self.shellQuoted(installedHelperPath))",
                "/usr/sbin/chown root:wheel \(Self.shellQuoted(installedHelperPath))",
                "/bin/chmod 4755 \(Self.shellQuoted(installedHelperPath))",
                "/usr/bin/printf '%s\\n' \(Self.shellQuoted(Self.expectedHelperVersion)) > \(Self.shellQuoted(installedHelperVersionPath))",
                "/usr/sbin/chown root:wheel \(Self.shellQuoted(installedHelperVersionPath))",
                "/bin/chmod 644 \(Self.shellQuoted(installedHelperVersionPath))",
                "/bin/rm -f \(legacyHelperPaths.map(Self.shellQuoted).joined(separator: " "))"
            ].joined(separator: " && ")
            let script = "do shell script \(Self.appleScriptLiteral(command)) with administrator privileges"
            _ = try Self.runProcess(executable: "/usr/bin/osascript", arguments: ["-e", script])
            return persistentHelperState == .ready
                ? .applied("Hardware Helper is ready. Fan changes no longer need repeated password prompts.")
                : .failed("Hardware Helper installation finished, but its version or permissions could not be verified.")
        } catch {
            return .failed("Hardware Helper install failed: \(Self.describe(error))")
        }
    }

    func applyWithPersistentHelper(_ fan: FanDevice) -> ApplyResult {
        do {
            guard isPersistentHelperInstalled else {
                throw FanControlError.helperMissing
            }
            return .applied(try runPersistentHelper(for: fan))
        } catch {
            return .failed("Hardware write failed: \(Self.describe(error))")
        }
    }

    func startWatchdog(for fan: FanDevice, parentPID: Int32) throws {
        guard let helperPath = activeHelperPath else {
            throw FanControlError.helperMissing
        }
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            throw FanControlError.invalidFanIdentifier(fan.id)
        }
        try Self.runDetachedProcess(
            executable: helperPath,
            arguments: ["--watch", "\(parentPID)", "\(fanIndex)"]
        )
    }

    func applyDirect(fanIndex: Int, mode: FanMode, rpm: Int?) throws -> String {
        let smc = try SMCClient()
        let fanCount = Int(try smc.readNumber(key: "FNum").value)
        guard fanIndex >= 0, fanIndex < fanCount else {
            throw FanControlError.noSuchFan(fanIndex: fanIndex, count: fanCount)
        }

        let prefix = "F\(fanIndex)"
        let minRPM = Int(try smc.readNumber(key: "\(prefix)Mn").value)
        let maxRPM = Int(try smc.readNumber(key: "\(prefix)Mx").value)
        guard minRPM >= 0, maxRPM > minRPM, maxRPM >= 1000 else {
            throw FanControlError.unreadableFanRange(fanIndex: fanIndex)
        }
        let clampedRPM = max(minRPM, min(rpm ?? minRPM, maxRPM))
        let perFanModeKey = "\(prefix)Md"
        let supportsPerFanMode = (try? smc.readNumber(key: perFanModeKey)) != nil

        switch mode {
        case .automatic:
            if supportsPerFanMode {
                try smc.writeNumber(key: perFanModeKey, value: 0)
                let verifiedMode = try smc.readNumber(key: perFanModeKey).value
                guard verifiedMode < 0.5 else {
                    throw FanControlError.verificationFailed("SMC still reports manual mode for fan \(fanIndex + 1).")
                }
                return "Fan \(fanIndex + 1) returned to automatic hardware control."
            }

            var forceMask = Int(try smc.readNumber(key: "FS! ").value)
            forceMask &= ~(1 << fanIndex)
            try smc.writeNumber(key: "FS! ", value: Double(forceMask))
            let verifiedMask = Int(try smc.readNumber(key: "FS! ").value)
            guard (verifiedMask & (1 << fanIndex)) == 0 else {
                throw FanControlError.verificationFailed("The SMC force mask still includes fan \(fanIndex + 1).")
            }
            return "Fan \(fanIndex + 1) returned to automatic hardware control."
        case .fixed, .curve:
            if supportsPerFanMode {
                try smc.writeNumber(key: perFanModeKey, value: 1)
            } else {
                var forceMask = Int(try smc.readNumber(key: "FS! ").value)
                forceMask |= (1 << fanIndex)
                try smc.writeNumber(key: "FS! ", value: Double(forceMask))
            }

            do {
                try smc.writeNumber(key: "\(prefix)Tg", value: Double(clampedRPM))
                let appliedRPM = try smc.readNumber(key: "\(prefix)Tg").value
                guard abs(appliedRPM - Double(clampedRPM)) <= 25 else {
                    throw FanControlError.verificationFailed(
                        "Requested \(clampedRPM) RPM, but SMC reports \(Int(appliedRPM.rounded())) RPM."
                    )
                }
                if supportsPerFanMode {
                    let verifiedMode = try smc.readNumber(key: perFanModeKey).value
                    guard verifiedMode >= 0.5 else {
                        throw FanControlError.verificationFailed("SMC did not retain manual mode for fan \(fanIndex + 1).")
                    }
                } else {
                    let verifiedMask = Int(try smc.readNumber(key: "FS! ").value)
                    guard (verifiedMask & (1 << fanIndex)) != 0 else {
                        throw FanControlError.verificationFailed("The SMC force mask does not include fan \(fanIndex + 1).")
                    }
                }
                return "Fan \(fanIndex + 1) target verified on hardware: \(Int(appliedRPM.rounded())) RPM."
            } catch {
                if supportsPerFanMode {
                    try? smc.writeNumber(key: perFanModeKey, value: 0)
                } else if var forceMask = try? Int(smc.readNumber(key: "FS! ").value) {
                    forceMask &= ~(1 << fanIndex)
                    try? smc.writeNumber(key: "FS! ", value: Double(forceMask))
                }
                throw error
            }
        }
    }

    private func applyDirect(fan: FanDevice) throws -> String {
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            throw FanControlError.invalidFanIdentifier(fan.id)
        }
        let rpm = fan.mode == .automatic ? nil : fan.targetRPM
        return try applyDirect(fanIndex: fanIndex, mode: fan.mode, rpm: rpm)
    }

    private func runPersistentHelper(for fan: FanDevice) throws -> String {
        guard let helperPath = activeHelperPath else {
            throw FanControlError.helperMissing
        }
        guard let fanIndex = Self.fanIndex(from: fan.id) else {
            throw FanControlError.invalidFanIdentifier(fan.id)
        }
        var arguments = ["--fanctl", "\(fanIndex)", fan.mode.rawValue]
        if fan.mode != .automatic {
            arguments.append("\(fan.targetRPM)")
        }

        let output = try Self.runProcess(executable: helperPath, arguments: arguments)
        return output.isEmpty ? "Hardware command applied." : output
    }

    private var activeHelperPath: String? {
        if helperIsValid(
            at: installedHelperPath,
            versionPath: installedHelperVersionPath,
            expectedVersion: Self.expectedHelperVersion
        ) {
            return installedHelperPath
        }
        if helperIsValid(
            at: legacyHelperPath,
            versionPath: legacyHelperVersionPath,
            expectedVersion: Self.compatibleLegacyHelperVersion
        ) {
            return legacyHelperPath
        }
        return nil
    }

    private func helperIsValid(at path: String, versionPath: String, expectedVersion: String) -> Bool {
        guard
            FileManager.default.isExecutableFile(atPath: path),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let type = attributes[.type] as? FileAttributeType,
            let owner = attributes[.ownerAccountID] as? NSNumber,
            let group = attributes[.groupOwnerAccountID] as? NSNumber,
            let permissions = attributes[.posixPermissions] as? NSNumber,
            type == .typeRegular,
            owner.intValue == 0,
            group.intValue == 0,
            (permissions.intValue & 0o4777) == 0o4755,
            let versionAttributes = try? FileManager.default.attributesOfItem(atPath: versionPath),
            let versionType = versionAttributes[.type] as? FileAttributeType,
            let versionOwner = versionAttributes[.ownerAccountID] as? NSNumber,
            let versionGroup = versionAttributes[.groupOwnerAccountID] as? NSNumber,
            let versionPermissions = versionAttributes[.posixPermissions] as? NSNumber,
            versionType == .typeRegular,
            versionOwner.intValue == 0,
            versionGroup.intValue == 0,
            (versionPermissions.intValue & 0o777) == 0o644,
            let version = try? String(contentsOfFile: versionPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            version == expectedVersion
        else {
            return false
        }
        return true
    }

    /// Vets the helper binary before it is copied and made setuid-root. This is
    /// defense-in-depth against a swapped payload; a notarized SMAppService/XPC
    /// helper is the proper long-term fix. Returns an error message, or nil if OK.
    private static func verifyBundledHelper(at path: String) -> String? {
        let fileManager = FileManager.default
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: path),
            let type = attributes[.type] as? FileAttributeType,
            type == .typeRegular
        else {
            return "Bundled hardware helper is missing or is not a regular file; refusing to install."
        }

        // Reject a group/other-writable binary: another process could swap in a
        // malicious payload before it is blessed as setuid-root.
        if let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue, (permissions & 0o022) != 0 {
            return "Bundled hardware helper is writable by other users; refusing to install."
        }

        // Verify the helper carries an intact code signature (catches a tampered
        // or unsigned replacement binary).
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess, let staticCode else {
            return "Bundled hardware helper could not be read for signature validation; refusing to install."
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else {
            return "Bundled hardware helper failed code-signature validation; refusing to install."
        }

        return nil
    }

    private func bundledHelperPath() -> String? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
            .appendingPathComponent("ThermoFanHelper")
        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL.path
        }

        let developmentURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("ThermoFan.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("PrivilegedHelperTools", isDirectory: true)
            .appendingPathComponent("ThermoFanHelper")
        return FileManager.default.isExecutableFile(atPath: developmentURL.path) ? developmentURL.path : nil
    }

    private static func fanIndex(from id: String) -> Int? {
        guard id.hasPrefix("fan") else { return nil }
        return Int(id.dropFirst(3))
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw FanControlError.processFailed(errorOutput.isEmpty ? output : errorOutput)
        }

        return output
    }

    private static func runDetachedProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let null = FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = null
        process.standardError = null
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    enum FanControlError: Error, LocalizedError {
        case invalidFanIdentifier(String)
        case noSuchFan(fanIndex: Int, count: Int)
        case unreadableFanRange(fanIndex: Int)
        case helperMissing
        case verificationFailed(String)
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidFanIdentifier(let id):
                return "Invalid fan identifier '\(id)'."
            case .noSuchFan(let fanIndex, let count):
                return "Fan \(fanIndex + 1) does not exist; SMC reports \(count) fan(s)."
            case .unreadableFanRange(let fanIndex):
                return "Fan \(fanIndex + 1) RPM range could not be read safely from SMC."
            case .helperMissing:
                return "Hardware Helper is not installed."
            case .verificationFailed(let message):
                return "Hardware verification failed: \(message)"
            case .processFailed(let message):
                return message.isEmpty ? "The privileged command failed." : message
            }
        }
    }
}

final class HardwareProbe: @unchecked Sendable {
    private struct SensorDefinition {
        var key: String
        var name: String
        var category: SensorCategory
    }

    private let smc: SMCClient?
    private let hidReader = HIDTemperatureReader()

    // Model identifier, chip name, and OS version never change while the app
    // runs, so resolve them once instead of spawning sw_vers on every sample.
    private let modelIdentifier: String
    private let chipName: String
    private let osVersion: String

    init() {
        smc = try? SMCClient()
        modelIdentifier = Self.sysctlString("hw.model") ?? "Unknown Mac"
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    var isSMCAvailable: Bool {
        smc != nil
    }

    func sample(preferences: AppPreferences) -> HardwareSnapshot {
        let machine = machineSnapshot()
        var warnings: [String] = []
        let smcSensors = readSMCSensors()
        let systemSensors = hidReader.readSensors()
        var sensors = smcSensors
        let fans = readSMCFans()

        if smcSensors.isEmpty, !systemSensors.isEmpty {
            sensors = systemSensors
        } else if shouldSupplementWithSystemSensors(smcSensors: smcSensors, systemSensors: systemSensors) {
            sensors = smcSensors + systemSensors
        } else {
            sensors += systemSensors.filter { $0.category == .storage }
        }

        if sensors.isEmpty, preferences.showEstimatedReadings {
            sensors = estimatedSensors(load: machine.cpuLoad)
            warnings.append("SMC temperature readings are unavailable on this Mac/session, showing estimated readings.")
        }

        return HardwareSnapshot(
            sensors: sensors.sorted { $0.displaySortKey < $1.displaySortKey },
            fans: fans,
            machine: machine,
            warnings: warnings
        )
    }

    private func readSMCSensors() -> [ThermalSensor] {
        guard let smc else { return [] }
        var definitions: [SensorDefinition] = [
            SensorDefinition(key: "TA0P", name: "Airport Proximity", category: .ambient),
            SensorDefinition(key: "TA0p", name: "Ambient Proximity", category: .ambient),
            SensorDefinition(key: "Ta0p", name: "Ambient Proximity", category: .ambient),
            SensorDefinition(key: "TCMz", name: "CPU Die Hotspot", category: .cpu),
            SensorDefinition(key: "TCMb", name: "CPU Core Max", category: .cpu),
            SensorDefinition(key: "TC0P", name: "CPU Proximity", category: .cpu),
            SensorDefinition(key: "TC0E", name: "CPU PECI", category: .cpu),
            SensorDefinition(key: "TC0F", name: "CPU Controller", category: .cpu),
            SensorDefinition(key: "TC0H", name: "CPU Heatsink", category: .cpu),
            SensorDefinition(key: "TC0D", name: "CPU Diode", category: .cpu),
            SensorDefinition(key: "TC1C", name: "CPU Core 1", category: .cpu),
            SensorDefinition(key: "TC2C", name: "CPU Core 2", category: .cpu),
            SensorDefinition(key: "TC3C", name: "CPU Core 3", category: .cpu),
            SensorDefinition(key: "TC4C", name: "CPU Core 4", category: .cpu),
            SensorDefinition(key: "Te04", name: "CPU Efficiency Sensor 1", category: .cpu),
            SensorDefinition(key: "Te05", name: "CPU Efficiency Sensor 2", category: .cpu),
            SensorDefinition(key: "Te06", name: "CPU Efficiency Sensor 3", category: .cpu),
            SensorDefinition(key: "TG0P", name: "GPU Proximity", category: .gpu),
            SensorDefinition(key: "TG0D", name: "GPU Diode", category: .gpu),
            SensorDefinition(key: "TG0H", name: "GPU Heatsink", category: .gpu),
            SensorDefinition(key: "Tg05", name: "GPU Cluster 1", category: .gpu),
            SensorDefinition(key: "Tg0S", name: "GPU Cluster 2", category: .gpu),
            SensorDefinition(key: "Tg0Y", name: "GPU Cluster 3", category: .gpu),
            SensorDefinition(key: "Tg0k", name: "GPU Cluster 4", category: .gpu),
            SensorDefinition(key: "Tg0z", name: "GPU Cluster 5", category: .gpu),
            SensorDefinition(key: "TRDX", name: "GPU Die Hotspot", category: .gpu),
            SensorDefinition(key: "TPMP", name: "SoC Package", category: .power),
            SensorDefinition(key: "TPDX", name: "SoC Package Hotspot", category: .power),
            SensorDefinition(key: "Tp0P", name: "Power Manager Die", category: .power),
            SensorDefinition(key: "TW0P", name: "Wi-Fi Proximity", category: .other),
            SensorDefinition(key: "TVD0", name: "Voltage Regulator", category: .power),
            SensorDefinition(key: "Tm0P", name: "Memory Proximity", category: .power),
            SensorDefinition(key: "Tm0p", name: "Memory Proximity", category: .power),
            SensorDefinition(key: "TB0T", name: "Battery", category: .battery),
            SensorDefinition(key: "TH0P", name: "Heat Pipe", category: .other),
            SensorDefinition(key: "Ts0P", name: "Palm Rest", category: .other),
            SensorDefinition(key: "TN0D", name: "Platform Controller", category: .other),
            SensorDefinition(key: "TS0P", name: "SSD Proximity", category: .storage)
        ]

        let modernPerformanceKeys = ["Tp0G", "Tp0H", "Tp0I", "Tp0K", "Tp0L", "Tp0M", "Tp0O", "Tp0P", "Tp0Q", "Tp0S"]
        let performanceCoreCount = min(
            modernPerformanceKeys.count,
            max(0, Self.sysctlInt("hw.perflevel0.physicalcpu") ?? 0)
        )
        if chipName.localizedCaseInsensitiveContains("Apple M") && performanceCoreCount > 0 {
            definitions.removeAll { $0.key == "Tp0P" }
            definitions.append(contentsOf: modernPerformanceKeys.prefix(performanceCoreCount).enumerated().map { offset, key in
                SensorDefinition(key: key, name: "CPU Performance Core \(offset + 1)", category: .cpu)
            })
        } else {
            definitions.append(contentsOf: [
                SensorDefinition(key: "Tp09", name: "CPU Efficiency Core 1", category: .cpu),
                SensorDefinition(key: "Tp0T", name: "CPU Efficiency Core 2", category: .cpu),
                SensorDefinition(key: "Tp01", name: "CPU Performance Core 1", category: .cpu),
                SensorDefinition(key: "Tp05", name: "CPU Performance Core 2", category: .cpu),
                SensorDefinition(key: "Tp0D", name: "CPU Performance Core 3", category: .cpu)
            ])
        }

        var readings: [ThermalSensor] = []
        var seenKeys = Set<String>()

        for definition in definitions where !seenKeys.contains(definition.key) {
            seenKeys.insert(definition.key)
            guard
                let reading = try? smc.readNumber(key: definition.key),
                reading.value.isFinite,
                Self.isPlausibleTemperature(reading.value),
                reading.value < 130
            else {
                continue
            }

            readings.append(ThermalSensor(
                id: definition.key,
                name: definition.name,
                category: definition.category,
                temperatureC: reading.value,
                source: .smc,
                isFavorite: false,
                isHidden: false,
                updatedAt: Date()
            ))
        }

        return SensorContinuity.removingFlatPerformanceCoreSentinels(from: readings)
    }

    private func readSMCFans() -> [FanDevice] {
        guard let smc else { return [] }
        let count = Int((try? smc.readNumber(key: "FNum").value) ?? 0)
        guard count > 0, count < 8 else { return [] }

        return (0..<count).compactMap { index in
            let prefix = "F\(index)"
            guard
                let minReading = try? smc.readNumber(key: "\(prefix)Mn"),
                let maxReading = try? smc.readNumber(key: "\(prefix)Mx")
            else {
                return nil
            }

            let current = Int((try? smc.readNumber(key: "\(prefix)Ac").value) ?? 0)
            let minRPM = Int(minReading.value)
            let maxRPM = Int(maxReading.value)
            guard minRPM >= 0, maxRPM > minRPM, maxRPM >= 1000 else {
                return nil
            }

            let target = Int((try? smc.readNumber(key: "\(prefix)Tg").value) ?? Double(max(current, minRPM)))
            let modeValue = Int((try? smc.readNumber(key: "\(prefix)Md").value) ?? 0)

            return FanDevice(
                id: "fan\(index)",
                name: count == 1 ? "Main Fan" : "Fan \(index + 1)",
                currentRPM: max(0, current),
                minRPM: minRPM,
                maxRPM: maxRPM,
                targetRPM: max(minRPM, min(target, maxRPM)),
                mode: modeValue == 0 ? .automatic : .fixed,
                linkedSensorID: nil,
                curve: Self.defaultCurve(minRPM: minRPM, maxRPM: maxRPM),
                source: .smc,
                lastCommand: nil,
                hardwareMode: modeValue == 0 ? .automatic : .fixed,
                hardwareTargetRPM: max(minRPM, min(target, maxRPM))
            )
        }
    }

    private func shouldSupplementWithSystemSensors(smcSensors: [ThermalSensor], systemSensors: [ThermalSensor]) -> Bool {
        guard !systemSensors.isEmpty else { return false }
        guard !smcSensors.isEmpty else { return false }
        let hottestSMC = smcSensors.map(\.temperatureC).max() ?? 0
        return smcSensors.count < 3 || hottestSMC < 10 || systemSensors.count > smcSensors.count * 2
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value.isFinite && value >= 10 && value < 130
    }

    private func estimatedSensors(load: Double) -> [ThermalSensor] {
        let phase = Date().timeIntervalSinceReferenceDate
        let wobble = sin(phase / 6) * 2.5
        let cpuBase = 44 + load * 48 + wobble
        let gpuBase = 39 + load * 36 + cos(phase / 8) * 1.8
        let powerBase = 41 + load * 42 + sin(phase / 9) * 2

        let definitions: [(String, String, SensorCategory, Double)] = [
            ("airport-proximity", "Airport Proximity", .ambient, 36 + wobble),
            ("cpu-efficiency-1", "CPU Efficiency Core 1", .cpu, cpuBase - 4),
            ("cpu-efficiency-2", "CPU Efficiency Core 2", .cpu, cpuBase - 2),
            ("cpu-efficiency-3", "CPU Efficiency Core 3", .cpu, cpuBase - 1),
            ("cpu-efficiency-4", "CPU Efficiency Core 4", .cpu, cpuBase - 3),
            ("cpu-performance-1", "CPU Performance Core 1", .cpu, cpuBase + 3),
            ("cpu-performance-2", "CPU Performance Core 2", .cpu, cpuBase + 5),
            ("cpu-performance-3", "CPU Performance Core 3", .cpu, cpuBase + 2),
            ("cpu-performance-4", "CPU Performance Core 4", .cpu, cpuBase + 4),
            ("gpu-cluster-1", "GPU Cluster 1", .gpu, gpuBase + 1),
            ("gpu-cluster-2", "GPU Cluster 2", .gpu, gpuBase + 2),
            ("gpu-cluster-3", "GPU Cluster 3", .gpu, gpuBase - 1),
            ("gpu-cluster-4", "GPU Cluster 4", .gpu, gpuBase + 3),
            ("power-manager", "Power Manager Die", .power, powerBase + 6),
            ("power-supply", "Power Supply Proximity", .power, powerBase),
            ("ssd", "APPLE SSD", .storage, 42 + load * 18)
        ]

        return definitions.map { id, name, category, temperature in
            ThermalSensor(
                id: id,
                name: name,
                category: category,
                temperatureC: max(25, min(105, temperature)),
                source: .estimated,
                isFavorite: id == "cpu-performance-1" || id == "power-manager",
                isHidden: false,
                updatedAt: Date()
            )
        }
    }

    private func machineSnapshot() -> MachineSnapshot {
        MachineSnapshot(
            modelIdentifier: modelIdentifier,
            chipName: chipName,
            osVersion: osVersion,
            uptime: ProcessInfo.processInfo.systemUptime,
            cpuLoad: Self.normalizedLoad(),
            memoryPressure: 0
        )
    }

    static func defaultCurve(minRPM: Int, maxRPM: Int) -> [FanCurvePoint] {
        [
            FanCurvePoint(temperatureC: 45, rpm: minRPM),
            FanCurvePoint(temperatureC: 65, rpm: minRPM + Int(Double(maxRPM - minRPM) * 0.35)),
            FanCurvePoint(temperatureC: 82, rpm: minRPM + Int(Double(maxRPM - minRPM) * 0.72)),
            FanCurvePoint(temperatureC: 95, rpm: maxRPM)
        ]
    }

    private static func normalizedLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let result = getloadavg(&loads, 3)
        guard result > 0 else { return 0.25 }
        let cores = max(1, ProcessInfo.processInfo.processorCount)
        return max(0, min(1, loads[0] / Double(cores)))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value = Int32(0)
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
