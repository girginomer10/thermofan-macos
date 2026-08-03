import Foundation

enum SensorContinuity {
    /// SMC core keys can temporarily return sleep/sentinel values. Keep an
    /// already-discovered SMC topology stable for the rest of this app session;
    /// `updatedAt` still exposes whether the value itself is current.
    static func merging(incoming: [ThermalSensor], previous: [ThermalSensor]) -> [ThermalSensor] {
        var merged = incoming
        var sensorIDs = Set(incoming.map(\.id))

        for sensor in previous where sensor.source == .smc && !sensorIDs.contains(sensor.id) {
            merged.append(sensor)
            sensorIDs.insert(sensor.id)
        }
        return removingFlatPerformanceCoreSentinels(from: merged)
    }

    /// Some Apple Silicon SMC firmwares expose the legacy `Tp0*` performance
    /// keys but return 40 C for every key, even while the CPU hotspot changes.
    /// That is a sentinel, not per-core telemetry. Hide the entire group rather
    /// than presenting it as a real, current measurement.
    static func removingFlatPerformanceCoreSentinels(from sensors: [ThermalSensor]) -> [ThermalSensor] {
        let performanceCores = sensors.filter {
            $0.name.localizedCaseInsensitiveContains("Performance Core")
        }
        guard performanceCores.count >= 2,
              performanceCores.allSatisfy({ abs($0.temperatureC - 40) < 0.01 })
        else {
            return sensors
        }

        let sentinelIDs = Set(performanceCores.map(\.id))
        return sensors.filter { !sentinelIDs.contains($0.id) }
    }

    static func isFresh(
        _ sensor: ThermalSensor,
        now: Date = Date(),
        refreshInterval: TimeInterval
    ) -> Bool {
        guard sensor.source != .estimated else { return true }
        let freshnessWindow = max(6, refreshInterval * 3)
        return now.timeIntervalSince(sensor.updatedAt) <= freshnessWindow
    }
}
