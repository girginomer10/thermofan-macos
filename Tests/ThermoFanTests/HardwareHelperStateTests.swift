import XCTest
@testable import ThermoFan

final class HardwareHelperStateTests: XCTestCase {
    func testOnlyReadyAndCompatibleLegacyHelpersAreUsable() {
        XCTAssertFalse(HardwareHelperState.missing.isUsable)
        XCTAssertFalse(HardwareHelperState.updateRequired.isUsable)
        XCTAssertTrue(HardwareHelperState.legacyCompatible.isUsable)
        XCTAssertTrue(HardwareHelperState.ready.isUsable)
    }

    func testProcessIdentitySafetyRequiresV8ForEveryHelperPath() {
        XCTAssertEqual(FanControlService.expectedHelperVersion, "8")
        XCTAssertEqual(FanControlService.compatibleLegacyHelperVersion, "8")
        XCTAssertEqual(FanControlService.watchdogReadyPrefix, "THERMOFAN_WATCHDOG_READY_V8")
    }
}
