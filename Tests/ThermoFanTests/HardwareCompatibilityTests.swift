import XCTest
import FanSafetyPolicy
@testable import ThermoFan

final class HardwareCompatibilityTests: XCTestCase {
    func testUppercasePerFanModeTakesPriority() {
        let values = ["F0Md": 0.0, "F0md": 1.0, "FS! ": 1.0]

        XCTAssertEqual(
            FanControlInterfacePolicy.detect(fanIndex: 0, read: { values[$0] }),
            .perFanMode(key: "F0Md")
        )
    }

    func testLowercasePerFanModeSupportsNewerFirmware() {
        let values = ["F1md": 1.0]

        XCTAssertEqual(
            FanControlInterfacePolicy.detect(fanIndex: 1, read: { values[$0] }),
            .perFanMode(key: "F1md")
        )
    }

    func testUnknownUppercaseModeFallsThroughToValidLowercaseMode() {
        let values = ["F0Md": 2.0, "F0md": 0.0]

        XCTAssertEqual(
            FanControlInterfacePolicy.detect(fanIndex: 0, read: { values[$0] }),
            .perFanMode(key: "F0md")
        )
    }

    func testForceMaskIsNotAGenericAppleSiliconFallback() {
        let values = ["FS! ": 2.0]

        XCTAssertEqual(
            FanControlInterfacePolicy.detect(fanIndex: 1, read: { values[$0] }),
            .unavailable
        )
        XCTAssertEqual(
            FanControlInterfacePolicy.detect(fanIndex: 1, allowForceMask: true, read: { values[$0] }),
            .forceMask(key: "FS! ")
        )
    }

    func testModeValuesTreatSystemAsAutomaticAndRejectUnknownState() {
        let interface = FanControlInterface.perFanMode(key: "F0Md")

        XCTAssertEqual(mode(interface, value: 0), .automatic)
        XCTAssertEqual(mode(interface, value: 1), .fixed)
        XCTAssertEqual(mode(interface, value: 3), .automatic)
        XCTAssertNil(mode(interface, value: 2))
        XCTAssertNil(mode(interface, value: .nan))
    }

    func testForceMaskReadsEachFanBitIndependently() {
        let interface = FanControlInterface.forceMask(key: "FS! ")
        let values = ["FS! ": 2.0]

        XCTAssertEqual(
            FanControlInterfacePolicy.hardwareMode(fanIndex: 0, interface: interface, read: { values[$0] }),
            .automatic
        )
        XCTAssertEqual(
            FanControlInterfacePolicy.hardwareMode(fanIndex: 1, interface: interface, read: { values[$0] }),
            .fixed
        )
    }

    func testLowercaseTwoFanFixtureDiscoversTopologyAndModes() {
        let smc = FakeSMC(values: [
            "FNum": 2,
            "F0Mn": 1_350, "F0Mx": 5_349, "F0Ac": 1_500, "F0Tg": 1_350, "F0md": 0,
            "F1Mn": 1_458, "F1Mx": 5_777, "F1Ac": 1_600, "F1Tg": 2_200, "F1md": 1
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertEqual(snapshot.fans.count, 2)
        XCTAssertEqual(snapshot.fans[0].controlInterface, .perFanMode(key: "F0md"))
        XCTAssertEqual(snapshot.fans[0].hardwareMode, .automatic)
        XCTAssertEqual(snapshot.fans[1].controlInterface, .perFanMode(key: "F1md"))
        XCTAssertEqual(snapshot.fans[1].hardwareMode, .fixed)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testReadableFanWithoutModeKeyIsMonitoringOnlyEvenWhenForceMaskExists() {
        let smc = FakeSMC(values: [
            "FNum": 1, "F0Mn": 1_000, "F0Mx": 4_900,
            "F0Ac": 1_200, "F0Tg": 1_000, "FS! ": 1
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertEqual(snapshot.fans.count, 1)
        XCTAssertEqual(snapshot.fans[0].controlInterface, .unavailable)
        XCTAssertNil(snapshot.fans[0].hardwareMode)
        XCTAssertEqual(snapshot.warnings.count, 1)
    }

    func testFanlessFixtureProducesNoSyntheticFan() {
        let snapshot = probe(FakeSMC(values: ["FNum": 0])).sample(preferences: .defaults)

        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testMissingFanCountIsNotMisreportedAsConfirmedFanless() {
        let snapshot = probe(FakeSMC(values: [:])).sample(preferences: .defaults)

        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertEqual(snapshot.warnings.count, 1)
        XCTAssertTrue(snapshot.warnings[0].contains("fan count"))
    }

    func testMissingTargetRegisterMakesReadableFanMonitoringOnly() {
        let smc = FakeSMC(values: [
            "FNum": 1, "F0Mn": 1_000, "F0Mx": 4_900,
            "F0Ac": 1_200, "F0Md": 0
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertEqual(snapshot.fans.first?.controlInterface, .unavailable)
        XCTAssertNil(snapshot.fans.first?.hardwareMode)
    }

    func testLegacyCoreFamilyIsStillDiscoveredOnAnMSeriesName() {
        let smc = FakeSMC(values: [
            "FNum": 0,
            "Tp01": 52, "Tp05": 54, "Tp0D": 56
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertEqual(
            Set(snapshot.sensors.filter { $0.name.contains("Performance Core") }.map(\.id)),
            Set(["Tp01", "Tp05", "Tp0D"])
        )
    }

    func testUniformFortyModernAndLegacyFamiliesAreBothRejected() {
        let allKeys = SMCSensorCatalog.modernPerformanceCandidates
            + SMCSensorCatalog.legacyCoreCandidates
        var values = Dictionary(uniqueKeysWithValues: allKeys.map { ($0.key, 40.0) })
        values["FNum"] = 0

        let snapshot = probe(FakeSMC(values: values)).sample(preferences: .defaults)

        XCTAssertFalse(snapshot.sensors.contains { $0.name.contains("Performance Core") })
        XCTAssertFalse(snapshot.sensors.contains { $0.name.contains("Efficiency Core") })
        XCTAssertFalse(snapshot.sensors.contains { $0.id == "Tp0P" })
    }

    func testWakeClearsReaderNegativeCache() {
        let smc = FakeSMC(values: ["FNum": 0])
        let hardwareProbe = probe(smc)

        hardwareProbe.prepareAfterWake()

        XCTAssertEqual(smc.resetCount, 1)
    }

    func testNonFiniteAndOutOfRangeNumericValuesAreRejected() {
        XCTAssertNil(SMCNumericPolicy.fanCount(.nan))
        XCTAssertNil(SMCNumericPolicy.fanCount(1.5))
        XCTAssertEqual(SMCNumericPolicy.fanCount(8), 8)
        XCTAssertNil(SMCNumericPolicy.fanCount(9))
        XCTAssertNil(SMCNumericPolicy.rpm(.infinity))
        XCTAssertNil(SMCNumericPolicy.rpm(-1))
        XCTAssertNil(SMCNumericPolicy.rpm(65_535))
        XCTAssertNil(SMCNumericPolicy.rpm(20_001))
        XCTAssertEqual(SMCNumericPolicy.rpm(1_234.75), 1_234)
    }

    func testSentinelRPMRangeCannotEnableControl() {
        let smc = FakeSMC(values: [
            "FNum": 1, "F0Mn": 1_000, "F0Mx": 65_535,
            "F0Ac": 1_200, "F0Tg": 1_000, "F0Md": 0
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertEqual(snapshot.warnings.count, 1)
    }

    func testIncoherentCurrentRPMCannotEnableControl() {
        let smc = FakeSMC(values: [
            "FNum": 1, "F0Mn": 1_000, "F0Mx": 4_900,
            "F0Ac": 8_000, "F0Tg": 1_000, "F0Md": 0
        ])

        let snapshot = probe(smc).sample(preferences: .defaults)

        XCTAssertTrue(snapshot.fans.isEmpty)
        XCTAssertEqual(snapshot.warnings.count, 1)
    }

    func testUnownedAutoFailureDoesNotPromiseWatchdogRecovery() {
        let status = thermofan_status_after_persisted_ownership_check(
            1,
            FanControlService.recoveryRequiredExitCode,
            0,
            0,
            0
        )

        XCTAssertEqual(status, 1)
    }

    func testOwnedFanFailureRequiresWatchdogRecovery() {
        let status = thermofan_status_after_persisted_ownership_check(
            1,
            FanControlService.recoveryRequiredExitCode,
            1,
            1,
            1
        )

        XCTAssertEqual(status, FanControlService.recoveryRequiredExitCode)
    }

    func testOwnershipRecoveryRequiresMatchingOwnerAndFanBit() {
        XCTAssertEqual(
            thermofan_status_after_persisted_ownership_check(
                1,
                FanControlService.recoveryRequiredExitCode,
                1,
                0,
                1
            ),
            1
        )
        XCTAssertEqual(
            thermofan_status_after_persisted_ownership_check(
                1,
                FanControlService.recoveryRequiredExitCode,
                1,
                1,
                0
            ),
            1
        )
    }

    func testProcessIdentityRejectsPIDReuse() {
        XCTAssertEqual(
            thermofan_process_identity_matches(42, 1_700_000_000, 123_456, 42, 1_700_000_000, 123_456),
            1
        )
        XCTAssertEqual(
            thermofan_process_identity_matches(42, 1_700_000_000, 123_456, 42, 1_700_000_001, 123_456),
            0
        )
        XCTAssertEqual(
            thermofan_process_identity_matches(42, 1_700_000_000, 123_456, 42, 1_700_000_000, 654_321),
            0
        )
    }

    func testGoldenLegacyV7OwnershipStateIsAccepted() {
        let bytes: [UInt8] = [
            0x36, 0x46, 0x46, 0x54, 0x01, 0x00, 0x00, 0x00,
            0x2A, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xC4, 0xD0, 0x27, 0xD4
        ]
        var decoded = ThermoFanLegacyFanState()

        let isValid = bytes.withUnsafeBufferPointer { buffer in
            thermofan_decode_legacy_fan_state(buffer.baseAddress, buffer.count, &decoded)
        }

        XCTAssertEqual(isValid, 1)
        XCTAssertEqual(decoded.owner_pid, 42)
        XCTAssertEqual(decoded.touched_mask, 0b11)
        XCTAssertEqual(decoded.refcount, 2)
        XCTAssertEqual(decoded.flags, 1)
    }

    func testLegacyOwnershipRejectsBadChecksumAndValidlyChecksummedBadMask() {
        var badChecksum: [UInt8] = [
            0x36, 0x46, 0x46, 0x54, 0x01, 0x00, 0x00, 0x00,
            0x2A, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
            0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
            0xC4, 0xD0, 0x27, 0xD4
        ]
        badChecksum[27] ^= 0x01
        let badMask: [UInt8] = [
            0x36, 0x46, 0x46, 0x54, 0x01, 0x00, 0x00, 0x00,
            0x2A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x0E, 0x10, 0xC1, 0xED
        ]

        XCTAssertEqual(
            badChecksum.withUnsafeBufferPointer {
                thermofan_decode_legacy_fan_state($0.baseAddress, $0.count, nil)
            },
            0
        )
        XCTAssertEqual(
            badMask.withUnsafeBufferPointer {
                thermofan_decode_legacy_fan_state($0.baseAddress, $0.count, nil)
            },
            0
        )
    }

    func testLegacyMigrationBlocksNewWritesUntilAutoRecoveryIsVerified() {
        XCTAssertEqual(thermofan_legacy_migration_allows_new_write(0), 0)
        XCTAssertEqual(thermofan_legacy_migration_allows_new_write(1), 1)
    }

    private func mode(_ interface: FanControlInterface, value: Double) -> FanMode? {
        FanControlInterfacePolicy.hardwareMode(
            fanIndex: 0,
            interface: interface,
            read: { _ in value }
        )
    }

    private func probe(_ smc: FakeSMC) -> HardwareProbe {
        HardwareProbe(
            smc: smc,
            hidReader: FakeHID(),
            modelIdentifier: "FixtureMac",
            chipName: "Apple M Fixture",
            osVersion: "macOS Fixture"
        )
    }
}

private final class FakeSMC: SMCReadingProviding {
    private let values: [String: Double]
    private(set) var resetCount = 0

    init(values: [String: Double]) {
        self.values = values
    }

    func readNumber(key: String) throws -> SMCReading {
        guard let value = values[key] else {
            throw SMCError.smcResult(0x84)
        }
        return SMCReading(key: key, type: "flt", value: value)
    }

    func resetCacheAfterWake() {
        resetCount += 1
    }
}

private final class FakeHID: HIDTemperatureReadingProviding {
    func readSensors() -> [ThermalSensor] { [] }
}
