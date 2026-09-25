import Foundation

struct PersistedState: Codable, Equatable {
    var preferences: AppPreferences
    var presets: [FanPreset]
    var sensorPreferences: [String: SensorPreference]
    var fanSettings: [String: FanPresetSetting]
    var customIndexes: [ThermalIndex]

    init(
        preferences: AppPreferences,
        presets: [FanPreset],
        sensorPreferences: [String: SensorPreference],
        fanSettings: [String: FanPresetSetting],
        customIndexes: [ThermalIndex]
    ) {
        self.preferences = preferences
        self.presets = presets
        self.sensorPreferences = sensorPreferences
        self.fanSettings = fanSettings
        self.customIndexes = customIndexes
    }

    private enum CodingKeys: String, CodingKey {
        case preferences
        case presets
        case sensorPreferences
        case fanSettings
        case customIndexes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try container.decode(AppPreferences.self, forKey: .preferences)
        presets = try container.decode([FanPreset].self, forKey: .presets)
        sensorPreferences = try container.decode([String: SensorPreference].self, forKey: .sensorPreferences)
        fanSettings = try container.decode([String: FanPresetSetting].self, forKey: .fanSettings)
        customIndexes = try container.decodeIfPresent([ThermalIndex].self, forKey: .customIndexes) ?? []
    }
}

/// Reads and writes `state.json`. Writes carry a caller-supplied, monotonically
/// increasing sequence number so a background save queued earlier can never
/// overwrite a newer snapshot (for example the synchronous flush at quit).
final class PersistenceController: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private var lastWrittenSequence: UInt64?

    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = support.appendingPathComponent("ThermoFan", isDirectory: true)
        self.init(fileURL: directory.appendingPathComponent("state.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Returns the saved state, or `nil` when there is none or it cannot be
    /// decoded. An undecodable file is first copied aside as
    /// `state.json.corrupt-<ISO date>` so the defaults written afterwards never
    /// destroy the only copy of the user's settings.
    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            backUpCorruptFile()
            return nil
        }
    }

    /// Writes `state` unless a snapshot with a newer sequence number was already
    /// written. A `nil` sequence writes unconditionally.
    func save(_ state: PersistedState, sequence: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let sequence {
            if let lastWrittenSequence, sequence < lastWrittenSequence { return }
            lastWrittenSequence = sequence
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    /// Copies the current file to `<name>.corrupt-<basic ISO 8601 date>` and
    /// returns the backup location, or `nil` if the copy failed.
    @discardableResult
    func backUpCorruptFile(now: Date = Date()) -> URL? {
        let formatter = ISO8601DateFormatter()
        // Basic format (no colons) keeps the file name valid in every file UI.
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let stamp = formatter.string(from: now)
        let directory = fileURL.deletingLastPathComponent()
        let baseName = "\(fileURL.lastPathComponent).corrupt-\(stamp)"
        var destination = directory.appendingPathComponent(baseName)
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        do {
            try FileManager.default.copyItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
