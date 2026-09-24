import Foundation

/// The SMC fan-control surface is firmware-defined and differs between Mac
/// generations. Detect the interface from readable keys instead of assuming a
/// model identifier implies a particular write path.
enum FanControlInterface: Hashable {
    case perFanMode(key: String)
    /// Legacy Intel/T2 `FS!` bitmask. Test-only: production code never passes
    /// `allowForceMask: true`, so the app never selects this interface on
    /// Apple Silicon (and the app process never writes to the SMC at all).
    /// The case stays so fixtures keep the mask decoding covered.
    case forceMask(key: String)
    case unavailable

    var isAvailable: Bool {
        self != .unavailable
    }

    var diagnosticLabel: String {
        switch self {
        case .perFanMode(let key):
            "per-fan mode key \(key)"
        case .forceMask(let key):
            "global force mask \(key.trimmingCharacters(in: .whitespaces))"
        case .unavailable:
            "monitoring only"
        }
    }
}

enum FanControlInterfacePolicy {
    static let forceMaskKey = "FS! "

    /// - Parameter allowForceMask: Test-only. Production callers must leave it
    ///   `false`; `FS!` is never a fallback on Apple Silicon.
    static func detect(
        fanIndex: Int,
        allowForceMask: Bool = false,
        read: (String) -> Double?
    ) -> FanControlInterface {
        for suffix in ["Md", "md"] {
            let key = "F\(fanIndex)\(suffix)"
            if let value = read(key), decodedPerFanMode(value) != nil {
                return .perFanMode(key: key)
            }
        }

        // FS! is a legacy Intel/T2 bitmask. It is not a safe generic fallback
        // on Apple Silicon merely because both per-fan keys are absent.
        if allowForceMask, let value = read(forceMaskKey), value.isFinite {
            return .forceMask(key: forceMaskKey)
        }
        return .unavailable
    }

    static func hardwareMode(
        fanIndex: Int,
        interface: FanControlInterface,
        read: (String) -> Double?
    ) -> FanMode? {
        switch interface {
        case .perFanMode(let key):
            guard let value = read(key) else { return nil }
            return decodedPerFanMode(value)
        case .forceMask(let key):
            guard
                let value = read(key),
                value.isFinite,
                value >= 0,
                value <= Double(Int.max)
            else {
                return nil
            }
            let mask = Int(value.rounded(.towardZero))
            return (mask & (1 << fanIndex)) == 0 ? .automatic : .fixed
        case .unavailable:
            return nil
        }
    }

    private static func decodedPerFanMode(_ value: Double) -> FanMode? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded()
        guard value == rounded else { return nil }
        switch Int(rounded) {
        case 0, 3:
            return .automatic
        case 1:
            return .fixed
        default:
            return nil
        }
    }
}

enum SMCNumericPolicy {
    static let maximumFanCount = 8
    static let maximumRPM = 20_000
    static let rpmRangeTolerance = 500

    static func fanCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0, value <= Double(maximumFanCount) else { return nil }
        let rounded = value.rounded()
        guard value == rounded else { return nil }
        return Int(rounded)
    }

    static func rpm(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value >= 0, value <= Double(maximumRPM) else { return nil }
        return Int(value.rounded(.towardZero))
    }
}

/// Plausibility window shared by the SMC and HID temperature paths. Values
/// outside it are firmware sentinels (for example -1/-2 C PMU channels or
/// unused channels reading near 0 C) or decoding errors, not measurements.
enum TemperaturePlausibility {
    static let celsiusRange: Range<Double> = 10..<130

    static func isPlausible(_ celsius: Double) -> Bool {
        celsius.isFinite && celsiusRange.contains(celsius)
    }
}

struct SMCSensorDefinition: Hashable {
    var key: String
    var name: String
    var category: SensorCategory
}

/// The two mutually exclusive CPU-core key families. `HardwareProbe` picks
/// one per app session and never switches, so a key cannot change meaning
/// (name or category) between samples.
enum SMCCoreFamily: Hashable {
    case modern
    case legacy
}

enum SMCSensorCatalog {
    /// `Tp0P` is a CPU performance core in the modern family but the power
    /// manager die on firmware that uses the legacy family. `HardwareProbe`
    /// fixes its meaning once per session.
    static let dualMeaningKey = "Tp0P"

    static let common: [SMCSensorDefinition] = [
        SMCSensorDefinition(key: "TA0P", name: "Airport Proximity", category: .ambient),
        SMCSensorDefinition(key: "TA0p", name: "Ambient Proximity", category: .ambient),
        SMCSensorDefinition(key: "Ta0p", name: "Ambient Proximity", category: .ambient),
        SMCSensorDefinition(key: "TCMz", name: "CPU Die Hotspot", category: .cpu),
        SMCSensorDefinition(key: "TCMb", name: "CPU Core Max", category: .cpu),
        SMCSensorDefinition(key: "TC0P", name: "CPU Proximity", category: .cpu),
        SMCSensorDefinition(key: "TC0E", name: "CPU PECI", category: .cpu),
        SMCSensorDefinition(key: "TC0F", name: "CPU Controller", category: .cpu),
        SMCSensorDefinition(key: "TC0H", name: "CPU Heatsink", category: .cpu),
        SMCSensorDefinition(key: "TC0D", name: "CPU Diode", category: .cpu),
        SMCSensorDefinition(key: "TC1C", name: "CPU Core 1", category: .cpu),
        SMCSensorDefinition(key: "TC2C", name: "CPU Core 2", category: .cpu),
        SMCSensorDefinition(key: "TC3C", name: "CPU Core 3", category: .cpu),
        SMCSensorDefinition(key: "TC4C", name: "CPU Core 4", category: .cpu),
        SMCSensorDefinition(key: "Te04", name: "CPU Efficiency Sensor 1", category: .cpu),
        SMCSensorDefinition(key: "Te05", name: "CPU Efficiency Sensor 2", category: .cpu),
        SMCSensorDefinition(key: "Te06", name: "CPU Efficiency Sensor 3", category: .cpu),
        SMCSensorDefinition(key: "TG0P", name: "GPU Proximity", category: .gpu),
        SMCSensorDefinition(key: "TG0D", name: "GPU Diode", category: .gpu),
        SMCSensorDefinition(key: "TG0H", name: "GPU Heatsink", category: .gpu),
        SMCSensorDefinition(key: "Tg05", name: "GPU Cluster 1", category: .gpu),
        SMCSensorDefinition(key: "Tg0S", name: "GPU Cluster 2", category: .gpu),
        SMCSensorDefinition(key: "Tg0Y", name: "GPU Cluster 3", category: .gpu),
        SMCSensorDefinition(key: "Tg0k", name: "GPU Cluster 4", category: .gpu),
        SMCSensorDefinition(key: "Tg0z", name: "GPU Cluster 5", category: .gpu),
        SMCSensorDefinition(key: "TRDX", name: "GPU Die Hotspot", category: .gpu),
        SMCSensorDefinition(key: "TPMP", name: "SoC Package", category: .power),
        SMCSensorDefinition(key: "TPDX", name: "SoC Package Hotspot", category: .power),
        SMCSensorDefinition(key: "Tp0P", name: "Power Manager Die", category: .power),
        SMCSensorDefinition(key: "TW0P", name: "Wi-Fi Proximity", category: .other),
        SMCSensorDefinition(key: "TVD0", name: "Voltage Regulator", category: .power),
        SMCSensorDefinition(key: "Tm0P", name: "Memory Proximity", category: .power),
        SMCSensorDefinition(key: "Tm0p", name: "Memory Proximity", category: .power),
        SMCSensorDefinition(key: "TB0T", name: "Battery", category: .battery),
        SMCSensorDefinition(key: "TH0P", name: "Heat Pipe", category: .other),
        SMCSensorDefinition(key: "Ts0P", name: "Palm Rest", category: .other),
        SMCSensorDefinition(key: "TN0D", name: "Platform Controller", category: .other),
        SMCSensorDefinition(key: "TS0P", name: "SSD Proximity", category: .storage)
    ]

    static let gpuCoreNamePrefix = "GPU Core"

    /// Per-core GPU candidates `Tg{bank}{a...h}`. Firmware exposes a sparse,
    /// model-dependent subset (for example `Tg0d`, `Tg0e`, `Tg1c`, `Tg1d` on
    /// an M4 Pro), so candidates carry no slot number; the probe names the
    /// discovered keys densely with `numberingGPUCores(_:assigned:)`.
    static let gpuCoreCandidates: [SMCSensorDefinition] = (0...2).flatMap { bank in
        Array("abcdefgh").map { suffix in
            SMCSensorDefinition(key: "Tg\(bank)\(suffix)", name: gpuCoreNamePrefix, category: .gpu)
        }
    }

    /// Names GPU-core readings "GPU Core N" (category `.gpu`). Numbers are
    /// dense and assigned, in the given (catalog) order, the first time each
    /// key is published; `assigned` is the session's key-to-number table, so
    /// a key keeps its name for the whole session even when another key
    /// sleeps or first appears later. Pass readings that already went through
    /// `removingFlatSentinelGroups(from:)` so sentinel keys consume no number.
    static func numberingGPUCores(
        _ sensors: [ThermalSensor],
        assigned: inout [String: Int]
    ) -> [ThermalSensor] {
        sensors.map { sensor in
            let number: Int
            if let existing = assigned[sensor.id] {
                number = existing
            } else {
                number = assigned.count + 1
                assigned[sensor.id] = number
            }
            var named = sensor
            named.name = "\(gpuCoreNamePrefix) \(number)"
            named.category = .gpu
            return named
        }
    }

    static let modernPerformanceCandidates: [SMCSensorDefinition] = {
        let keys = ["Tp0G", "Tp0H", "Tp0I", "Tp0K", "Tp0L", "Tp0M", "Tp0O", "Tp0P", "Tp0Q", "Tp0S"]
        return keys.enumerated().map { offset, key in
            SMCSensorDefinition(key: key, name: "CPU Performance Core \(offset + 1)", category: .cpu)
        }
    }()

    /// Older Apple Silicon generations expose a different family of core keys.
    /// Probe it independently and select it only when it yields the stronger
    /// coherent group, avoiding chip-name assumptions.
    static let legacyCoreCandidates: [SMCSensorDefinition] = [
        SMCSensorDefinition(key: "Tp09", name: "CPU Efficiency Core 1", category: .cpu),
        SMCSensorDefinition(key: "Tp0T", name: "CPU Efficiency Core 2", category: .cpu),
        SMCSensorDefinition(key: "Tp01", name: "CPU Performance Core 1", category: .cpu),
        SMCSensorDefinition(key: "Tp05", name: "CPU Performance Core 2", category: .cpu),
        SMCSensorDefinition(key: "Tp0D", name: "CPU Performance Core 3", category: .cpu)
    ]

    /// Picks the family with the stronger coherent group of real core
    /// readings, or nil while neither yields at least two. The probe asks only
    /// until this returns a family and then keeps that answer for the session.
    static func coreFamily(modern: [ThermalSensor], legacy: [ThermalSensor]) -> SMCCoreFamily? {
        let modernCoreCount = validCores(modern).filter { $0.category == .cpu }.count
        let legacyCoreCount = validCores(legacy).filter { $0.category == .cpu }.count
        guard max(modernCoreCount, legacyCoreCount) >= 2 else { return nil }
        return modernCoreCount >= legacyCoreCount ? .modern : .legacy
    }

    /// Real readings of one core family: a family that reads a uniform 40 C
    /// is a firmware sentinel and is dropped whole, as are flat sub-groups.
    static func validCores(_ family: [ThermalSensor]) -> [ThermalSensor] {
        isUniformFortyCoreFamily(family) ? [] : removingFlatSentinelGroups(from: family)
    }

    static func isUniformFortyCoreFamily(_ sensors: [ThermalSensor]) -> Bool {
        sensors.count >= 2 && sensors.allSatisfy { abs($0.temperatureC - 40) < 0.01 }
    }

    /// Name markers of the SMC per-core groups that some firmware report as a
    /// flat 40 C sentinel. `SensorContinuity.removingFlatCoreSentinels` only
    /// knows the performance-core and GPU-core markers, so the probe filters
    /// every catalog group (including efficiency cores and `Te0x` efficiency
    /// sensors) here before publishing.
    static let flatSentinelGroupMarkers = [
        "Performance Core",
        "Efficiency Core",
        "Efficiency Sensor",
        gpuCoreNamePrefix
    ]

    /// Removes each marker group that has at least two members and reads a
    /// uniform 40 C. Groups that vary are kept whole.
    static func removingFlatSentinelGroups(from sensors: [ThermalSensor]) -> [ThermalSensor] {
        var result = sensors
        for marker in flatSentinelGroupMarkers {
            let group = result.filter { $0.name.localizedCaseInsensitiveContains(marker) }
            guard isUniformFortyCoreFamily(group) else { continue }
            let sentinelIDs = Set(group.map(\.id))
            result.removeAll { sentinelIDs.contains($0.id) }
        }
        return result
    }
}

/// Small seams keep firmware-topology decisions testable without opening the
/// real AppleSMC or HID services in the test process.
protocol SMCReadingProviding: AnyObject {
    func readNumber(key: String) throws -> SMCReading
    func resetCacheAfterWake()
}

extension SMCReadingProviding {
    func resetCacheAfterWake() {}
}

extension SMCClient: SMCReadingProviding {}

protocol HIDTemperatureReadingProviding: AnyObject {
    func readSensors() -> [ThermalSensor]
}

extension HIDTemperatureReader: HIDTemperatureReadingProviding {}
