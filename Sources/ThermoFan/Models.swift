import Foundation
import SwiftUI

enum TemperatureUnit: String, CaseIterable, Codable, Identifiable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .celsius: "C"
        case .fahrenheit: "F"
        }
    }

    var degreeLabel: String { "°\(symbol)" }

    func format(_ celsius: Double) -> String {
        "\(Int(toDisplay(celsius).rounded()))°\(symbol)"
    }

    /// Converts a stored Celsius value into the user's chosen display unit.
    func toDisplay(_ celsius: Double) -> Double {
        self == .celsius ? celsius : (celsius * 9 / 5) + 32
    }

    /// Converts a value entered in the display unit back to Celsius for storage.
    func toCelsius(_ value: Double) -> Double {
        self == .celsius ? value : (value - 32) * 5 / 9
    }
}

enum SensorCategory: String, CaseIterable, Codable, Identifiable {
    case cpu
    case gpu
    case index
    case power
    case storage
    case battery
    case ambient
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .index: "Index"
        case .power: "Power"
        case .storage: "Disk"
        case .battery: "Battery"
        case .ambient: "Ambient"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "display"
        case .index: "chart.line.uptrend.xyaxis"
        case .power: "bolt.fill"
        case .storage: "internaldrive"
        case .battery: "battery.100"
        case .ambient: "sensor"
        case .other: "thermometer.medium"
        }
    }

    var tint: Color {
        switch self {
        case .cpu: .green
        case .gpu: .mint
        case .index: .purple
        case .power: .yellow
        case .storage: .blue
        case .battery: .orange
        case .ambient: .cyan
        case .other: .secondary
        }
    }
}

enum ReadingSource: String, Codable {
    case smc
    case system
    case index
    case estimated

    var label: String {
        switch self {
        case .smc: "SMC"
        case .system: "System"
        case .index: "Index"
        case .estimated: "Estimated"
        }
    }
}

struct ThermalSensor: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var category: SensorCategory
    var temperatureC: Double
    var source: ReadingSource
    var isFavorite: Bool
    var isHidden: Bool
    var updatedAt: Date

    var displaySortKey: String {
        "\(category.rawValue)-\(name)"
    }
}

enum FanMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case fixed
    case curve

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .fixed: "Fixed"
        case .curve: "Curve"
        }
    }
}

enum FanControlState: Hashable {
    case idle
    case pending
    case active
    case failed
}

enum HardwareHelperState: Hashable {
    case missing
    case updateRequired
    case ready

    var title: String {
        switch self {
        case .missing: "Not installed"
        case .updateRequired: "Update required"
        case .ready: "Ready"
        }
    }
}

struct FanCurvePoint: Identifiable, Codable, Hashable {
    var id: UUID
    var temperatureC: Double
    var rpm: Int

    init(id: UUID = UUID(), temperatureC: Double, rpm: Int) {
        self.id = id
        self.temperatureC = temperatureC
        self.rpm = rpm
    }
}

struct FanDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var currentRPM: Int
    var minRPM: Int
    var maxRPM: Int
    var targetRPM: Int
    var mode: FanMode
    var linkedSensorID: String?
    var curve: [FanCurvePoint]
    var source: ReadingSource
    var lastCommand: String?
    var hardwareMode: FanMode? = nil
    var hardwareTargetRPM: Int? = nil
    var controlState: FanControlState = .idle

    var targetProgress: Double {
        guard maxRPM > minRPM else { return 0 }
        return Double(targetRPM - minRPM) / Double(maxRPM - minRPM)
    }
}

struct FanPresetSetting: Codable, Hashable {
    var mode: FanMode
    var targetRPM: Int
    var linkedSensorID: String?
    var curve: [FanCurvePoint]
}

struct FanPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var fanSettings: [String: FanPresetSetting]
    var menuSensorIDs: [String]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        fanSettings: [String: FanPresetSetting],
        menuSensorIDs: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.fanSettings = fanSettings
        self.menuSensorIDs = menuSensorIDs
        self.createdAt = createdAt
    }
}

enum ThermalIndexMode: String, CaseIterable, Codable, Identifiable {
    case hottest
    case average

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hottest: "Hottest"
        case .average: "Average"
        }
    }
}

struct ThermalIndex: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var mode: ThermalIndexMode
    var sensorIDs: [String]

    init(id: UUID = UUID(), name: String, mode: ThermalIndexMode, sensorIDs: [String]) {
        self.id = id
        self.name = name
        self.mode = mode
        self.sensorIDs = sensorIDs
    }
}

struct AppPreferences: Codable, Hashable {
    var temperatureUnit: TemperatureUnit
    var refreshInterval: Double
    var showDockIcon: Bool
    var launchAtLogin: Bool
    var menuSensorIDs: [String]
    var showEstimatedReadings: Bool

    init(
        temperatureUnit: TemperatureUnit,
        refreshInterval: Double,
        showDockIcon: Bool,
        launchAtLogin: Bool,
        menuSensorIDs: [String],
        showEstimatedReadings: Bool
    ) {
        self.temperatureUnit = temperatureUnit
        self.refreshInterval = refreshInterval
        self.showDockIcon = showDockIcon
        self.launchAtLogin = launchAtLogin
        self.menuSensorIDs = menuSensorIDs
        self.showEstimatedReadings = showEstimatedReadings
    }

    private enum CodingKeys: String, CodingKey {
        case temperatureUnit
        case refreshInterval
        case showDockIcon
        case launchAtLogin
        case menuSensorIDs
        case showEstimatedReadings
    }

    init(from decoder: Decoder) throws {
        let defaults = Self.defaults
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperatureUnit = try container.decodeIfPresent(TemperatureUnit.self, forKey: .temperatureUnit) ?? defaults.temperatureUnit
        refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? defaults.refreshInterval
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? defaults.showDockIcon
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        menuSensorIDs = try container.decodeIfPresent([String].self, forKey: .menuSensorIDs) ?? defaults.menuSensorIDs
        showEstimatedReadings = try container.decodeIfPresent(Bool.self, forKey: .showEstimatedReadings) ?? defaults.showEstimatedReadings
    }

    static let defaults = AppPreferences(
        temperatureUnit: .celsius,
        refreshInterval: 2,
        showDockIcon: false,
        launchAtLogin: false,
        menuSensorIDs: [],
        showEstimatedReadings: false
    )
}

struct MachineSnapshot: Codable, Hashable {
    var modelIdentifier: String
    var chipName: String
    var osVersion: String
    var uptime: TimeInterval
    var cpuLoad: Double
    var memoryPressure: Double

    static let empty = MachineSnapshot(
        modelIdentifier: "Unknown Mac",
        chipName: "Unknown chip",
        osVersion: "macOS",
        uptime: 0,
        cpuLoad: 0,
        memoryPressure: 0
    )
}

struct HardwareSnapshot {
    var sensors: [ThermalSensor]
    var fans: [FanDevice]
    var machine: MachineSnapshot
    var warnings: [String]
}
