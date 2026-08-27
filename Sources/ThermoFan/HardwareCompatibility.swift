import Foundation

/// The SMC fan-control surface is firmware-defined and differs between Mac
/// generations. Detect the interface from readable keys instead of assuming a
/// model identifier implies a particular write path.
enum FanControlInterface: Hashable {
    case perFanMode(key: String)
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

struct SMCSensorDefinition: Hashable {
    var key: String
    var name: String
    var category: SensorCategory
}

enum SMCSensorCatalog {
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

    static let gpuCoreCandidates: [SMCSensorDefinition] = {
        let keys = (0...2).flatMap { bank in
            Array("abcdefgh").map { suffix in
                "Tg\(bank)\(suffix)"
            }
        }
        return keys.enumerated().map { offset, key in
            SMCSensorDefinition(key: key, name: "GPU Core \(offset + 1)", category: .gpu)
        }
    }()

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

    static func selectingCoreFamily(
        modern: [ThermalSensor],
        legacy: [ThermalSensor]
    ) -> [ThermalSensor] {
        let validModern = isUniformFortyCoreFamily(modern)
            ? []
            : SensorContinuity.removingFlatCoreSentinels(from: modern)
        let validLegacy = isUniformFortyCoreFamily(legacy)
            ? []
            : SensorContinuity.removingFlatCoreSentinels(from: legacy)

        let modernCoreCount = validModern.filter { $0.category == .cpu }.count
        let legacyCoreCount = validLegacy.filter { $0.category == .cpu }.count
        guard max(modernCoreCount, legacyCoreCount) >= 2 else { return [] }
        return modernCoreCount >= legacyCoreCount ? validModern : validLegacy
    }

    static func isUniformFortyCoreFamily(_ sensors: [ThermalSensor]) -> Bool {
        sensors.count >= 2 && sensors.allSatisfy { abs($0.temperatureC - 40) < 0.01 }
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
