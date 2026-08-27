import AppKit
import Combine
import Foundation
import ServiceManagement

/// Bridges the SwiftUI-owned store to the AppKit delegate, which needs it at
/// launch (to restore the Dock-icon policy) and at quit (to return fans to auto).
enum AppStoreBridge {
    @MainActor weak static var store: ThermalStore?
}

@MainActor
final class ThermalStore: ObservableObject {
    @Published var sensors: [ThermalSensor] = []
    @Published var fans: [FanDevice] = []
    @Published var presets: [FanPreset] = []
    @Published var preferences = AppPreferences.defaults
    @Published var machine = MachineSnapshot.empty
    @Published var warnings: [String] = []
    @Published var selectedCategory: SensorCategory?
    @Published var searchText = ""
    @Published var newPresetName = ""
    @Published var customIndexes: [ThermalIndex] = []
    @Published var newIndexName = ""
    @Published var newIndexMode: ThermalIndexMode = .hottest
    @Published var newIndexSensorIDs: Set<String> = []
    @Published var isRefreshing = false
    @Published private(set) var helperState: HardwareHelperState = .missing
    @Published var applyingFanIDs: Set<String> = []
    @Published var installingHelper = false

    private let persistence = PersistenceController()
    private let probe = HardwareProbe()
    private let fanControl = FanControlService()
    private let sampleQueue = DispatchQueue(label: "io.thermofan.sample", qos: .utility)
    private let controlQueue = DispatchQueue(label: "io.thermofan.control", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "io.thermofan.persistence", qos: .background)
    private var sensorPreferences: [String: SensorPreference] = [:]
    private var timer: Timer?
    private var isSampling = false
    private var sampleGeneration: UInt64 = 0
    private var pendingSave: DispatchWorkItem?
    private var wakeCancellable: AnyCancellable?
    private var pendingWakeReapplyAttempts: [String: Int] = [:]
    private var wakeSafetyResetPending = false
    private var activeHardwareFanIDs: Set<String> = []
    private var automaticRecoveryFanIDs: Set<String> = []
    private var automaticRecoveryAttempts: [String: Int] = [:]
    private var lastAppliedConfigurations: [String: FanDevice] = [:]
    private var appWarnings: [String] = []
    /// Last RPM actually written to hardware per fan, used to throttle the curve
    /// control loop so it only re-applies when the target moves meaningfully.
    private var lastAppliedRPM: [String: Int] = [:]
    private static let curveHysteresisRPM = 100
    private static let maximumWakeReapplyAttempts = 3
    private static let maximumAutomaticRecoveryAttempts = 3
    private static let legacyMigrationWarning = "Security upgrade required: an older privileged ThermoFan helper is still installed. Approve the authenticated Hardware Helper migration to revoke and remove it before using fan control."
    /// Ring buffer of recent temperature readings per sensor (max 3). Used to
    /// compute a median for the menu bar display, preventing transient SMC
    /// spikes from flashing a misleading value in the status bar.
    private var recentReadings: [String: [Double]] = [:]
    private static let medianWindowSize = 3

    var helperInstalled: Bool {
        helperState.isUsable
    }

    func isSensorFresh(_ sensor: ThermalSensor, now: Date = Date()) -> Bool {
        SensorContinuity.isFresh(
            sensor,
            now: now,
            refreshInterval: preferences.refreshInterval
        )
    }

    init() {
        load()
        helperState = fanControl.persistentHelperState
        preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        AppStoreBridge.store = self
        applyActivationPolicy()
        wakeCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.handleWake()
                }
            }
        if fanControl.hasLegacyPrivilegedHelper {
            updateLegacyMigrationWarning()
            installHelper()
        }
        refresh()
        restartTimer()
    }

    /// Sensors eligible for readouts and control: everything the user has not
    /// hidden, independent of the Sensors-pane search/category filters.
    var unhiddenSensors: [ThermalSensor] {
        sensors.filter { !$0.isHidden }
    }

    var hottestSensor: ThermalSensor? {
        let freshSensors = unhiddenSensors.filter { isSensorFresh($0) }
        return (freshSensors.isEmpty ? unhiddenSensors : freshSensors)
            .max { smoothedTemperature($0) < smoothedTemperature($1) }
    }

    var menuSensors: [ThermalSensor] {
        let ids = preferences.menuSensorIDs
        let raw: [ThermalSensor]
        if ids.isEmpty {
            raw = hottestSensor.map { [$0] } ?? []
        } else {
            let lookup = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })
            raw = ids.compactMap { lookup[$0] }.filter { !$0.isHidden }
        }
        // Replace the raw temperature with the median-smoothed value so the
        // menu bar doesn't flash a transient spike.
        return raw.map { sensor in
            var smoothed = sensor
            smoothed.temperatureC = smoothedTemperature(sensor)
            return smoothed
        }
    }

    var curveSourceSensors: [ThermalSensor] {
        sensors.filter { !$0.isHidden }.sorted {
            if $0.source == .index, $1.source != .index {
                return true
            }
            if $0.source != .index, $1.source == .index {
                return false
            }
            return $0.displaySortKey < $1.displaySortKey
        }
    }

    var indexInputSensors: [ThermalSensor] {
        sensors
            .filter { !$0.isHidden && !$0.id.hasPrefix("index-custom-") }
            .sorted { $0.displaySortKey < $1.displaySortKey }
    }

    /// Non-hidden sensors for the menu panel and quick-stat counts. Deliberately
    /// ignores the Sensors-pane search/category filters so browsing the settings
    /// list never changes what the menu bar or curve fallback sees.
    var panelSensors: [ThermalSensor] {
        unhiddenSensors.sorted {
            if $0.isFavorite != $1.isFavorite {
                return $0.isFavorite && !$1.isFavorite
            }
            return $0.displaySortKey < $1.displaySortKey
        }
    }

    /// Source for the Sensors settings table. Applies the search/category filters
    /// and *includes* hidden sensors so their visibility toggle stays reachable.
    var settingsSensors: [ThermalSensor] {
        var result = sensors
        if let selectedCategory {
            result = result.filter { $0.category == selectedCategory }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { sensor in
                sensor.name.lowercased().contains(query) || sensor.category.title.lowercased().contains(query)
            }
        }
        return result.sorted {
            if $0.isHidden != $1.isHidden {
                return !$0.isHidden && $1.isHidden
            }
            if $0.isFavorite != $1.isFavorite {
                return $0.isFavorite && !$1.isFavorite
            }
            return $0.displaySortKey < $1.displaySortKey
        }
    }

    var activePresetName: String {
        presets.first { preset in
            guard !preset.fanSettings.isEmpty else { return false }
            return preset.fanSettings.allSatisfy { fanID, setting in
                guard let fan = fans.first(where: { $0.id == fanID }) else { return false }
                guard fan.mode == setting.mode else { return false }
                switch setting.mode {
                case .automatic:
                    return true
                case .fixed:
                    return fan.targetRPM == setting.targetRPM
                case .curve:
                    return fan.linkedSensorID == setting.linkedSensorID
                        && fan.curve == setting.curve
                }
            }
        }?.name ?? "Custom"
    }

    func refresh() {
        guard !isSampling else { return }
        isSampling = true
        isRefreshing = true
        let prefs = preferences
        let probe = self.probe
        let generation = sampleGeneration
        sampleQueue.async {
            let snapshot = probe.sample(preferences: prefs)
            Task { @MainActor [weak self] in
                self?.applySnapshot(snapshot, generation: generation)
            }
        }
    }

    private func applySnapshot(_ snapshot: HardwareSnapshot, generation: UInt64) {
        // A sample that began before wake may contain stale SMC metadata. The
        // wake sample is serialized behind it and is the only generation that
        // may update the UI or trigger hardware recovery.
        guard generation == sampleGeneration else { return }
        let previousSettings = currentFanSettings()
        machine = snapshot.machine
        updateLegacyMigrationWarning()
        warnings = snapshot.warnings + appWarnings
        helperState = fanControl.persistentHelperState
        let continuousSensors = SensorContinuity.merging(
            incoming: snapshot.sensors,
            previous: sensors
        )
        sensors = mergeSensors(addIndexes(to: continuousSensors))
        updateRecentReadings()
        // Keep the last-known fan configuration if a sample momentarily returns
        // no fans (transient SMC read failure) so hand-tuned curves aren't wiped.
        if !snapshot.fans.isEmpty {
            fans = mergeFans(snapshot.fans)
        } else if fans.contains(where: { $0.source != .estimated }) {
            // Preserve configuration through a transient SMC miss, but mark the
            // missing hardware read-only until it is rediscovered.
            fans = mergeFans([])
        } else {
            fans = []
        }
        applyCurveTargets()
        recoverFansRequiringAutomaticControl()
        if !pendingWakeReapplyAttempts.isEmpty {
            reapplyActiveFansAfterWake()
        }
        autoApplyCurveTargets()
        if previousSettings != currentFanSettings() {
            save()
        }
        isRefreshing = false
        isSampling = false
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = max(1, preferences.refreshInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        // Give the kernel slack to coalesce wakeups (battery friendly), and run
        // in common mode so sampling keeps ticking during slider/scroll tracking.
        timer.tolerance = max(0.5, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func updatePreferences(_ update: (inout AppPreferences) -> Void) {
        let previous = preferences
        update(&preferences)
        if preferences.showDockIcon != previous.showDockIcon {
            applyActivationPolicy()
        }
        if preferences.refreshInterval != previous.refreshInterval {
            restartTimer()
        }
        if preferences.launchAtLogin != previous.launchAtLogin {
            applyLaunchAtLogin(preferences.launchAtLogin)
        }
        save()
    }

    func applyActivationPolicy() {
        NSApp.setActivationPolicy(preferences.showDockIcon ? .regular : .accessory)
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            addWarning("Could not update Launch at Login: \(error.localizedDescription)")
            // Reflect the real state so the toggle doesn't lie.
            preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func toggleFavorite(_ sensor: ThermalSensor) {
        guard let index = sensors.firstIndex(where: { $0.id == sensor.id }) else { return }
        sensors[index].isFavorite.toggle()
        sensorPreferences[sensor.id] = SensorPreference(
            isFavorite: sensors[index].isFavorite,
            isHidden: sensors[index].isHidden
        )
        save()
    }

    func setHidden(_ sensor: ThermalSensor, hidden: Bool) {
        guard let index = sensors.firstIndex(where: { $0.id == sensor.id }) else { return }
        sensors[index].isHidden = hidden
        sensorPreferences[sensor.id] = SensorPreference(
            isFavorite: sensors[index].isFavorite,
            isHidden: hidden
        )
        if hidden {
            preferences.menuSensorIDs.removeAll { $0 == sensor.id }
        }
        save()
    }

    func toggleMenuSensor(_ sensor: ThermalSensor) {
        updatePreferences { preferences in
            if preferences.menuSensorIDs.contains(sensor.id) {
                preferences.menuSensorIDs.removeAll { $0 == sensor.id }
            } else if preferences.menuSensorIDs.count < 3 {
                preferences.menuSensorIDs.append(sensor.id)
            }
        }
    }

    func canToggleMenuSensor(_ sensor: ThermalSensor) -> Bool {
        preferences.menuSensorIDs.contains(sensor.id) || preferences.menuSensorIDs.count < 3
    }

    func setFanMode(_ fanID: String, mode: FanMode) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[index].mode = mode
        if mode == .curve, fans[index].linkedSensorID == nil {
            fans[index].linkedSensorID = recommendedCurveSensor?.id
        }
        applyCurveTargets()
        markFanPending(fanID)
        save()
    }

    func setFanTarget(_ fanID: String, rpm: Int) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[index].targetRPM = clamp(rpm, min: fans[index].minRPM, max: fans[index].maxRPM)
        fans[index].mode = .fixed
        markFanPending(fanID)
        save()
    }

    func setLinkedSensor(_ fanID: String, sensorID: String?) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[index].linkedSensorID = sensorID
        fans[index].mode = .curve
        applyCurveTargets()
        markFanPending(fanID)
        save()
    }

    func updateCurvePoint(fanID: String, pointID: UUID, temperature: Double? = nil, rpm: Int? = nil) {
        guard let fanIndex = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[fanIndex].curve = FanCurveMath.updating(
            fans[fanIndex].curve,
            pointID: pointID,
            temperature: temperature,
            rpm: rpm,
            minRPM: fans[fanIndex].minRPM,
            maxRPM: fans[fanIndex].maxRPM
        )
        fans[fanIndex].mode = .curve
        applyCurveTargets()
        markFanPending(fanID)
        save()
    }

    func addCurvePoint(fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        let updated = FanCurveMath.addingPoint(
            to: fans[index].curve,
            minRPM: fans[index].minRPM,
            maxRPM: fans[index].maxRPM
        )
        guard updated != fans[index].curve else { return }
        fans[index].curve = updated
        fans[index].mode = .curve
        applyCurveTargets()
        markFanPending(fanID)
        save()
    }

    func canAddCurvePoint(fanID: String) -> Bool {
        guard let fan = fans.first(where: { $0.id == fanID }) else { return false }
        return fan.curve.count < FanCurveMath.maximumPointCount
    }

    func removeCurvePoint(fanID: String, pointID: UUID) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }), fans[index].curve.count > 2 else { return }
        fans[index].curve = FanCurveMath.removingPoint(
            from: fans[index].curve,
            pointID: pointID,
            minRPM: fans[index].minRPM,
            maxRPM: fans[index].maxRPM
        )
        applyCurveTargets()
        markFanPending(fanID)
        save()
    }

    func toggleDraftIndexSensor(_ sensorID: String) {
        if newIndexSensorIDs.contains(sensorID) {
            newIndexSensorIDs.remove(sensorID)
        } else {
            newIndexSensorIDs.insert(sensorID)
        }
    }

    func createCustomIndex() {
        let trimmed = newIndexName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !newIndexSensorIDs.isEmpty else { return }
        customIndexes.append(ThermalIndex(
            name: trimmed,
            mode: newIndexMode,
            sensorIDs: Array(newIndexSensorIDs).sorted()
        ))
        customIndexes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        newIndexName = ""
        newIndexSensorIDs.removeAll()
        rebuildIndexes()
        save()
    }

    func deleteCustomIndex(_ index: ThermalIndex) {
        let sensorID = Self.customIndexSensorID(for: index)
        customIndexes.removeAll { $0.id == index.id }
        preferences.menuSensorIDs.removeAll { $0 == sensorID }
        for fanIndex in fans.indices where fans[fanIndex].linkedSensorID == sensorID {
            fans[fanIndex].linkedSensorID = recommendedCurveSensor?.id
            applyCurveTargets()
            markFanPending(fans[fanIndex].id)
        }
        rebuildIndexes()
        save()
    }

    func savePreset() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = FanPreset(
            name: trimmed,
            fanSettings: currentFanSettings(),
            menuSensorIDs: preferences.menuSensorIDs
        )
        presets.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        presets.append(preset)
        presets.sort { $0.createdAt < $1.createdAt }
        newPresetName = ""
        save()
    }

    func applyPreset(_ preset: FanPreset) {
        let existingSensorIDs = Set(sensors.map(\.id))
        for index in fans.indices {
            guard let setting = preset.fanSettings[fans[index].id] else { continue }
            fans[index].mode = setting.mode
            fans[index].targetRPM = clamp(setting.targetRPM, min: fans[index].minRPM, max: fans[index].maxRPM)
            // Drop a linked sensor that no longer exists (e.g. a custom index that
            // was deleted after the preset was saved) so the curve fallback re-links
            // explicitly and the picker shows "None" instead of a dangling id.
            if let linked = setting.linkedSensorID, !existingSensorIDs.contains(linked) {
                fans[index].linkedSensorID = nil
            } else {
                fans[index].linkedSensorID = setting.linkedSensorID
            }
            fans[index].curve = FanCurveMath.normalized(
                setting.curve,
                minRPM: fans[index].minRPM,
                maxRPM: fans[index].maxRPM
            )
            markFanPending(fans[index].id)
        }
        preferences.menuSensorIDs = Array(preset.menuSensorIDs.prefix(3))
        applyCurveTargets()
        save()
        let fanIDs = fans.compactMap { preset.fanSettings[$0.id] == nil ? nil : $0.id }
        for fanID in fanIDs {
            applyFanWithAdmin(fanID)
        }
    }

    func deletePreset(_ preset: FanPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func resetFanToAutomatic(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[index].mode = .automatic
        lastAppliedRPM[fanID] = nil
        markFanPending(fanID)
        save()
        applyFanWithAdmin(fanID)
    }

    /// Registers the helper if needed, then writes the fan's staged setting to
    /// hardware. Registration and authenticated XPC work run off the main actor
    /// so macOS approval and hardware read-back never freeze the UI.
    func applyFanWithAdmin(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        guard !applyingFanIDs.contains(fanID) else { return }
        guard fans[index].source != .estimated else {
            fans[index].lastCommand = "Fan control is unavailable — no controllable fan was detected on this Mac."
            return
        }
        guard fans[index].controlInterface.isAvailable else {
            fans[index].controlState = .failed
            fans[index].lastCommand = "Monitoring only: this firmware exposes no verified fan-control interface, so no hardware write was attempted."
            return
        }

        let fan = fans[index]
        let control = fanControl
        let requiresWatchdog = fan.mode != .automatic
        let parentPID = ProcessInfo.processInfo.processIdentifier
        applyingFanIDs.insert(fanID)

        controlQueue.async {
            if !control.isPersistentHelperInstalled {
                switch control.installPersistentHelper() {
                case .applied:
                    break
                case .failed(let text), .recoveryRequired(let text):
                    Task { @MainActor [weak self] in
                        self?.finishApply(
                            appliedFan: fan,
                            message: text,
                            succeeded: false,
                            helperState: control.persistentHelperState,
                            recoveryRequired: false
                        )
                    }
                    return
                }
            }

            if requiresWatchdog {
                do {
                    // Manual control is impossible until the privileged watcher
                    // confirms that it is already observing this app's exit.
                    try control.startWatchdog(for: fan, parentPID: parentPID)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.finishApply(
                            appliedFan: fan,
                            message: "No hardware write was attempted because the crash watchdog could not be verified: \(error.localizedDescription)",
                            succeeded: false,
                            helperState: control.persistentHelperState,
                            recoveryRequired: false
                        )
                    }
                    return
                }
            }

            let message: String
            let succeeded: Bool
            let recoveryRequired: Bool
            switch control.applyWithPersistentHelper(fan) {
            case .applied(let text):
                message = text
                succeeded = true
                recoveryRequired = false
            case .failed(let text):
                message = text
                succeeded = false
                recoveryRequired = false
            case .recoveryRequired(let text):
                message = text
                succeeded = false
                recoveryRequired = true
            }

            Task { @MainActor [weak self] in
                self?.finishApply(
                    appliedFan: fan,
                    message: message,
                    succeeded: succeeded,
                    helperState: control.persistentHelperState,
                    recoveryRequired: recoveryRequired
                )
            }
        }
    }

    private func finishApply(
        appliedFan: FanDevice,
        message: String,
        succeeded: Bool,
        helperState: HardwareHelperState,
        recoveryRequired: Bool
    ) {
        let fanID = appliedFan.id
        self.helperState = helperState

        if succeeded {
            automaticRecoveryFanIDs.remove(fanID)
            automaticRecoveryAttempts[fanID] = nil
            if appliedFan.mode == .automatic {
                activeHardwareFanIDs.remove(fanID)
                pendingWakeReapplyAttempts[fanID] = nil
                lastAppliedRPM[fanID] = nil
                lastAppliedConfigurations[fanID] = nil
            } else {
                activeHardwareFanIDs.insert(fanID)
                lastAppliedConfigurations[fanID] = appliedFan
            }
        } else {
            lastAppliedRPM[fanID] = nil
            if recoveryRequired {
                activeHardwareFanIDs.insert(fanID)
                lastAppliedConfigurations[fanID] = appliedFan
                automaticRecoveryFanIDs.insert(fanID)
                automaticRecoveryAttempts[fanID] = 0
            }
        }

        if let index = fans.firstIndex(where: { $0.id == fanID }) {
            let currentMatches = sameConfiguration(fans[index], appliedFan)
            if succeeded, currentMatches {
                fans[index].controlState = appliedFan.mode == .automatic ? .idle : .active
                lastAppliedRPM[fanID] = appliedFan.mode == .automatic ? nil : appliedFan.targetRPM
                fans[index].lastCommand = message
            } else if succeeded {
                fans[index].controlState = .pending
                lastAppliedRPM[fanID] = nil
                fans[index].lastCommand = "\(message) Newer edits are still waiting to be applied."
            } else {
                fans[index].controlState = .failed
                fans[index].lastCommand = message
            }
        }
        applyingFanIDs.remove(fanID)
        save()
        if recoveryRequired {
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "The helper could not verify rollback after a failed hardware write."
            )
        }
        refresh()
    }

    /// Installs the Hardware Helper without applying a specific fan (used by the
    /// General settings pane's Install button). Runs off the main actor.
    func installHelper() {
        guard helperState != .ready, !installingHelper else { return }
        let control = fanControl
        installingHelper = true
        controlQueue.async {
            let result = control.installPersistentHelper()
            let helperState = control.persistentHelperState
            let legacyHelperRemains = control.hasLegacyPrivilegedHelper
            let message: String
            switch result {
            case .applied(let text), .failed(let text), .recoveryRequired(let text):
                message = text
            }
            Task { @MainActor [weak self] in
                self?.helperState = helperState
                self?.installingHelper = false
                self?.updateLegacyMigrationWarning(legacyHelperRemains: legacyHelperRemains)
                if helperState != .ready {
                    self?.addWarning(message)
                } else {
                    self?.appWarnings.removeAll { $0.localizedCaseInsensitiveContains("Hardware Helper") }
                }
            }
        }
    }

    func unregisterHelper() {
        guard !installingHelper else { return }
        let control = fanControl
        installingHelper = true
        controlQueue.async {
            let result = control.unregisterPersistentHelper()
            let helperState = control.persistentHelperState
            Task { @MainActor [weak self] in
                self?.helperState = helperState
                self?.installingHelper = false
                switch result {
                case .applied(let message):
                    self?.addWarning(message)
                case .failed(let message), .recoveryRequired(let message):
                    self?.addWarning(message)
                }
            }
        }
    }

    /// Re-sends curve-mode targets to hardware as the linked temperature changes,
    /// so a curve actually tracks temperature instead of freezing at the RPM
    /// written by the last manual Apply. Only active for fans the user has
    /// already applied this session (lastAppliedRPM set), to avoid surprise writes.
    private func autoApplyCurveTargets() {
        guard helperInstalled else { return }
        let control = fanControl
        for fan in fans where fan.mode == .curve && fan.source != .estimated && fan.controlInterface.isAvailable {
            guard activeHardwareFanIDs.contains(fan.id) else { continue }
            guard !applyingFanIDs.contains(fan.id) else { continue }
            guard let previous = lastAppliedRPM[fan.id] else { continue }
            guard abs(previous - fan.targetRPM) >= Self.curveHysteresisRPM else { continue }
            let snapshot = fan
            applyingFanIDs.insert(fan.id)
            controlQueue.async {
                let result = control.applyWithPersistentHelper(snapshot)
                Task { @MainActor [weak self] in
                    self?.finishAutomaticCurveApply(snapshot, result: result)
                }
            }
        }
    }

    private func finishAutomaticCurveApply(_ appliedFan: FanDevice, result: FanControlService.ApplyResult) {
        guard let index = fans.firstIndex(where: { $0.id == appliedFan.id }) else {
            applyingFanIDs.remove(appliedFan.id)
            return
        }
        switch result {
        case .applied:
            lastAppliedRPM[appliedFan.id] = appliedFan.targetRPM
            lastAppliedConfigurations[appliedFan.id] = appliedFan
            if fans[index].controlState != .pending {
                fans[index].controlState = .active
                fans[index].lastCommand = "Curve active at \(appliedFan.targetRPM) RPM."
            }
        case .failed(let message):
            lastAppliedRPM[appliedFan.id] = nil
            fans[index].controlState = .failed
            fans[index].lastCommand = message
        case .recoveryRequired(let message):
            lastAppliedRPM[appliedFan.id] = nil
            activeHardwareFanIDs.insert(appliedFan.id)
            lastAppliedConfigurations[appliedFan.id] = appliedFan
            automaticRecoveryFanIDs.insert(appliedFan.id)
            automaticRecoveryAttempts[appliedFan.id] = 0
            fans[index].controlState = .failed
            fans[index].lastCommand = message
        }
        applyingFanIDs.remove(appliedFan.id)
        if case .recoveryRequired = result {
            scheduleAutomaticRecovery(
                fanID: appliedFan.id,
                reason: "Curve control failed and automatic rollback could not be verified."
            )
        }
    }

    /// Returns every daemon-owned fan to automatic control before the app exits.
    /// The daemon also recovers on connection invalidation/process exit, so this
    /// synchronous request is the first of multiple independent safety paths.
    func restoreAutomaticControlOnQuit() {
        flushSaveSynchronously()
        guard helperState == .ready
                || helperState == .recoveryBlocked
                || !activeHardwareFanIDs.isEmpty
        else { return }
        _ = fanControl.returnAllToAutomatic()
    }

    var hasForcedFans: Bool {
        helperInstalled && !activeHardwareFanIDs.isEmpty
    }

    private func load() {
        guard let state = persistence.load() else { return }
        preferences = state.preferences
        preferences.refreshInterval = max(1, min(60, preferences.refreshInterval))
        preferences.menuSensorIDs = Array(preferences.menuSensorIDs.map(Self.migratedSensorID).prefix(3))
        presets = state.presets.map { preset in
            var migrated = preset
            migrated.menuSensorIDs = Array(preset.menuSensorIDs.map(Self.migratedSensorID).prefix(3))
            migrated.fanSettings = preset.fanSettings.mapValues { setting in
                var migratedSetting = setting
                migratedSetting.linkedSensorID = setting.linkedSensorID.map(Self.migratedSensorID)
                return migratedSetting
            }
            return migrated
        }
        sensorPreferences = state.sensorPreferences
        customIndexes = state.customIndexes.map { index in
            var migrated = index
            migrated.sensorIDs = index.sensorIDs.map(Self.migratedSensorID)
            return migrated
        }
        fans = state.fanSettings.map { fanID, setting in
            FanDevice(
                id: fanID,
                name: fanID.capitalized,
                currentRPM: setting.targetRPM,
                minRPM: 1200,
                maxRPM: 6500,
                targetRPM: setting.targetRPM,
                mode: setting.mode,
                linkedSensorID: setting.linkedSensorID.map(Self.migratedSensorID),
                curve: setting.curve,
                source: .estimated,
                lastCommand: nil,
                controlState: .pending
            )
        }
    }

    nonisolated private static func migratedSensorID(_ id: String) -> String {
        switch id {
        case "cpu-average": "index-cpu-average"
        case "gpu-average": "index-gpu-average"
        default: id
        }
    }

    /// Coalesces rapid mutations (curve/slider drags fire this at 60-120 Hz) into
    /// at most one disk write every ~0.6 s, performed off the main thread.
    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushPendingSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func flushPendingSave() {
        pendingSave = nil
        let state = snapshotState()
        let persistence = self.persistence
        persistenceQueue.async {
            persistence.save(state)
        }
    }

    func flushSaveSynchronously() {
        pendingSave?.cancel()
        pendingSave = nil
        persistence.save(snapshotState())
    }

    private func snapshotState() -> PersistedState {
        PersistedState(
            preferences: preferences,
            presets: presets,
            sensorPreferences: sensorPreferences,
            fanSettings: currentFanSettings(),
            customIndexes: customIndexes
        )
    }

    private func currentFanSettings() -> [String: FanPresetSetting] {
        Dictionary(uniqueKeysWithValues: fans.map { fan in
            (
                fan.id,
                FanPresetSetting(
                    mode: fan.mode,
                    targetRPM: fan.targetRPM,
                    linkedSensorID: fan.linkedSensorID,
                    curve: fan.curve
                )
            )
        })
    }

    private func mergeSensors(_ incoming: [ThermalSensor]) -> [ThermalSensor] {
        incoming.map { sensor in
            var merged = sensor
            if let preference = sensorPreferences[sensor.id] {
                merged.isFavorite = preference.isFavorite
                merged.isHidden = preference.isHidden
            }
            return merged
        }
    }

    private func rebuildIndexes() {
        let baseSensors = sensors.filter { $0.source != .index }
        sensors = mergeSensors(addIndexes(to: baseSensors))
        applyCurveTargets()
    }

    private func addIndexes(to baseSensors: [ThermalSensor]) -> [ThermalSensor] {
        let builtIn = builtInIndexes(from: baseSensors)
        let availableForCustom = baseSensors + builtIn
        let custom = customIndexes.compactMap { makeCustomIndexSensor($0, from: availableForCustom) }
        return baseSensors + builtIn + custom
    }

    private func builtInIndexes(from sensors: [ThermalSensor]) -> [ThermalSensor] {
        var indexes: [ThermalSensor] = []

        let cpuCoreSensors = sensors.filter { sensor in
            sensor.category == .cpu && (
                sensor.name.localizedCaseInsensitiveContains("Performance Core")
                || sensor.name.localizedCaseInsensitiveContains("Efficiency Sensor")
                || sensor.name.localizedCaseInsensitiveContains("Efficiency Core")
                || sensor.name.localizedCaseInsensitiveContains("CPU Core ")
            )
        }
        let performanceSensors = sensors.filter { sensor in
            sensor.category == .cpu && (
                sensor.name.localizedCaseInsensitiveContains("Performance Core")
                || ["Tp01", "Tp05", "Tp0D"].contains(sensor.id)
            )
        }
        let performanceFallback = sensors.filter { ["TCMz", "TCMb"].contains($0.id) }
        let performanceSensorIDs = Set(performanceSensors.map(\.id))
        let performanceIndexSensors = performanceSensors
            + performanceFallback.filter { !performanceSensorIDs.contains($0.id) }
        appendIndex(
            to: &indexes,
            id: "index-cpu-average",
            name: "CPU Average",
            category: .cpu,
            mode: .average,
            sensors: cpuCoreSensors.isEmpty ? sensors.filter { $0.category == .cpu } : cpuCoreSensors
        )

        appendIndex(
            to: &indexes,
            id: "index-gpu-average",
            name: "GPU Average",
            category: .gpu,
            mode: .average,
            sensors: sensors.filter { $0.category == .gpu && $0.name.localizedCaseInsensitiveContains("Cluster") }
        )

        appendIndex(
            to: &indexes,
            id: "index-cpu-performance",
            name: "CPU Performance Index",
            category: .cpu,
            mode: .hottest,
            sensors: performanceIndexSensors
        )

        appendIndex(
            to: &indexes,
            id: "index-cpu-efficiency",
            name: "CPU Efficiency Index",
            category: .cpu,
            mode: .hottest,
            sensors: sensors.filter { sensor in
                sensor.category == .cpu && (
                    sensor.name.localizedCaseInsensitiveContains("Efficiency Core")
                    || sensor.name.localizedCaseInsensitiveContains("Efficiency Sensor")
                    || ["Tp09", "Tp0T"].contains(sensor.id)
                )
            }
        )

        appendIndex(
            to: &indexes,
            id: "index-gpu",
            name: "GPU Index",
            category: .gpu,
            mode: .hottest,
            sensors: sensors.filter { sensor in
                sensor.category == .gpu
                    || sensor.name.localizedCaseInsensitiveContains("GPU")
            }
        )

        appendIndex(
            to: &indexes,
            id: "index-system-hotspot",
            name: "System Hotspot Index",
            category: .index,
            mode: .hottest,
            sensors: sensors.filter {
                [.cpu, .gpu, .power].contains($0.category) && $0.source != .estimated
            }
        )

        return indexes
    }

    private func makeCustomIndexSensor(_ index: ThermalIndex, from sensors: [ThermalSensor]) -> ThermalSensor? {
        let lookup = Dictionary(uniqueKeysWithValues: sensors.map { ($0.id, $0) })
        let members = index.sensorIDs.compactMap { lookup[$0] }
        return makeIndexSensor(
            id: Self.customIndexSensorID(for: index),
            name: index.name,
            category: .index,
            mode: index.mode,
            sensors: members,
            isFavorite: false
        )
    }

    private func appendIndex(
        to indexes: inout [ThermalSensor],
        id: String,
        name: String,
        category: SensorCategory,
        mode: ThermalIndexMode,
        sensors: [ThermalSensor]
    ) {
        guard let sensor = makeIndexSensor(
            id: id,
            name: name,
            category: category,
            mode: mode,
            sensors: sensors,
            isFavorite: id == "index-system-hotspot" || id == "index-cpu-average"
        ) else {
            return
        }
        indexes.append(sensor)
    }

    private func makeIndexSensor(
        id: String,
        name: String,
        category: SensorCategory,
        mode: ThermalIndexMode,
        sensors: [ThermalSensor],
        isFavorite: Bool
    ) -> ThermalSensor? {
        let freshSensors = sensors.filter { isSensorFresh($0) }
        let contributors = freshSensors.isEmpty ? sensors : freshSensors
        let values = contributors.map(\.temperatureC).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        let value: Double
        switch mode {
        case .hottest:
            value = values.max() ?? 0
        case .average:
            value = values.reduce(0, +) / Double(values.count)
        }

        return ThermalSensor(
            id: id,
            name: name,
            category: category,
            temperatureC: value,
            source: .index,
            isFavorite: isFavorite,
            isHidden: false,
            updatedAt: contributors.map(\.updatedAt).max() ?? Date()
        )
    }

    private static func customIndexSensorID(for index: ThermalIndex) -> String {
        "index-custom-\(index.id.uuidString)"
    }

    private func mergeFans(_ incoming: [FanDevice]) -> [FanDevice] {
        let existing = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0) })
        var mergedFans = incoming.map { fan in
            guard let saved = existing[fan.id] else {
                var discovered = fan
                discovered.curve = FanCurveMath.normalized(
                    fan.curve,
                    minRPM: fan.minRPM,
                    maxRPM: fan.maxRPM
                )
                if fan.hardwareMode != .automatic {
                    discovered.controlState = .pending
                    discovered.lastCommand = "Hardware reports manual fan control. Choose Auto or review the target, then apply."
                }
                return discovered
            }
            var merged = fan
            merged.mode = saved.mode
            merged.targetRPM = clamp(saved.targetRPM, min: fan.minRPM, max: fan.maxRPM)
            merged.linkedSensorID = saved.linkedSensorID
            merged.curve = FanCurveMath.normalized(
                saved.curve.isEmpty ? fan.curve : saved.curve,
                minRPM: fan.minRPM,
                maxRPM: fan.maxRPM
            )
            merged.lastCommand = saved.lastCommand
            merged.controlState = saved.controlState

            if !fan.controlInterface.isAvailable && activeHardwareFanIDs.contains(fan.id) {
                merged.controlState = .failed
                merged.lastCommand = "The verified control interface disappeared. ThermoFan is returning this fan to automatic control; manual writes are disabled."
            }

            if saved.source == .estimated {
                if saved.mode == .automatic, fan.hardwareMode == .automatic {
                    merged.controlState = .idle
                    merged.lastCommand = nil
                } else {
                    merged.controlState = .pending
                    if saved.mode == .automatic {
                        merged.lastCommand = "Hardware is in manual mode. Apply Auto to return control to macOS."
                    } else {
                        merged.lastCommand = "Saved \(saved.mode.title) settings are not active yet. Review them, then apply."
                    }
                }
            }
            return merged
        }

        let incomingIDs = Set(incoming.map(\.id))
        for missing in fans where missing.source != .estimated && !incomingIDs.contains(missing.id) {
            var stale = missing
            stale.controlInterface = .unavailable
            stale.hardwareMode = nil
            stale.controlState = .failed
            stale.lastCommand = "Fan telemetry is temporarily unavailable. Last reading is shown; hardware writes are disabled."
            mergedFans.append(stale)
        }
        return mergedFans.sorted { $0.id < $1.id }
    }

    private func applyCurveTargets() {
        for index in fans.indices where fans[index].mode == .curve {
            let linkedSensor = fans[index].linkedSensorID.flatMap { linkedSensorID in
                sensors.first(where: { $0.id == linkedSensorID })
            }
            let currentLinkedSensor = linkedSensor.flatMap { sensor in
                isSensorFresh(sensor) ? sensor : nil
            }
            guard let sensor = currentLinkedSensor ?? recommendedCurveSensor else {
                continue
            }
            let sourceWasMissing = fans[index].linkedSensorID != nil && linkedSensor == nil
            if fans[index].linkedSensorID == nil || sourceWasMissing {
                fans[index].linkedSensorID = sensor.id
            }
            fans[index].curve = FanCurveMath.normalized(
                fans[index].curve,
                minRPM: fans[index].minRPM,
                maxRPM: fans[index].maxRPM
            )
            fans[index].targetRPM = FanCurveMath.interpolatedRPM(
                temperature: sensor.temperatureC,
                points: fans[index].curve,
                minRPM: fans[index].minRPM,
                maxRPM: fans[index].maxRPM,
                fallback: fans[index].targetRPM
            )
            if sourceWasMissing {
                let fanID = fans[index].id
                markFanPending(fanID)
                fans[index].lastCommand = "The previous curve source is unavailable. Switched to \(sensor.name); review and apply."
            }
        }
    }

    private var recommendedCurveSensor: ThermalSensor? {
        sensors.first { $0.id == "index-system-hotspot" && !$0.isHidden && isSensorFresh($0) }
            ?? sensors.first { $0.id == "TCMz" && !$0.isHidden && isSensorFresh($0) }
            ?? unhiddenSensors
                .filter { [.cpu, .gpu, .power].contains($0.category) && isSensorFresh($0) }
                .max { $0.temperatureC < $1.temperatureC }
    }

    private func markFanPending(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        // A newly-staged change disarms the curve control loop until the user
        // applies again, so it never writes a configuration they haven't confirmed.
        // (Automatic curve retargeting goes through applyCurveTargets, which does
        // not call this, so an already-applied curve keeps tracking.)
        lastAppliedRPM[fanID] = nil
        fans[index].controlState = .pending
        switch fans[index].mode {
        case .automatic:
            fans[index].lastCommand = "Pending: click Apply to Hardware to return this fan to automatic control."
        case .fixed:
            fans[index].lastCommand = "Pending: click Apply to Hardware to set \(fans[index].targetRPM) RPM."
        case .curve:
            fans[index].lastCommand = "Pending: curve target is \(fans[index].targetRPM) RPM. Click Apply to Hardware."
        }
    }

    private func sameConfiguration(_ lhs: FanDevice, _ rhs: FanDevice) -> Bool {
        guard lhs.mode == rhs.mode else { return false }
        switch lhs.mode {
        case .automatic:
            return true
        case .fixed:
            return lhs.targetRPM == rhs.targetRPM
        case .curve:
            return lhs.targetRPM == rhs.targetRPM
                && lhs.linkedSensorID == rhs.linkedSensorID
                && lhs.curve == rhs.curve
        }
    }

    private func handleWake() {
        sampleGeneration &+= 1
        pendingWakeReapplyAttempts = Dictionary(
            uniqueKeysWithValues: activeHardwareFanIDs.map { ($0, 0) }
        )
        let requiresSafetyReset = !pendingWakeReapplyAttempts.isEmpty
        wakeSafetyResetPending = requiresSafetyReset
        if requiresSafetyReset {
            let control = fanControl
            controlQueue.async {
                let result = control.returnAllToAutomatic()
                Task { @MainActor [weak self] in
                    self?.finishWakeSafetyReset(
                        result,
                        helperState: control.persistentHelperState
                    )
                }
            }
        }
        restartTimer()
        isSampling = true
        isRefreshing = true
        let prefs = preferences
        let probe = self.probe
        let generation = sampleGeneration
        sampleQueue.async {
            // This runs after any pre-wake sample already on the serial queue,
            // so cache invalidation cannot race a dictionary read or SMC call.
            probe.prepareAfterWake()
            let snapshot = probe.sample(preferences: prefs)
            Task { @MainActor [weak self] in
                self?.applySnapshot(snapshot, generation: generation)
            }
        }
    }

    private func finishWakeSafetyReset(
        _ result: FanControlService.ApplyResult,
        helperState: HardwareHelperState
    ) {
        self.helperState = helperState
        wakeSafetyResetPending = false
        switch result {
        case .applied:
            // Re-arm only after the post-wake topology sample has completed.
            if !isSampling {
                reapplyActiveFansAfterWake()
            }
        case .failed(let message), .recoveryRequired(let message):
            let affectedFanIDs = Array(pendingWakeReapplyAttempts.keys)
            pendingWakeReapplyAttempts.removeAll()
            addWarning("Post-wake automatic recovery was not verified: \(message)")
            for fanID in affectedFanIDs {
                automaticRecoveryFanIDs.insert(fanID)
                automaticRecoveryAttempts[fanID] = 0
                scheduleAutomaticRecovery(
                    fanID: fanID,
                    reason: "Post-wake automatic recovery must succeed before manual control can resume."
                )
            }
        }
    }

    private func reapplyActiveFansAfterWake() {
        guard !wakeSafetyResetPending else { return }
        guard helperInstalled else {
            addWarning("Fan settings are waiting after wake because the verified Hardware Helper is unavailable.")
            return
        }
        let control = fanControl
        for fanID in pendingWakeReapplyAttempts.keys.sorted() where !applyingFanIDs.contains(fanID) {
            guard activeHardwareFanIDs.contains(fanID) else {
                pendingWakeReapplyAttempts[fanID] = nil
                continue
            }
            let attempts = pendingWakeReapplyAttempts[fanID] ?? 0
            if attempts >= Self.maximumWakeReapplyAttempts {
                scheduleAutomaticRecovery(
                    fanID: fanID,
                    reason: "Wake restore reached its retry limit."
                )
                continue
            }
            guard let current = fans.first(where: { $0.id == fanID }) else { continue }
            guard current.controlInterface.isAvailable else {
                pendingWakeReapplyAttempts[fanID] = attempts + 1
                if let index = fans.firstIndex(where: { $0.id == fanID }) {
                    fans[index].controlState = .failed
                    fans[index].lastCommand = "Wake restore is waiting for the fan-control interface to be re-verified."
                }
                continue
            }
            var applied = current.controlState == .active ? current : lastAppliedConfigurations[fanID]
            applied?.controlInterface = current.controlInterface
            guard let applied else { continue }
            let nextAttempt = attempts + 1
            let maximumAttempts = Self.maximumWakeReapplyAttempts
            applyingFanIDs.insert(fanID)
            controlQueue.async {
                let result: FanControlService.ApplyResult
                if applied.mode == .automatic {
                    result = control.applyWithPersistentHelper(applied)
                } else {
                    do {
                        try control.startWatchdog(
                            for: applied,
                            parentPID: ProcessInfo.processInfo.processIdentifier
                        )
                        result = control.applyWithPersistentHelper(applied)
                    } catch {
                        result = .failed(
                            "Wake restore was blocked because a fresh crash-watchdog lease could not be armed: \(error.localizedDescription)"
                        )
                    }
                }
                var recoveryResult: FanControlService.ApplyResult?
                let shouldRecoverAutomatically: Bool
                switch result {
                case .recoveryRequired:
                    shouldRecoverAutomatically = true
                case .failed:
                    shouldRecoverAutomatically = nextAttempt >= maximumAttempts
                case .applied:
                    shouldRecoverAutomatically = false
                }
                if shouldRecoverAutomatically {
                    var reset = applied
                    reset.mode = .automatic
                    recoveryResult = control.applyWithPersistentHelper(reset)
                }
                Task { @MainActor [weak self] in
                    self?.finishWakeReapply(
                        appliedFan: applied,
                        result: result,
                        attempt: nextAttempt,
                        recoveryResult: recoveryResult,
                        helperState: control.persistentHelperState
                    )
                }
            }
        }
    }

    private func finishWakeReapply(
        appliedFan: FanDevice,
        result: FanControlService.ApplyResult,
        attempt: Int,
        recoveryResult: FanControlService.ApplyResult?,
        helperState: HardwareHelperState
    ) {
        let fanID = appliedFan.id
        self.helperState = helperState
        applyingFanIDs.remove(fanID)

        switch result {
        case .applied:
            pendingWakeReapplyAttempts[fanID] = nil
            automaticRecoveryFanIDs.remove(fanID)
            automaticRecoveryAttempts[fanID] = nil
            activeHardwareFanIDs.insert(fanID)
            lastAppliedConfigurations[fanID] = appliedFan
            lastAppliedRPM[fanID] = appliedFan.targetRPM
            if let index = fans.firstIndex(where: { $0.id == fanID }) {
                if sameConfiguration(fans[index], appliedFan) {
                    fans[index].controlState = .active
                    fans[index].lastCommand = "Fan settings restored after wake."
                } else {
                    fans[index].controlState = .pending
                    fans[index].lastCommand = "Fan settings restored after wake. Newer edits are still pending."
                }
            }

        case .failed(let message):
            finishWakeReapplyFailure(
                appliedFan: appliedFan,
                message: message,
                attempt: attempt,
                recoveryResult: recoveryResult,
                recoveryWasRequired: false
            )
        case .recoveryRequired(let message):
            finishWakeReapplyFailure(
                appliedFan: appliedFan,
                message: message,
                attempt: attempt,
                recoveryResult: recoveryResult,
                recoveryWasRequired: true
            )
        }
        save()
    }

    private func finishWakeReapplyFailure(
        appliedFan: FanDevice,
        message: String,
        attempt: Int,
        recoveryResult: FanControlService.ApplyResult?,
        recoveryWasRequired: Bool
    ) {
        let fanID = appliedFan.id
        lastAppliedRPM[fanID] = nil

        if let recoveryResult {
            switch recoveryResult {
            case .applied:
                pendingWakeReapplyAttempts[fanID] = nil
                automaticRecoveryFanIDs.remove(fanID)
                automaticRecoveryAttempts[fanID] = nil
                activeHardwareFanIDs.remove(fanID)
                lastAppliedConfigurations[fanID] = nil
                if let index = fans.firstIndex(where: { $0.id == fanID }) {
                    fans[index].controlState = .pending
                    fans[index].lastCommand = "Wake restore failed after \(attempt) attempt(s), so the fan was verified back in automatic control. Review and apply again if needed."
                }
            case .failed(let recoveryMessage), .recoveryRequired(let recoveryMessage):
                pendingWakeReapplyAttempts[fanID] = nil
                automaticRecoveryFanIDs.insert(fanID)
                automaticRecoveryAttempts[fanID] = 0
                if let index = fans.firstIndex(where: { $0.id == fanID }) {
                    fans[index].controlState = .failed
                    fans[index].lastCommand = "Wake restore failed: \(message) Automatic recovery also failed: \(recoveryMessage) The daemon recovery supervisor remains active with backoff retries."
                }
                addWarning("Automatic fan recovery after wake failed and will be retried.")
                scheduleAutomaticRecovery(
                    fanID: fanID,
                    reason: "Wake restore and its immediate automatic rollback both failed."
                )
            }
            return
        }

        if recoveryWasRequired {
            pendingWakeReapplyAttempts[fanID] = nil
            automaticRecoveryFanIDs.insert(fanID)
            automaticRecoveryAttempts[fanID] = 0
            if let index = fans.firstIndex(where: { $0.id == fanID }) {
                fans[index].controlState = .failed
                fans[index].lastCommand = "Wake restore could not verify automatic rollback: \(message)"
            }
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "Wake restore could not verify automatic rollback."
            )
        } else {
            pendingWakeReapplyAttempts[fanID] = attempt
            if let index = fans.firstIndex(where: { $0.id == fanID }) {
                fans[index].controlState = .failed
                fans[index].lastCommand = "Wake restore attempt \(attempt) failed: \(message)"
            }
        }
    }

    /// A fan that was actively controlled must never keep a stale manual target
    /// after its write interface disappears. The helper independently re-probes
    /// the firmware and verifies Auto/System mode; failures remain retryable.
    private func recoverFansRequiringAutomaticControl() {
        for fanID in activeHardwareFanIDs.sorted() {
            guard
                let fan = fans.first(where: { $0.id == fanID }),
                !fan.controlInterface.isAvailable
            else {
                continue
            }
            automaticRecoveryFanIDs.insert(fanID)
            if automaticRecoveryAttempts[fanID] == nil {
                automaticRecoveryAttempts[fanID] = 0
            }
        }

        for fanID in automaticRecoveryFanIDs.sorted() {
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "Automatic control is required because the previous hardware state could not be verified."
            )
        }
    }

    private func scheduleAutomaticRecovery(fanID: String, reason: String) {
        guard !applyingFanIDs.contains(fanID) else { return }
        guard helperState == .ready || helperState == .recoveryBlocked else {
            addWarning("\(reason) Automatic recovery is waiting for the authenticated Hardware Helper.")
            return
        }
        guard lastAppliedConfigurations[fanID] != nil
                || fans.contains(where: { $0.id == fanID })
        else {
            addWarning("\(reason) The last fan configuration is unavailable for automatic recovery.")
            return
        }

        automaticRecoveryFanIDs.insert(fanID)
        pendingWakeReapplyAttempts[fanID] = nil
        let attempts = automaticRecoveryAttempts[fanID] ?? 0
        guard attempts < Self.maximumAutomaticRecoveryAttempts else {
            if let index = fans.firstIndex(where: { $0.id == fanID }) {
                fans[index].controlState = .failed
                fans[index].lastCommand = "The UI recovery retry limit was reached. The root daemon's recovery supervisor remains active; keep the Mac awake and retry recovery before manual control."
            }
            addWarning("Automatic fan recovery reached its UI retry limit; the daemon recovery supervisor remains active.")
            return
        }
        automaticRecoveryAttempts[fanID] = attempts + 1

        let control = fanControl
        applyingFanIDs.insert(fanID)
        controlQueue.async {
            let result = control.returnAllToAutomatic()
            Task { @MainActor [weak self] in
                self?.finishAutomaticRecovery(
                    fanID: fanID,
                    reason: reason,
                    result: result,
                    helperState: control.persistentHelperState
                )
            }
        }
    }

    private func finishAutomaticRecovery(
        fanID: String,
        reason: String,
        result: FanControlService.ApplyResult,
        helperState: HardwareHelperState
    ) {
        self.helperState = helperState
        applyingFanIDs.remove(fanID)
        lastAppliedRPM[fanID] = nil
        if case .applied = result {
            activeHardwareFanIDs.remove(fanID)
            pendingWakeReapplyAttempts[fanID] = nil
            lastAppliedConfigurations[fanID] = nil
            automaticRecoveryFanIDs.remove(fanID)
            automaticRecoveryAttempts[fanID] = nil
        }
        if let index = fans.firstIndex(where: { $0.id == fanID }) {
            switch result {
            case .applied:
                fans[index].controlState = .pending
                fans[index].lastCommand = "\(reason) The fan was verified back in automatic control. Review before applying manual control again."
            case .failed(let message):
                fans[index].controlState = .failed
                fans[index].lastCommand = "\(reason) Automatic recovery failed: \(message) The daemon recovery supervisor remains active and will retry."
                addWarning("Automatic recovery for \(fans[index].name) failed and will be retried.")
            case .recoveryRequired(let message):
                fans[index].controlState = .failed
                fans[index].lastCommand = "\(reason) Automatic recovery could not be verified: \(message) The daemon recovery supervisor remains active and will retry."
                addWarning("Automatic recovery for \(fans[index].name) could not be verified and will be retried.")
            }
        }
        save()
    }

    private func addWarning(_ message: String) {
        guard !appWarnings.contains(message) else { return }
        appWarnings.append(message)
        warnings = warnings.filter { !appWarnings.contains($0) } + appWarnings
    }

    private func updateLegacyMigrationWarning(legacyHelperRemains: Bool? = nil) {
        let remains = legacyHelperRemains ?? fanControl.hasLegacyPrivilegedHelper
        if remains {
            guard !appWarnings.contains(Self.legacyMigrationWarning) else { return }
            appWarnings.append(Self.legacyMigrationWarning)
        } else {
            appWarnings.removeAll { $0 == Self.legacyMigrationWarning }
        }
    }

    private func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
        Swift.max(minimum, Swift.min(maximum, value))
    }

    // MARK: - Median smoothing for menu bar

    /// Appends the current temperature of every sensor to the ring buffer.
    private func updateRecentReadings() {
        let activeSensorIDs = Set(sensors.map(\.id))
        recentReadings = recentReadings.filter { activeSensorIDs.contains($0.key) }
        for sensor in sensors {
            recentReadings[sensor.id] = TemperatureSmoothing.appending(
                sensor.temperatureC,
                to: recentReadings[sensor.id] ?? [],
                maximumCount: Self.medianWindowSize
            )
        }
    }

    /// Returns the median of the last few readings for a sensor, falling back
    /// to the raw value when no history is available yet.
    private func smoothedTemperature(_ sensor: ThermalSensor) -> Double {
        TemperatureSmoothing.median(
            recentReadings[sensor.id] ?? [],
            fallback: sensor.temperatureC
        )
    }
}

enum TemperatureSmoothing {
    static func appending(_ reading: Double, to history: [Double], maximumCount: Int) -> [Double] {
        guard maximumCount > 0 else { return [] }
        return Array((history + [reading]).suffix(maximumCount))
    }

    static func median(_ readings: [Double], fallback: Double) -> Double {
        guard !readings.isEmpty else { return fallback }
        let sorted = readings.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
