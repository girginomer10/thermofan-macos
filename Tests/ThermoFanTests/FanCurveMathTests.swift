import XCTest
@testable import ThermoFan

final class FanCurveMathTests: XCTestCase {
    func testNormalizationCollapsesDuplicateTemperaturesAndKeepsRPMMonotonic() {
        let points = [
            FanCurvePoint(temperatureC: 45, rpm: 1300),
            FanCurvePoint(temperatureC: 53, rpm: 4900),
            FanCurvePoint(temperatureC: 68.5, rpm: 2950),
            FanCurvePoint(temperatureC: 68.5, rpm: 2950),
            FanCurvePoint(temperatureC: 82, rpm: 3800),
            FanCurvePoint(temperatureC: 95, rpm: 4900)
        ]

        let normalized = FanCurveMath.normalized(points, minRPM: 1000, maxRPM: 4900)

        XCTAssertEqual(normalized.count, 5)
        XCTAssertTrue(zip(normalized, normalized.dropFirst()).allSatisfy {
            $1.temperatureC - $0.temperatureC >= FanCurveMath.minimumTemperatureSpacing
        })
        XCTAssertTrue(zip(normalized, normalized.dropFirst()).allSatisfy { $0.rpm <= $1.rpm })
    }

    func testPointUpdateCannotCrossItsNeighborsOrCreateFallingFanSpeed() {
        let first = FanCurvePoint(temperatureC: 40, rpm: 1200)
        let middle = FanCurvePoint(temperatureC: 60, rpm: 2400)
        let last = FanCurvePoint(temperatureC: 80, rpm: 4000)

        let updated = FanCurveMath.updating(
            [first, middle, last],
            pointID: middle.id,
            temperature: 100,
            rpm: 5000,
            minRPM: 1000,
            maxRPM: 4900
        )

        XCTAssertEqual(updated[1].temperatureC, 79)
        XCTAssertEqual(updated[1].rpm, 4000)
    }

    func testAddingPointUsesLargestGapWithoutDuplicatingTemperature() {
        let points = [
            FanCurvePoint(temperatureC: 40, rpm: 1200),
            FanCurvePoint(temperatureC: 50, rpm: 1800),
            FanCurvePoint(temperatureC: 90, rpm: 4500)
        ]

        let updated = FanCurveMath.addingPoint(to: points, minRPM: 1000, maxRPM: 4900)

        XCTAssertEqual(updated.count, 4)
        XCTAssertTrue(updated.contains { $0.temperatureC == 70 })
        XCTAssertEqual(Set(updated.map(\.temperatureC)).count, updated.count)
    }

    func testInterpolationUsesSafeNormalizedCurve() {
        let points = [
            FanCurvePoint(temperatureC: 40, rpm: 1000),
            FanCurvePoint(temperatureC: 80, rpm: 4000)
        ]

        XCTAssertEqual(
            FanCurveMath.interpolatedRPM(
                temperature: 60,
                points: points,
                minRPM: 1000,
                maxRPM: 4900,
                fallback: 1000
            ),
            2500
        )
    }
}
