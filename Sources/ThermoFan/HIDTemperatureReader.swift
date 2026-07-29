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

    // The event-system client and its matching service list are expensive to
    // build (a Mach connection to hidd plus a full service enumeration), so
    // create them once and reuse. Services are re-enumerated only when the
    // cached list disappears (e.g. after sleep/wake).
    private var client: IOHIDEventSystemClientRef?
    private var cachedServices: [IOHIDServiceClientRef] = []

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
        if cachedServices.isEmpty, let client {
            cachedServices = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef]) ?? []
        }
        return cachedServices
    }

    func readSensors() -> [ThermalSensor] {
        let services = services()
        guard !services.isEmpty else { return [] }

        var readings: [ThermalSensor] = []
        var seenIDs = Set<String>()

        for service in services {
            guard
                let product = propertyString("Product", service: service),
                let event = IOHIDServiceClientCopyEvent(service, eventTypeTemperature, 0, 0)
            else {
                continue
            }

            let normalizedProduct = product.lowercased()
            // tcal is a calibration reference, not a device hotspot. Including it
            // makes the menu bar and fan curves report a false "hottest" sensor.
            guard !normalizedProduct.contains("tcal") else { continue }

            var value = IOHIDEventGetFloatValue(event, eventFieldTemperature)
            if value > 200 {
                value -= 273.15
            }

            guard value.isFinite, value > -20, value < 130 else {
                continue
            }

            let location = propertyNumber("LocationID", service: service).map(String.init) ?? product
            let id = "hid-\(product.normalizedSensorID)-\(location)"
            guard !seenIDs.contains(id) else { continue }
            seenIDs.insert(id)

            readings.append(ThermalSensor(
                id: id,
                name: Self.displayName(for: product),
                category: Self.category(for: normalizedProduct),
                temperatureC: value,
                source: .system,
                isFavorite: false,
                isHidden: false,
                updatedAt: Date()
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

    private static func category(for normalizedProduct: String) -> SensorCategory {
        if normalizedProduct.contains("nand") || normalizedProduct.contains("ssd") {
            return .storage
        }
        return .other
    }

    private static func displayName(for product: String) -> String {
        let rawName = product.replacingOccurrences(of: "PMU ", with: "")
        let normalized = rawName.lowercased()
        if normalized.hasPrefix("tdie") {
            return "PMU Die \(rawName.dropFirst(4))"
        }
        if normalized.hasPrefix("tdev") {
            return "PMU Device \(rawName.dropFirst(4))"
        }
        if normalized.contains("nand") {
            return rawName.replacingOccurrences(of: "temp", with: "Temperature")
        }
        return "PMU \(rawName)"
    }
}

private extension String {
    var normalizedSensorID: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}
