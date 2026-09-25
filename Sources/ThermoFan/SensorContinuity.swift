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
        return removingFlatCoreSentinels(from: merged)
    }

    /// Some Apple Silicon SMC firmwares expose the legacy `Tp0*` performance
    /// keys but return 40 C for every key, even while the CPU hotspot changes.
    /// That is a sentinel, not per-core telemetry. Hide the entire group rather
    /// than presenting it as a real, current measurement.
    static func removingFlatCoreSentinels(from sensors: [ThermalSensor]) -> [ThermalSensor] {
        var result = sensors

        let performanceCores = result.filter {
            $0.name.localizedCaseInsensitiveContains("Performance Core")
        }
        if performanceCores.count >= 2,
           performanceCores.allSatisfy({ abs($0.temperatureC - 40) < 0.01 })
        {
            let sentinelIDs = Set(performanceCores.map(\.id))
            result = result.filter { !sentinelIDs.contains($0.id) }
        }

        let gpuCores = result.filter {
            $0.name.localizedCaseInsensitiveContains("GPU Core")
        }
        if gpuCores.count >= 2,
           gpuCores.allSatisfy({ abs($0.temperatureC - 40) < 0.01 })
        {
            let sentinelIDs = Set(gpuCores.map(\.id))
            result = result.filter { !sentinelIDs.contains($0.id) }
        }

        return result
    }

    /// Whether the reading was updated recently enough to be shown as current.
    /// Every source, including `.estimated`, is judged by its timestamp; an
    /// estimated reading is never a measurement, so callers that drive fan
    /// control must additionally exclude `.estimated` sensors themselves.
    static func isFresh(
        _ sensor: ThermalSensor,
        now: Date = Date(),
        refreshInterval: TimeInterval
    ) -> Bool {
        let freshnessWindow = max(6, refreshInterval * 3)
        return now.timeIntervalSince(sensor.updatedAt) <= freshnessWindow
    }

    /// Whether a reading may drive a fan write: it must be a fresh, real
    /// measurement (or an index built from them), never an estimate.
    static func isUsableForControl(
        _ sensor: ThermalSensor,
        now: Date = Date(),
        refreshInterval: TimeInterval
    ) -> Bool {
        sensor.source != .estimated
            && isFresh(sensor, now: now, refreshInterval: refreshInterval)
    }
}
