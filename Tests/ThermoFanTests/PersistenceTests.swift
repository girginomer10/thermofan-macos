import XCTest
@testable import ThermoFan

final class PersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThermoFanPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSavedStateRoundTrips() {
        let controller = PersistenceController(fileURL: directory.appendingPathComponent("state.json"))
        let state = PersistedState(
            preferences: .defaults,
            presets: [],
            sensorPreferences: ["TCMz": SensorPreference(isFavorite: true, isHidden: false)],
            fanSettings: [
                "fan0": FanPresetSetting(
                    mode: .curve,
                    targetRPM: 2200,
                    linkedSensorID: nil,
                    curve: [FanCurvePoint(temperatureC: 50, rpm: 1500)]
                )
            ],
            customIndexes: []
        )

        controller.save(state, sequence: 1)

        XCTAssertEqual(controller.load(), state)
    }

    func testOlderSequenceCannotOverwriteNewerSnapshot() {
        let controller = PersistenceController(fileURL: directory.appendingPathComponent("state.json"))
        var newer = PersistedState(
            preferences: .defaults,
            presets: [],
            sensorPreferences: [:],
            fanSettings: [:],
            customIndexes: []
        )
        newer.preferences.refreshInterval = 5
        let older = PersistedState(
            preferences: .defaults,
            presets: [],
            sensorPreferences: [:],
            fanSettings: [:],
            customIndexes: []
        )

        controller.save(newer, sequence: 2)
        controller.save(older, sequence: 1)

        XCTAssertEqual(controller.load(), newer)
    }

    func testCorruptFileIsBackedUpBeforeDefaultsReplaceIt() throws {
        let fileURL = directory.appendingPathComponent("state.json")
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: fileURL)
        let controller = PersistenceController(fileURL: fileURL)

        XCTAssertNil(controller.load())

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertFalse(try XCTUnwrap(backups.first).contains(":"))
        let backupData = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(backups.first)))
        XCTAssertEqual(backupData, corrupt)
    }
}
