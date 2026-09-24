import Foundation
import IOKit

private typealias IOHIDEventSystemClientRef = CFTypeRef
private typealias IOHIDServiceClientRef = CFTypeRef
private typealias IOHIDEventRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(
    _ service: IOHIDServiceClientRef,
    _ type: Int64,
    _ options: Int32,
    _ timeout: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: Int32) -> Double

final class HIDTemperatureReader: @unchecked Sendable {
    private let eventTypeTemperature: Int64 = 15
    private let eventFieldTemperature: Int32 = 15 << 16
    /// Services can be added or replaced (for example across sleep/wake)
    /// without the cached list ever becoming empty, so it is also refreshed
    /// on this interval.
    private static let serviceRefreshInterval: TimeInterval = 60

    // The event-system client and its matching service list are expensive to
    // build (a Mach connection to hidd plus a full service enumeration), so
    // create them once and reuse. Services are re-enumerated when the cached
    // list is empty, after a sample in which no service yielded a reading
    // (handles invalidated by sleep/wake), and every `serviceRefreshInterval`.
    private var client: IOHIDEventSystemClientRef?
    private var cachedServices: [IOHIDServiceClientRef] = []
    private var lastEnumerationUptime: TimeInterval = 0

    private func services() -> [IOHIDServiceClientRef] {
        if client == nil {
            guard let created = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
                return []
            }
            let matching: [String: Any] = [
                "PrimaryUsagePage": 0xff00,
                "PrimaryUsage": 5
            ]
            IOHIDEventSystemClientSetMatching(created, matching as CFDictionary)
            client = created
        }
        let now = ProcessInfo.processInfo.systemUptime
        let isDue = now - lastEnumerationUptime >= Self.serviceRefreshInterval
        if let client, cachedServices.isEmpty || isDue {
            cachedServices = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef]) ?? []
            lastEnumerationUptime = now
        }
        return cachedServices
    }

    func readSensors() -> [ThermalSensor] {
        let services = services()
        guard !services.isEmpty else { return [] }

        var readings: [ThermalSensor] = []
        // Several services can share a product and location. The first keeps
        // the plain ID and later ones get their ordinal appended instead of
        // being dropped. Ordinals are assigned before a reading is validated,
        // so one duplicate failing to read never renames another.
        var occurrences: [String: Int] = [:]
        let updatedAt = Date()

        for service in services {
            guard let product = propertyString("Product", service: service) else {
                continue
            }
            // tcal is a calibration reference, not a device hotspot. Including it
            // makes the menu bar and fan curves report a false "hottest" sensor.
            guard !product.lowercased().contains("tcal") else { continue }

            // The raw product string stays in the ID so identities are stable
            // however the display name or category policy evolves.
            let location = propertyNumber("LocationID", service: service).map(String.init) ?? product
            let baseID = "hid-\(product.normalizedSensorID)-\(location)"
            let occurrence = (occurrences[baseID] ?? 0) + 1
            occurrences[baseID] = occurrence
            let id = occurrence == 1 ? baseID : "\(baseID)-\(occurrence)"

            guard
                let event = IOHIDServiceClientCopyEvent(service, eventTypeTemperature, 0, 0),
                let value = HIDTemperaturePolicy.celsius(
                    from: IOHIDEventGetFloatValue(event, eventFieldTemperature)
                )
            else {
                continue
            }

            readings.append(ThermalSensor(
                id: id,
                name: HIDTemperaturePolicy.displayName(for: product),
                category: HIDTemperaturePolicy.category(for: product),
                temperatureC: value,
                source: .system,
                isFavorite: false,
                isHidden: false,
                updatedAt: updatedAt
            ))
        }

        // If a previously-populated service list stops yielding any readings
        // (typically after sleep/wake invalidates the handles), drop the cache
        // so the next call rebuilds it.
        if readings.isEmpty {
            cachedServices = []
        }

        return readings.sorted { $0.name < $1.name }
    }

    private func propertyString(_ key: String, service: IOHIDServiceClientRef) -> String? {
        IOHIDServiceClientCopyProperty(service, key as CFString) as? String
    }

    private func propertyNumber(_ key: String, service: IOHIDServiceClientRef) -> Int? {
        let value = IOHIDServiceClientCopyProperty(service, key as CFString)
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}

/// Filters, names, and classifies values returned by Apple's private HID
/// temperature event stream.
enum HIDTemperaturePolicy {
    /// Applies the same plausibility window as the SMC path (10 C ..< 130 C),
    /// after converting Kelvin readings. Some Apple Silicon PMU services expose
    /// unused `tdev` channels as -1 C or -2 C, or as values near 0 C; those are
    /// firmware sentinels, not physical temperature readings.
    static func celsius(from rawValue: Double) -> Double? {
        guard rawValue.isFinite else { return nil }
        let value = rawValue > 200 ? rawValue - 273.15 : rawValue
        return TemperaturePlausibility.isPlausible(value) ? value : nil
    }

    /// Only products the PMU reports (`PMU ...`) carry a PMU label; other
    /// blocks are named after what their product string identifies.
    static func displayName(for product: String) -> String {
        let isPMUProduct = product.lowercased().hasPrefix("pmu ")
        let rawName = isPMUProduct ? String(product.dropFirst(4)) : product
        let normalized = rawName.lowercased()
        if normalized.hasPrefix("tdie") {
            return numberedName(prefix: isPMUProduct ? "PMU Die" : "Die", suffix: rawName.dropFirst(4))
        }
        if normalized.hasPrefix("tdev") {
            // Apple exposes these as anonymous, model-dependent HID channels.
            // Keep them visible without leaking the cryptic `PMU Device` label
            // or claiming that a number maps to a specific physical component.
            return numberedName(prefix: "System Temperature", suffix: rawName.dropFirst(4))
        }
        if normalized.contains("nand") {
            return rawName.replacingOccurrences(of: "temp", with: "Temperature")
        }
        if normalized.contains("gas gauge") {
            return "Battery Gas Gauge"
        }
        if let blockName = blockSensorName(for: rawName) {
            return blockName
        }
        return isPMUProduct ? "PMU \(rawName)" : rawName
    }

    /// Classifies by product string so die and CPU/GPU cluster sensors qualify
    /// as CPU/GPU curve sources:
    /// - `NAND`/`SSD` -> storage
    /// - battery / gas gauge -> other
    /// - `pACC`/`eACC` CPU clusters and `tdie` die sensors -> CPU
    /// - `GPU` -> GPU
    /// - everything else, including `ANE`, `ISP`, `SOC`, and the anonymous
    ///   `tdev` channels -> other
    static func category(for product: String) -> SensorCategory {
        let normalized = product.lowercased()
        if normalized.contains("nand") || normalized.contains("ssd") {
            return .storage
        }
        if normalized.contains("gas gauge") || normalized.contains("battery") {
            return .other
        }
        let words = normalized.split { $0 == " " || $0 == "_" || $0 == "-" }
        if words.contains(where: { $0 == "pacc" || $0 == "eacc" || $0.hasPrefix("tdie") }) {
            return .cpu
        }
        if words.contains("gpu") {
            return .gpu
        }
        return .other
    }

    private static let blockLabels: [String: String] = [
        "pacc": "CPU Performance Cluster",
        "eacc": "CPU Efficiency Cluster",
        "gpu": "GPU",
        "ane": "Neural Engine",
        "isp": "Image Processor",
        "soc": "SoC"
    ]

    /// `pACC MTR Temp Sensor2` -> `CPU Performance Cluster Sensor 2`. Only the
    /// block named by the product's first word is interpreted; the trailing
    /// number is kept as-is rather than mapped to a physical core.
    private static func blockSensorName(for product: String) -> String? {
        guard
            let block = product.split(separator: " ").first,
            let label = blockLabels[block.lowercased()]
        else {
            return nil
        }
        let number = String(product.reversed().prefix { $0.isNumber }.reversed())
        return number.isEmpty ? "\(label) Temperature" : "\(label) Sensor \(number)"
    }

    private static func numberedName(prefix: String, suffix: Substring) -> String {
        let number = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        return number.isEmpty ? prefix : "\(prefix) \(number)"
    }
}

private extension String {
    var normalizedSensorID: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}
