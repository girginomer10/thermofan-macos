import XCTest
@testable import ThermoFan

final class TemperatureSmoothingTests: XCTestCase {
    func testMedianRejectsSingleSampleSpike() {
        XCTAssertEqual(TemperatureSmoothing.median([52, 98, 53], fallback: 0), 53)
    }

    func testMedianUsesFallbackWhenHistoryIsEmpty() {
        XCTAssertEqual(TemperatureSmoothing.median([], fallback: 47.5), 47.5)
    }

    func testAppendingKeepsOnlyNewestReadings() {
        XCTAssertEqual(
            TemperatureSmoothing.appending(54, to: [50, 51, 52, 53], maximumCount: 3),
            [52, 53, 54]
        )
    }
}
