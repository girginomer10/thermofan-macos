import XCTest
@testable import ThermoFan

final class SensorContinuityTests: XCTestCase {
    func testMissingSMCSensorKeepsItsLastValidReading() {
        let previous = sensor(id: "Tp0G", source: .smc, temperature: 71)

        let merged = SensorContinuity.merging(incoming: [], previous: [previous])

        XCTAssertEqual(merged, [previous])
    }

    func testNewReadingReplacesPreviousValueWithoutDuplication() {
        let previous = sensor(id: "Tp0G", source: .smc, temperature: 60)
        let incoming = sensor(id: "Tp0G", source: .smc, temperature: 72)

        let merged = SensorContinuity.merging(incoming: [incoming], previous: [previous])

        XCTAssertEqual(merged, [incoming])
    }

    func testMissingSystemSensorIsNotRetained() {
        let previous = sensor(id: "nand", source: .system, temperature: 45)

        XCTAssertTrue(SensorContinuity.merging(incoming: [], previous: [previous]).isEmpty)
    }

    func testFreshnessAllowsThreeRefreshIntervalsWithMinimumGrace() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let recent = sensor(id: "Tp0G", source: .smc, temperature: 70, updatedAt: now.addingTimeInterval(-5))
        let stale = sensor(id: "Tp0H", source: .smc, temperature: 70, updatedAt: now.addingTimeInterval(-7))

        XCTAssertTrue(SensorContinuity.isFresh(recent, now: now, refreshInterval: 1))
        XCTAssertFalse(SensorContinuity.isFresh(stale, now: now, refreshInterval: 1))
    }

    func testFlatFortyDegreePerformanceCoreGroupIsRemoved() {
        let sensors = [
            sensor(id: "TCMb", name: "CPU Core Max", temperature: 67),
            sensor(id: "Tp0G", name: "CPU Performance Core 1", temperature: 40),
            sensor(id: "Tp0H", name: "CPU Performance Core 2", temperature: 40)
        ]

        let filtered = SensorContinuity.removingFlatPerformanceCoreSentinels(from: sensors)

        XCTAssertEqual(filtered.map(\.id), ["TCMb"])
    }

    func testChangingPerformanceCoreGroupIsKept() {
        let sensors = [
            sensor(id: "Tp0G", name: "CPU Performance Core 1", temperature: 52),
            sensor(id: "Tp0H", name: "CPU Performance Core 2", temperature: 58)
        ]

        XCTAssertEqual(SensorContinuity.removingFlatPerformanceCoreSentinels(from: sensors), sensors)
    }

    private func sensor(
        id: String,
        name: String? = nil,
        source: ReadingSource = .smc,
        temperature: Double,
        updatedAt: Date = Date()
    ) -> ThermalSensor {
        ThermalSensor(
            id: id,
            name: name ?? id,
            category: .cpu,
            temperatureC: temperature,
            source: source,
            isFavorite: false,
            isHidden: false,
            updatedAt: updatedAt
        )
    }
}
