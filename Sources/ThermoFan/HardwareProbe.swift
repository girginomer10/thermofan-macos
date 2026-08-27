import Darwin
import Foundation

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

final class HardwareProbe: @unchecked Sendable {
    private let smc: (any SMCReadingProviding)?
    private let hidReader: any HIDTemperatureReadingProviding

    // Model identifier, chip name, and OS version never change while the app
    // runs, so resolve them once instead of spawning sw_vers on every sample.
    private let modelIdentifier: String
    private let chipName: String
    private let osVersion: String

    init() {
        smc = try? SMCClient()
        hidReader = HIDTemperatureReader()
        modelIdentifier = Self.sysctlString("hw.model") ?? "Unknown Mac"
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    init(
        smc: (any SMCReadingProviding)?,
        hidReader: any HIDTemperatureReadingProviding,
        modelIdentifier: String,
        chipName: String,
        osVersion: String
    ) {
        self.smc = smc
        self.hidReader = hidReader
        self.modelIdentifier = modelIdentifier
        self.chipName = chipName
        self.osVersion = osVersion
    }

    var isSMCAvailable: Bool {
        smc != nil
    }

    func prepareAfterWake() {
        smc?.resetCacheAfterWake()
    }

    func sample(preferences: AppPreferences) -> HardwareSnapshot {
        let machine = machineSnapshot()
        var warnings: [String] = []
        let smcSensors = readSMCSensors()
        let systemSensors = hidReader.readSensors()
        var sensors = smcSensors
        let fanDiscovery = readSMCFans()
        let fans = fanDiscovery.fans
        if let warning = fanDiscovery.warning {
            warnings.append(warning)
        }

        let monitoringOnlyCount = fans.filter { !$0.controlInterface.isAvailable }.count
        if monitoringOnlyCount > 0 {
            warnings.append(
                "\(monitoringOnlyCount) fan\(monitoringOnlyCount == 1 ? "" : "s") detected, but this firmware exposes no verified fan-control interface. ThermoFan will monitor without writing."
            )
        }

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
        var common = readSensors(SMCSensorCatalog.common, using: smc)
        let gpu = readSensors(SMCSensorCatalog.gpuCoreCandidates, using: smc)
        let modern = readSensors(SMCSensorCatalog.modernPerformanceCandidates, using: smc)
        let legacy = readSensors(SMCSensorCatalog.legacyCoreCandidates, using: smc)
        let cores = SMCSensorCatalog.selectingCoreFamily(modern: modern, legacy: legacy)

        // Tp0P changes meaning between firmware generations. If it is part of
        // the coherent modern CPU-core family, do not also label it as power.
        if cores.contains(where: { $0.id == "Tp0P" })
            || SMCSensorCatalog.isUniformFortyCoreFamily(modern) {
            common.removeAll { $0.id == "Tp0P" }
        }

        var readings: [ThermalSensor] = []
        var seenKeys = Set<String>()
        for sensor in common + gpu + cores where seenKeys.insert(sensor.id).inserted {
            readings.append(sensor)
        }
        return SensorContinuity.removingFlatCoreSentinels(from: readings)
    }

    private func readSensors(
        _ definitions: [SMCSensorDefinition],
        using smc: any SMCReadingProviding
    ) -> [ThermalSensor] {
        let updatedAt = Date()
        return definitions.compactMap { definition in
            guard
                let reading = try? smc.readNumber(key: definition.key),
                Self.isPlausibleTemperature(reading.value)
            else {
                return nil
            }
            return ThermalSensor(
                id: definition.key,
                name: definition.name,
                category: definition.category,
                temperatureC: reading.value,
                source: .smc,
                isFavorite: false,
                isHidden: false,
                updatedAt: updatedAt
            )
        }
    }

    private func readSMCFans() -> (fans: [FanDevice], warning: String?) {
        guard let smc else { return ([], "Apple SMC is unavailable; fan topology could not be verified.") }
        guard let count = SMCNumericPolicy.fanCount(try? smc.readNumber(key: "FNum").value) else {
            return ([], "The SMC fan count is missing or invalid; this session is monitoring-only.")
        }
        guard count > 0 else { return ([], nil) }

        let fans: [FanDevice] = (0..<count).compactMap { index in
            let prefix = "F\(index)"
            guard
                let minReading = try? smc.readNumber(key: "\(prefix)Mn"),
                let maxReading = try? smc.readNumber(key: "\(prefix)Mx")
            else {
                return nil
            }

            let currentValue = SMCNumericPolicy.rpm(try? smc.readNumber(key: "\(prefix)Ac").value)
            let current = currentValue ?? 0
            guard
                let minRPM = SMCNumericPolicy.rpm(minReading.value),
                let maxRPM = SMCNumericPolicy.rpm(maxReading.value)
            else {
                return nil
            }
            guard minRPM >= 0, maxRPM > minRPM, maxRPM >= 1000 else {
                return nil
            }

            let read: (String) -> Double? = { key in
                try? smc.readNumber(key: key).value
            }
            let targetValue = SMCNumericPolicy.rpm(read("\(prefix)Tg"))
            let target = targetValue ?? max(current, minRPM)
            guard
                current <= maxRPM + SMCNumericPolicy.rpmRangeTolerance,
                target <= maxRPM + SMCNumericPolicy.rpmRangeTolerance
            else {
                return nil
            }
            var controlInterface = FanControlInterfacePolicy.detect(fanIndex: index, read: read)
            var hardwareMode = FanControlInterfacePolicy.hardwareMode(
                fanIndex: index,
                interface: controlInterface,
                read: read
            )
            if currentValue == nil || targetValue == nil || hardwareMode == nil {
                controlInterface = .unavailable
                hardwareMode = nil
            }

            return FanDevice(
                id: "fan\(index)",
                name: count == 1 ? "Main Fan" : "Fan \(index + 1)",
                currentRPM: max(0, current),
                minRPM: minRPM,
                maxRPM: maxRPM,
                targetRPM: max(minRPM, min(target, maxRPM)),
                mode: hardwareMode ?? .automatic,
                linkedSensorID: nil,
                curve: Self.defaultCurve(minRPM: minRPM, maxRPM: maxRPM),
                source: .smc,
                controlInterface: controlInterface,
                lastCommand: nil,
                hardwareMode: hardwareMode,
                hardwareTargetRPM: max(minRPM, min(target, maxRPM))
            )
        }
        let warning = fans.count == count
            ? nil
            : "The SMC reports \(count) fan\(count == 1 ? "" : "s"), but only \(fans.count) had a safe readable RPM range. Unreadable fans were not exposed for control."
        return (fans, warning)
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
