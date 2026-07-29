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
        return merged
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
