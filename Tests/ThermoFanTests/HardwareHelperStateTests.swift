import XCTest
@testable import ThermoFan

final class HardwareHelperStateTests: XCTestCase {
    func testOnlyReadyAndCompatibleLegacyHelpersAreUsable() {
        XCTAssertFalse(HardwareHelperState.missing.isUsable)
        XCTAssertFalse(HardwareHelperState.updateRequired.isUsable)
        XCTAssertTrue(HardwareHelperState.legacyCompatible.isUsable)
        XCTAssertTrue(HardwareHelperState.ready.isUsable)
    }
}
