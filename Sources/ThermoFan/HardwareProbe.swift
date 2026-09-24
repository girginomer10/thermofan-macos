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
    private var smc: (any SMCReadingProviding)?
    private let hidReader: any HIDTemperatureReadingProviding

    // Model identifier, chip name, and OS version never change while the app
    // runs, so resolve them once instead of spawning sw_vers on every sample.
    private let modelIdentifier: String
    private let chipName: String
    private let osVersion: String

    /// Reopens AppleSMC after a failed open. `nil` for injected fixtures.
    private let smcFactory: (() throws -> any SMCReadingProviding)?
    private var smcOpenError: (any Error)?
    private var lastSMCOpenAttempt: TimeInterval?

    // Session state. Every entry point takes `stateLock`, so sampling stays
    // serialized even if a caller forgets to use one queue. The sensor
    // topology below is kept for the whole app session, including across
    // sleep/wake; only the verified fan state is discarded on wake.
    private let stateLock = NSLock()
    private var knownSMCSensorIDs = Set<String>()
    private var knownSystemSensorIDs = Set<String>()
    private var isSupplementingWithSystemSensors = false
    private var coreFamily: SMCCoreFamily?
    /// Session meaning of `SMCSensorCatalog.dualMeaningKey` (`Tp0P`):
    /// `true` = CPU performance core, `false` = power manager die, `nil` =
    /// not published yet.
    private var dualMeaningKeyIsCore: Bool?
    private var gpuCoreNumbers: [String: Int] = [:]
    private var verifiedFans: [Int: VerifiedFanState] = [:]

    private static let smcOpenRetryInterval: TimeInterval = 5
    /// Consecutive failed samples after which a previously verified fan is
    /// exposed as monitoring-only (or dropped when its range is unreadable).
    private static let fanReadMissLimit = 3

    init() {
        let factory: () throws -> any SMCReadingProviding = { try SMCClient() }
        smcFactory = factory
        hidReader = HIDTemperatureReader()
        modelIdentifier = Self.sysctlString("hw.model") ?? "Unknown Mac"
        chipName = Self.sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        osVersion = "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
        do {
            smc = try factory()
        } catch {
            smcOpenError = error
        }
        lastSMCOpenAttempt = ProcessInfo.processInfo.systemUptime
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
        smcFactory = nil
    }

    var isSMCAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return smc != nil
    }

    func prepareAfterWake() {
        stateLock.lock()
        defer { stateLock.unlock() }
        smc?.resetCacheAfterWake()
        // Control topology must be re-verified from fresh reads after wake;
        // a pre-sleep interface is never carried into a post-wake decision.
        verifiedFans.removeAll()
        // Let a failed SMC open retry immediately on the post-wake sample.
        lastSMCOpenAttempt = nil
    }

    func sample(preferences: AppPreferences) -> HardwareSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }

        let machine = machineSnapshot()
        var warnings: [String] = []
        let smc = connectedSMC()
        if smc == nil {
            warnings.append(smcUnavailableWarning())
        }

        let smcSensors = smc.map { readSMCSensors(using: $0) } ?? []
        let systemSensors = hidReader.readSensors()
        var fans: [FanDevice] = []
        if let smc {
            let fanDiscovery = readSMCFans(using: smc)
            fans = fanDiscovery.fans
            warnings += fanDiscovery.warnings
        }

        let monitoringOnlyCount = fans.filter { !$0.controlInterface.isAvailable }.count
        if monitoringOnlyCount > 0 {
            warnings.append(
                "\(monitoringOnlyCount) fan\(monitoringOnlyCount == 1 ? "" : "s") detected, but this firmware exposes no verified fan-control interface. ThermoFan will monitor without writing."
            )
        }

        var sensors = combining(smcSensors: smcSensors, systemSensors: systemSensors)

        if sensors.isEmpty {
            if smc != nil {
                warnings.append("Apple SMC is open, but none of its temperature keys returned a plausible reading and no system temperature sensors are available.")
            }
            if preferences.showEstimatedReadings {
                sensors = estimatedSensors(load: machine.cpuLoad)
                warnings.append("SMC temperature readings are unavailable on this Mac/session, showing estimated readings.")
            }
        }

        return HardwareSnapshot(
            sensors: sensors.sorted { $0.displaySortKey < $1.displaySortKey },
            fans: fans,
            machine: machine,
            warnings: warnings
        )
    }

    /// Returns the open SMC connection, retrying a failed open at most once
    /// per `smcOpenRetryInterval` (and immediately after wake).
    private func connectedSMC() -> (any SMCReadingProviding)? {
        if let smc {
            return smc
        }
        guard let smcFactory else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastSMCOpenAttempt, now - lastSMCOpenAttempt < Self.smcOpenRetryInterval {
            return nil
        }
        lastSMCOpenAttempt = now
        do {
            let opened = try smcFactory()
            smc = opened
            smcOpenError = nil
            return opened
        } catch {
            smcOpenError = error
            return nil
        }
    }

    private func smcUnavailableWarning() -> String {
        // SMCError descriptions carry the kern_return_t message and code.
        let reason = smcOpenError.map(Self.describe) ?? SMCError.serviceUnavailable.description
        let retry = smcFactory == nil
            ? ""
            : "; ThermoFan retries the connection every \(Int(Self.smcOpenRetryInterval)) s"
        return "\(reason) SMC temperatures and fan topology cannot be verified\(retry)."
    }

    /// Decides whether HID (Apple PMU/system) temperatures join the SMC set.
    ///
    /// The rule is evaluated against the session's stable topology (every SMC
    /// and HID sensor ID published so far), never per-sample counts, and it
    /// latches: once supplementing starts it continues for the rest of the
    /// session. A flat 40 C group being filtered out or SMC keys sleeping for
    /// a sample therefore cannot make HID sensors appear and disappear.
    ///
    /// Supplementing starts once HID readings exist and any of these holds:
    /// - the sample produced HID readings but no SMC readings at all;
    /// - fewer than three SMC sensors have been published this session;
    /// - more than twice as many HID sensors as SMC sensors have been seen.
    ///
    /// Until then only HID storage sensors (NAND/SSD), which the SMC catalog
    /// does not cover, are included.
    private func combining(smcSensors: [ThermalSensor], systemSensors: [ThermalSensor]) -> [ThermalSensor] {
        knownSMCSensorIDs.formUnion(smcSensors.map(\.id))
        knownSystemSensorIDs.formUnion(systemSensors.map(\.id))
        let topologyNeedsSupplement = smcSensors.isEmpty
            || knownSMCSensorIDs.count < 3
            || knownSystemSensorIDs.count > knownSMCSensorIDs.count * 2
        if !isSupplementingWithSystemSensors, !systemSensors.isEmpty, topologyNeedsSupplement {
            isSupplementingWithSystemSensors = true
        }
        if isSupplementingWithSystemSensors {
            return smcSensors + systemSensors
        }
        return smcSensors + systemSensors.filter { $0.category == .storage }
    }

    private func readSMCSensors(using smc: any SMCReadingProviding) -> [ThermalSensor] {
        let dualKey = SMCSensorCatalog.dualMeaningKey
        let commonDefinitions = dualMeaningKeyIsCore == true
            ? SMCSensorCatalog.common.filter { $0.key != dualKey }
            : SMCSensorCatalog.common
        var common = readSensors(commonDefinitions, using: smc)
        let gpu = SMCSensorCatalog.numberingGPUCores(
            SMCSensorCatalog.removingFlatSentinelGroups(
                from: readSensors(SMCSensorCatalog.gpuCoreCandidates, using: smc)
            ),
            assigned: &gpuCoreNumbers
        )

        // The core family is chosen once per session. After that only the
        // chosen family is read, so its keys keep one name and category.
        let modern = coreFamily == .legacy
            ? []
            : readSensors(SMCSensorCatalog.modernPerformanceCandidates, using: smc)
        let legacy = coreFamily == .modern
            ? []
            : readSensors(SMCSensorCatalog.legacyCoreCandidates, using: smc)
        if coreFamily == nil {
            coreFamily = SMCSensorCatalog.coreFamily(modern: modern, legacy: legacy)
        }
        var cores: [ThermalSensor]
        switch coreFamily {
        case .modern?:
            cores = SMCSensorCatalog.validCores(modern)
        case .legacy?:
            cores = SMCSensorCatalog.validCores(legacy)
        case nil:
            cores = []
        }

        // Tp0P is a performance core in the modern family and the power
        // manager die otherwise. Its meaning is fixed the first time it can be
        // published: by the chosen family, or, while no family is chosen, as
        // the power manager die once it reads outside a flat sentinel sample.
        // A later family choice never renames it.
        let modernIsSentinel = SMCSensorCatalog.isUniformFortyCoreFamily(modern)
        if dualMeaningKeyIsCore == nil {
            switch coreFamily {
            case .modern?:
                dualMeaningKeyIsCore = true
            case .legacy?:
                dualMeaningKeyIsCore = false
            case nil:
                if !modernIsSentinel, common.contains(where: { $0.id == dualKey }) {
                    dualMeaningKeyIsCore = false
                }
            }
        }
        if dualMeaningKeyIsCore != false || modernIsSentinel {
            common.removeAll { $0.id == dualKey }
        }
        if dualMeaningKeyIsCore != true {
            cores.removeAll { $0.id == dualKey }
        }

        var readings: [ThermalSensor] = []
        var seenKeys = Set<String>()
        for sensor in common + gpu + cores where seenKeys.insert(sensor.id).inserted {
            readings.append(sensor)
        }
        return SMCSensorCatalog.removingFlatSentinelGroups(from: readings)
    }

    private func readSensors(
        _ definitions: [SMCSensorDefinition],
        using smc: any SMCReadingProviding
    ) -> [ThermalSensor] {
        let updatedAt = Date()
        return definitions.compactMap { definition in
            guard
                let reading = try? smc.readNumber(key: definition.key),
                TemperaturePlausibility.isPlausible(reading.value)
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

    /// One fan's registers from a single sample. `readFan` returns nil instead
    /// when the RPM envelope is unreadable or incoherent, in which case the
    /// sample cannot expose the fan at all.
    private struct FanReading {
        var minRPM: Int
        var maxRPM: Int
        var currentRPM: Int?
        /// Raw, unclamped `F{i}Tg`.
        var targetRPM: Int?
        var interface: FanControlInterface
        /// nil = unknown: no verified mode key, or its value did not decode.
        var mode: FanMode?

        /// Every register a control decision depends on was read and decoded.
        var isVerified: Bool {
            currentRPM != nil && targetRPM != nil && interface.isAvailable && mode != nil
        }
    }

    private struct VerifiedFanState {
        var fan: FanDevice
        var consecutiveMisses: Int
    }

    /// Discovers fans. A fan whose control registers were verified keeps its
    /// last verified interface and mode through up to two consecutive failed
    /// samples, reported as a stale-telemetry warning, so a single transient
    /// SMC miss cannot cancel manual control. The third consecutive failure
    /// exposes it as monitoring-only, or drops it when even its RPM range is
    /// unreadable. Wake discards this state (`prepareAfterWake`).
    private func readSMCFans(using smc: any SMCReadingProviding) -> (fans: [FanDevice], warnings: [String]) {
        let reportedCount = SMCNumericPolicy.fanCount(try? smc.readNumber(key: "FNum").value)
        let count = reportedCount ?? 0
        let indexes = Set(0..<count).union(verifiedFans.keys).sorted()

        var fans: [FanDevice] = []
        var warnings: [String] = []
        var exposedReportedFans = 0

        for index in indexes {
            let isReported = index < count
            let reading = isReported ? readFan(index: index, using: smc) : nil
            let name = count == 1 ? "Main Fan" : "Fan \(index + 1)"

            if let reading, reading.isVerified {
                let fan = makeFan(index: index, name: name, reading: reading, interface: reading.interface)
                verifiedFans[index] = VerifiedFanState(fan: fan, consecutiveMisses: 0)
                fans.append(fan)
                exposedReportedFans += 1
                continue
            }

            if var state = verifiedFans[index] {
                state.consecutiveMisses += 1
                if state.consecutiveMisses < Self.fanReadMissLimit {
                    verifiedFans[index] = state
                    fans.append(carryingForward(state.fan, with: reading))
                    if isReported {
                        exposedReportedFans += 1
                    }
                    warnings.append(
                        "\(state.fan.name) telemetry could not be verified (miss \(state.consecutiveMisses) of \(Self.fanReadMissLimit)); showing its last verified state."
                    )
                    continue
                }
                verifiedFans[index] = nil
            }

            if let reading {
                fans.append(makeFan(index: index, name: name, reading: reading, interface: .unavailable))
                exposedReportedFans += 1
            }
        }

        if reportedCount == nil {
            warnings.insert(
                fans.isEmpty
                    ? "The SMC fan count is missing or invalid; this session is monitoring-only."
                    : "The SMC fan count could not be read; showing the last verified fan state.",
                at: 0
            )
        } else if exposedReportedFans < count {
            warnings.append(
                "The SMC reports \(count) fan\(count == 1 ? "" : "s"), but only \(exposedReportedFans) had a safe readable RPM range. Unreadable fans were not exposed for control."
            )
        }
        return (fans, warnings)
    }

    private func readFan(index: Int, using smc: any SMCReadingProviding) -> FanReading? {
        let prefix = "F\(index)"
        let read: (String) -> Double? = { key in
            try? smc.readNumber(key: key).value
        }
        guard
            let minRPM = SMCNumericPolicy.rpm(read("\(prefix)Mn")),
            let maxRPM = SMCNumericPolicy.rpm(read("\(prefix)Mx")),
            maxRPM > minRPM,
            maxRPM >= 1000
        else {
            return nil
        }

        let currentRPM = SMCNumericPolicy.rpm(read("\(prefix)Ac"))
        let targetRPM = SMCNumericPolicy.rpm(read("\(prefix)Tg"))
        let ceiling = maxRPM + SMCNumericPolicy.rpmRangeTolerance
        guard (currentRPM ?? 0) <= ceiling, (targetRPM ?? 0) <= ceiling else {
            return nil
        }

        let interface = FanControlInterfacePolicy.detect(fanIndex: index, read: read)
        return FanReading(
            minRPM: minRPM,
            maxRPM: maxRPM,
            currentRPM: currentRPM,
            targetRPM: targetRPM,
            interface: interface,
            mode: FanControlInterfacePolicy.hardwareMode(fanIndex: index, interface: interface, read: read)
        )
    }

    private func makeFan(
        index: Int,
        name: String,
        reading: FanReading,
        interface: FanControlInterface
    ) -> FanDevice {
        // `FanDevice.currentRPM` is not optional, so an unreadable RPM on a
        // monitoring-only fan is reported as 0. A verified fan always has a
        // real reading.
        let currentRPM = reading.currentRPM ?? 0
        let stagedTarget = reading.targetRPM ?? max(currentRPM, reading.minRPM)
        return FanDevice(
            id: "fan\(index)",
            name: name,
            currentRPM: currentRPM,
            minRPM: reading.minRPM,
            maxRPM: reading.maxRPM,
            targetRPM: Self.clamp(stagedTarget, min: reading.minRPM, max: reading.maxRPM),
            mode: reading.mode ?? .automatic,
            linkedSensorID: nil,
            curve: Self.defaultCurve(minRPM: reading.minRPM, maxRPM: reading.maxRPM),
            source: .smc,
            controlInterface: interface,
            lastCommand: nil,
            // The true mode whenever it can be read, even for a fan that is
            // monitoring-only for another reason; nil means unknown.
            hardwareMode: reading.mode,
            // Raw register value. `targetRPM` above is the clamped staging value.
            hardwareTargetRPM: reading.targetRPM
        )
    }

    /// The last verified fan with whatever this sample could still read. The
    /// verified control interface is kept; the mode is refreshed only when it
    /// decoded.
    private func carryingForward(_ verified: FanDevice, with reading: FanReading?) -> FanDevice {
        var fan = verified
        guard let reading else { return fan }
        fan.minRPM = reading.minRPM
        fan.maxRPM = reading.maxRPM
        if let currentRPM = reading.currentRPM {
            fan.currentRPM = currentRPM
        }
        if let targetRPM = reading.targetRPM {
            fan.hardwareTargetRPM = targetRPM
        }
        fan.targetRPM = Self.clamp(
            fan.hardwareTargetRPM ?? fan.targetRPM,
            min: reading.minRPM,
            max: reading.maxRPM
        )
        if let mode = reading.mode {
            fan.hardwareMode = mode
            fan.mode = mode
        }
        return fan
    }

    private static func clamp(_ value: Int, min lower: Int, max upper: Int) -> Int {
        Swift.max(lower, Swift.min(value, upper))
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
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

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
