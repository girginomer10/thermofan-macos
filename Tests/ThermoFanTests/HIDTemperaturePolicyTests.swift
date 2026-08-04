import XCTest
@testable import ThermoFan

final class HIDTemperaturePolicyTests: XCTestCase {
    func testRejectsNegativePMUSentinelValues() {
        XCTAssertNil(HIDTemperaturePolicy.celsius(from: -1))
        XCTAssertNil(HIDTemperaturePolicy.celsius(from: -2))
    }

    func testKeepsPlausibleCelsiusReading() {
        XCTAssertEqual(HIDTemperaturePolicy.celsius(from: 42.5), 42.5)
    }

    func testConvertsKelvinReading() {
        let temperature = try? XCTUnwrap(HIDTemperaturePolicy.celsius(from: 315.65))
        XCTAssertEqual(temperature ?? 0, 42.5, accuracy: 0.001)
    }

    func testRejectsNonFiniteAndExcessiveReadings() {
        XCTAssertNil(HIDTemperaturePolicy.celsius(from: .nan))
        XCTAssertNil(HIDTemperaturePolicy.celsius(from: .infinity))
        XCTAssertNil(HIDTemperaturePolicy.celsius(from: 403.15))
    }

    func testAnonymousPMUDevicesUseHumanReadableSystemNames() {
        XCTAssertEqual(
            HIDTemperaturePolicy.displayName(for: "PMU tdev1"),
            "System Temperature 1"
        )
        XCTAssertEqual(
            HIDTemperaturePolicy.displayName(for: "pmu tdev5"),
            "System Temperature 5"
        )
    }

    func testKnownPMUNameHandlingIsPreserved() {
        XCTAssertEqual(HIDTemperaturePolicy.displayName(for: "PMU tdie2"), "PMU Die 2")
        XCTAssertEqual(HIDTemperaturePolicy.displayName(for: "PMU NAND temp"), "NAND Temperature")
    }
}
