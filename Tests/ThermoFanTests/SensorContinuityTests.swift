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

    private func sensor(
        id: String,
        source: ReadingSource,
        temperature: Double,
        updatedAt: Date = Date()
    ) -> ThermalSensor {
        ThermalSensor(
            id: id,
            name: id,
            category: .cpu,
            temperatureC: temperature,
            source: source,
            isFavorite: false,
            isHidden: false,
            updatedAt: updatedAt
        )
    }
}
