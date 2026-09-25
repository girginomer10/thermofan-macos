import AppKit
import Combine
import Foundation
import ServiceManagement

/// Bridges the SwiftUI-owned store to the AppKit delegate, which needs it at
/// launch (Dock-icon policy, `--open-settings`) and at quit (return fans to
/// auto). SwiftUI creates the store lazily, possibly after launch finished, so
/// launch work that needs it registers with `whenStoreAvailable`.
@MainActor
enum AppStoreBridge {
    weak static var store: ThermalStore? {
        didSet {
            guard let store, !pendingActions.isEmpty else { return }
            let actions = pendingActions
            pendingActions.removeAll()
            for action in actions {
                action(store)
            }
        }
    }

    private static var pendingActions: [(ThermalStore) -> Void] = []

    /// Runs `action` now if the store exists, otherwise as soon as it is created.
    static func whenStoreAvailable(_ action: @escaping (ThermalStore) -> Void) {
        if let store {
            action(store)
        } else {
            pendingActions.append(action)
        }
    }
}

/// A curve exactly as it was last verified on hardware. Automatic retargeting
/// always evaluates this, never the staged (possibly unapplied) curve in `fans`.
struct AppliedCurve: Hashable {
    var points: [FanCurvePoint]
    /// `nil` means "Hottest sensor", re-evaluated on every tick.
    var linkedSensorID: String?
    var minRPM: Int
    var maxRPM: Int

    init(points: [FanCurvePoint], linkedSensorID: String?, minRPM: Int, maxRPM: Int) {
        self.points = points
        self.linkedSensorID = linkedSensorID
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }

    init(fan: FanDevice) {
        self.init(
            points: FanCurveMath.normalized(fan.curve, minRPM: fan.minRPM, maxRPM: fan.maxRPM),
            linkedSensorID: fan.linkedSensorID,
            minRPM: fan.minRPM,
            maxRPM: fan.maxRPM
        )
    }
}

/// Identifies an app-generated warning so the matching success can replace or
/// clear it instead of warnings accumulating for the rest of the session.
enum AppWarningKey: Hashable {
    case legacyMigration
    case helperSetup
    case helperUnregister
    case recoveryRetry
    case launchAtLogin
    case wakeRestore
    case recoveryWaitingForHelper
    case automaticRecovery(fanID: String)
    case recoveryLimit(fanID: String)
    case leaseLost(fanID: String)
    case curveSource(fanID: String)
    case curveWrite(fanID: String)
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
    @Published private(set) var helperState: HardwareHelperState = .missing
    /// Fans with a user-visible hardware operation in flight (apply, wake
    /// restore, recovery, release). Background curve retargeting is not listed.
    @Published var applyingFanIDs: Set<String> = []
    /// True while a helper install, unregister, or recovery retry is running.
    @Published var installingHelper = false
    /// Fans whose APPLIED curve is actively retargeting the hardware from live
    /// temperature, including while newer staged edits are still pending.
    @Published private(set) var trackedCurveFanIDs: Set<String> = []

    private let persistence = PersistenceController()
    private let probe = HardwareProbe()
    private let fanControl = FanControlService()
    private let sampleQueue = DispatchQueue(label: "io.thermofan.sample", qos: .utility)
    /// Every XPC call runs here, never on the main actor: the lease heartbeat
    /// is routed through the main queue, so a blocked main actor loses leases.
    private let controlQueue = DispatchQueue(label: "io.thermofan.control", qos: .userInitiated)
    private let persistenceQueue = DispatchQueue(label: "io.thermofan.persistence", qos: .background)
    private var sensorPreferences: [String: SensorPreference] = [:]
    private var timer: Timer?
    private var isSampling = false
    private var sampleGeneration: UInt64 = 0
    private var pendingSave: DispatchWorkItem?
    private var saveSequence: UInt64 = 0
    private var wakeCancellable: AnyCancellable?
    private var helperRefreshInFlight = false

    // MARK: Hardware lease bookkeeping (main actor only)

    /// Fans for which this app may hold a manual lease: a verified manual
    /// write, or an uncertain one that is awaiting automatic recovery.
    private var activeHardwareFanIDs: Set<String> = [] {
        didSet { updateLeaseActivity() }
    }
    private var automaticRecoveryFanIDs: Set<String> = []
    private var automaticRecoveryAttempts: [String: Int] = [:]
    private var automaticRecoveryReasons: [String: String] = [:]
    private var automaticRecoveryInFlight = false
    private var recoveryRetryInFlight = false
    /// Fans to restore after wake, with the number of attempts so far. After
    /// the post-wake safety reset they are in Auto and hold no lease.
    private var pendingWakeReapplyAttempts: [String: Int] = [:]
    private var wakeSafetyResetsInFlight = 0
    /// Last configuration verified on hardware per fan (manual modes only).
    private var lastAppliedConfigurations: [String: FanDevice] = [:]
    /// The applied curve per fan; present only while that curve may retarget.
    private var appliedCurveConfigs: [String: AppliedCurve] = [:]
    /// Last RPM actually written per fan, used for the curve hysteresis.
    private var lastAppliedRPM: [String: Int] = [:]
    private var curveWriteInFlightFanIDs: Set<String> = []
    private var curveWriteFailures: [String: Int] = [:]
    private var curveSourceLoss: [String: CurveSourceLoss] = [:]
    private var curveFallbackFanIDs: Set<String> = []
    private var automaticReadbackCounts: [String: Int] = [:]
    /// App-initiated all-fan releases in flight (wake reset, recovery, retry,
    /// unregister). Lease-loss callbacks that arrive meanwhile describe leases
    /// that operation released; its own result reconciles the affected fans.
    private var expectedReleaseDepth = 0
    private var queuedPresetApplies: [String: FanDevice] = [:]
    private var leaseActivity: NSObjectProtocol?

    private var hardwareWarnings: [String] = []
    private var appWarnings: [AppWarningKey: String] = [:]
    private var appWarningOrder: [AppWarningKey] = []

    /// Ring buffer of recent temperature readings per sensor (max 3). Its
    /// median drives both the menu bar and curve evaluation, so a transient SMC
    /// spike neither flashes in the status bar nor jolts a fan.
    private var recentReadings: [String: [Double]] = [:]
    private static let medianWindowSize = 3
    private static let curveHysteresisRPM = 100
    private static let maximumWakeReapplyAttempts = 3
    private static let maximumAutomaticRecoveryAttempts = 3
    private static let maximumCurveWriteFailures = 3
    private static let curveSourceLossTicks = 3
    private static let curveSourceLossSeconds: TimeInterval = 10
    private static let automaticReadbacksBeforeReconcile = 2
    private static let postWakeSampleDelay: TimeInterval = 2
    private static let quitRecoveryTimeout: TimeInterval = 10
    private static let legacyMigrationWarning = "Security upgrade required: an older privileged ThermoFan helper is still installed. Approve the authenticated Hardware Helper migration to revoke and remove it before using fan control."

    private struct CurveSourceLoss {
        var ticks: Int
        var since: Date
    }

    var helperInstalled: Bool {
        helperState == .ready
    }

    private var wakeSafetyResetPending: Bool {
        wakeSafetyResetsInFlight > 0
    }

    func isSensorFresh(_ sensor: ThermalSensor, now: Date = Date()) -> Bool {
        SensorContinuity.isFresh(
            sensor,
            now: now,
            refreshInterval: preferences.refreshInterval
        )
    }

    private func isUsableForControl(_ sensor: ThermalSensor, now: Date = Date()) -> Bool {
        SensorContinuity.isUsableForControl(
            sensor,
            now: now,
            refreshInterval: preferences.refreshInterval
        )
    }

    init() {
        load()
        // Never block the main actor on the helper: seed from the cache and
        // refresh on the control queue.
        helperState = fanControl.cachedHelperState
        preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        fanControl.onLeaseLost = { [weak self] fanIDs, reason in
            guard let self else { return }
            Task { @MainActor in
                self.handleLeaseLost(fanIDs: fanIDs, reason: reason)
            }
        }
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
            updateLegacyMigrationWarning(legacyHelperRemains: true)
            installHelper()
        }
        scheduleHelperStateRefresh()
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
            let lookup = Dictionary(sensors.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Sensors a curve may link to. Estimated readings are never offered: they
    /// are placeholders, not measurements, and must never drive a fan write.
    var curveSourceSensors: [ThermalSensor] {
        sensors.filter { !$0.isHidden && $0.source != .estimated }.sorted {
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
            .filter { !$0.isHidden && $0.source != .estimated && !$0.id.hasPrefix("index-custom-") }
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
        let previousSettings = fanSettingsForChangeDetection()
        machine = snapshot.machine
        hardwareWarnings = snapshot.warnings
        // Non-blocking cached read; the blocking check runs on the control queue.
        updateHelperState(fanControl.cachedHelperState)
        scheduleHelperStateRefresh()
        let continuousSensors = SensorContinuity.merging(
            incoming: snapshot.sensors,
            previous: sensors
        )
        sensors = mergeSensors(addIndexes(to: continuousSensors))
        updateRecentReadings()
        // Always merge, even when the sample has no fans: vanished real fans
        // stay visible read-only, and saved placeholders are never dropped
        // because one sample lacked them.
        fans = mergeFans(snapshot.fans)
        reconcileHardwareReportedAutomatic()
        applyCurveTargets()
        recoverFansRequiringAutomaticControl()
        if !pendingWakeReapplyAttempts.isEmpty {
            reapplyActiveFansAfterWake()
        }
        autoApplyCurveTargets()
        updateTrackedCurveFanIDs()
        publishWarnings()
        if previousSettings != fanSettingsForChangeDetection() {
            save()
        }
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
            clearWarning(.launchAtLogin)
        } catch {
            setWarning(.launchAtLogin, "Could not update Launch at Login: \(error.localizedDescription)")
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
        // A nil linked sensor means "Hottest sensor" and is re-evaluated on
        // every tick; it is never pinned to whichever sensor is hottest now.
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
        var affectedCurveFanIDs: [String] = []
        for fanIndex in fans.indices where fans[fanIndex].linkedSensorID == sensorID {
            // Fall back to "Hottest sensor"; only a curve's staged configuration
            // actually changes, so only curve-mode fans become pending.
            fans[fanIndex].linkedSensorID = nil
            if fans[fanIndex].mode == .curve {
                affectedCurveFanIDs.append(fans[fanIndex].id)
            }
        }
        rebuildIndexes()
        for fanID in affectedCurveFanIDs {
            markFanPending(fanID)
        }
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
            // Drop a linked sensor that no longer exists (e.g. a custom index that
            // was deleted after the preset was saved) so the curve follows the
            // hottest sensor and the picker does not show a dangling id.
            if let linked = setting.linkedSensorID, !existingSensorIDs.contains(linked) {
                fans[index].linkedSensorID = nil
            } else {
                fans[index].linkedSensorID = setting.linkedSensorID
            }
            if fans[index].source == .estimated {
                // A placeholder's RPM range is a guess; keep the preset values
                // verbatim until the real fan's range normalizes them.
                fans[index].targetRPM = setting.targetRPM
                fans[index].curve = setting.curve
            } else {
                fans[index].targetRPM = clamp(setting.targetRPM, min: fans[index].minRPM, max: fans[index].maxRPM)
                fans[index].curve = FanCurveMath.normalized(
                    setting.curve,
                    minRPM: fans[index].minRPM,
                    maxRPM: fans[index].maxRPM
                )
            }
            markFanPending(fans[index].id)
        }
        preferences.menuSensorIDs = Array(preset.menuSensorIDs.prefix(3))
        applyCurveTargets()
        save()
        let fanIDs = fans.compactMap { preset.fanSettings[$0.id] == nil ? nil : $0.id }
        for fanID in fanIDs {
            guard let index = fans.firstIndex(where: { $0.id == fanID }) else { continue }
            if applyingFanIDs.contains(fanID) {
                // Never skip silently: apply once the in-flight operation ends,
                // provided the staged settings are still the preset's.
                queuedPresetApplies[fanID] = fans[index]
                fans[index].lastCommand = "Preset \"\(preset.name)\" is queued and will be applied when the current hardware operation finishes."
            } else {
                queuedPresetApplies[fanID] = nil
                applyFanWithAdmin(fanID)
            }
        }
    }

    func deletePreset(_ preset: FanPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func resetFanToAutomatic(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        fans[index].mode = .automatic
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

        switch helperState {
        case .recoveryBlocked:
            // Manual writes are refused until Auto is verified. Retrying the
            // daemon's verified recovery is also what an Auto request needs.
            fans[index].lastCommand = fans[index].mode == .automatic
                ? "Hardware recovery is blocked, so ThermoFan is retrying verified automatic recovery instead."
                : "Manual control is blocked until automatic recovery is verified. Retrying verified automatic recovery now; apply again after it succeeds."
            retryAutomaticRecovery()
            return
        case .monitoringOnly, .wrongLocation, .inactiveSession:
            fans[index].lastCommand = Self.unavailableControlMessage(for: helperState)
            return
        case .unreachable:
            fans[index].lastCommand = "The Hardware Helper is not responding, so no hardware write was attempted. Checking it again; its own automatic recovery stays in charge meanwhile."
            refreshHelperState()
            return
        case .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired, .ready:
            break
        }

        let fan = fans[index]
        let control = fanControl
        let requiresWatchdog = fan.mode != .automatic
        let parentPID = ProcessInfo.processInfo.processIdentifier
        applyingFanIDs.insert(fanID)
        updateTrackedCurveFanIDs()

        controlQueue.async {
            if !control.isPersistentHelperInstalled {
                let installFailure: (message: String, recoveryRequired: Bool)?
                switch control.installPersistentHelper() {
                case .applied:
                    installFailure = nil
                case .failed(let text):
                    installFailure = (text, false)
                case .recoveryRequired(let text):
                    installFailure = (text, true)
                }
                if let installFailure {
                    let helperState = control.persistentHelperState
                    Task { @MainActor [weak self] in
                        self?.finishApply(
                            appliedFan: fan,
                            message: installFailure.message,
                            succeeded: false,
                            helperState: helperState,
                            recoveryRequired: installFailure.recoveryRequired,
                            writeAttempted: false
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
                    let message = "No hardware write was attempted because the crash watchdog could not be verified: \(error.localizedDescription)"
                    let helperState = control.persistentHelperState
                    Task { @MainActor [weak self] in
                        self?.finishApply(
                            appliedFan: fan,
                            message: message,
                            succeeded: false,
                            helperState: helperState,
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
            let helperState = control.persistentHelperState

            Task { @MainActor [weak self] in
                self?.finishApply(
                    appliedFan: fan,
                    message: message,
                    succeeded: succeeded,
                    helperState: helperState,
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
        recoveryRequired: Bool,
        writeAttempted: Bool = true
    ) {
        let fanID = appliedFan.id
        applyingFanIDs.remove(fanID)
        updateHelperState(helperState)

        if succeeded {
            clearWarning(.leaseLost(fanID: fanID))
            clearWarning(.curveSource(fanID: fanID))
            clearWarning(.curveWrite(fanID: fanID))
            if appliedFan.mode == .automatic {
                clearLeaseState(for: fanID)
            } else {
                automaticRecoveryFanIDs.remove(fanID)
                automaticRecoveryAttempts[fanID] = nil
                automaticRecoveryReasons[fanID] = nil
                clearWarning(.automaticRecovery(fanID: fanID))
                clearWarning(.recoveryLimit(fanID: fanID))
                curveWriteFailures[fanID] = nil
                curveSourceLoss[fanID] = nil
                curveFallbackFanIDs.remove(fanID)
                automaticReadbackCounts[fanID] = nil
                activeHardwareFanIDs.insert(fanID)
                lastAppliedConfigurations[fanID] = appliedFan
                lastAppliedRPM[fanID] = appliedFan.targetRPM
                appliedCurveConfigs[fanID] = appliedFan.mode == .curve ? AppliedCurve(fan: appliedFan) : nil
                // An apply that finished after the post-wake reset armed a fresh
                // lease, so there is nothing left to restore for this fan.
                if !wakeSafetyResetPending {
                    pendingWakeReapplyAttempts[fanID] = nil
                }
            }
        } else if recoveryRequired {
            // Stop tracking until automatic recovery is verified. If a write was
            // attempted it may have reached hardware, so treat the lease as held.
            if writeAttempted {
                activeHardwareFanIDs.insert(fanID)
            }
            appliedCurveConfigs[fanID] = nil
            lastAppliedRPM[fanID] = nil
        }
        // A plain failure is a verified non-write: any configuration applied
        // earlier is still on the hardware under its lease and keeps tracking.

        if let index = fans.firstIndex(where: { $0.id == fanID }) {
            if succeeded {
                if sameConfiguration(fans[index], appliedFan) {
                    fans[index].controlState = appliedFan.mode == .automatic ? .idle : .active
                    fans[index].lastCommand = message
                } else {
                    fans[index].controlState = .pending
                    fans[index].lastCommand = "\(message) Newer edits are still waiting to be applied."
                }
            } else {
                fans[index].controlState = .failed
                fans[index].lastCommand = message
            }
        }
        save()
        if recoveryRequired {
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "The helper could not verify rollback after a failed hardware write."
            )
        }
        dequeueQueuedPresetApply(for: fanID)
        updateTrackedCurveFanIDs()
        refresh()
    }

    /// Installs the Hardware Helper without applying a specific fan (used by the
    /// General settings pane's Install button). Runs off the main actor.
    func installHelper() {
        guard helperState != .ready, !installingHelper else { return }
        switch helperState {
        case .recoveryBlocked:
            // Never re-register while recovery is blocked; retry verified Auto.
            retryAutomaticRecovery()
            return
        case .unreachable:
            refreshHelperState()
            return
        default:
            break
        }
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
                guard let self else { return }
                self.installingHelper = false
                self.updateHelperState(helperState)
                self.updateLegacyMigrationWarning(legacyHelperRemains: legacyHelperRemains)
                if helperState == .ready {
                    self.clearWarning(.helperSetup)
                } else {
                    self.setWarning(.helperSetup, message)
                }
            }
        }
    }

    func unregisterHelper() {
        guard !installingHelper else { return }
        let control = fanControl
        installingHelper = true
        expectedReleaseDepth += 1
        updateTrackedCurveFanIDs()
        controlQueue.async {
            let result = control.unregisterPersistentHelper()
            let helperState = control.persistentHelperState
            Task { @MainActor [weak self] in
                self?.finishUnregister(result, helperState: helperState)
            }
        }
    }

    private func finishUnregister(_ result: FanControlService.ApplyResult, helperState: HardwareHelperState) {
        installingHelper = false
        expectedReleaseDepth = max(0, expectedReleaseDepth - 1)
        updateHelperState(helperState)
        switch result {
        case .applied(let message):
            // Removal first verified Auto for every fan, so no lease survives.
            clearWarning(.helperUnregister)
            for fanID in leaseRelevantFanIDs.sorted() {
                markVerifiedAutomatic(
                    fanID,
                    message: "\(Self.sentence(message)) Manual settings stay staged but are not active."
                )
            }
        case .failed(let message), .recoveryRequired(let message):
            setWarning(.helperUnregister, message)
        }
        updateTrackedCurveFanIDs()
        save()
    }

    /// Asks the daemon to retry its verified automatic recovery (for
    /// `.recoveryBlocked`). Runs off the main actor; never registers,
    /// unregisters, or writes a manual target.
    func retryAutomaticRecovery() {
        guard !recoveryRetryInFlight, !installingHelper else { return }
        recoveryRetryInFlight = true
        installingHelper = true
        expectedReleaseDepth += 1
        let affected = leaseRelevantFanIDs
        updateTrackedCurveFanIDs()
        let control = fanControl
        controlQueue.async {
            let result = control.retryAutomaticRecovery()
            let helperState = control.persistentHelperState
            Task { @MainActor [weak self] in
                self?.finishRecoveryRetry(result, affected: affected, helperState: helperState)
            }
        }
    }

    private func finishRecoveryRetry(
        _ result: FanControlService.ApplyResult,
        affected: Set<String>,
        helperState: HardwareHelperState
    ) {
        recoveryRetryInFlight = false
        installingHelper = false
        expectedReleaseDepth = max(0, expectedReleaseDepth - 1)
        updateHelperState(helperState)
        switch result {
        case .applied(let message):
            clearWarning(.recoveryRetry)
            clearWarning(.wakeRestore)
            for fanID in affected.union(leaseRelevantFanIDs).sorted() {
                markVerifiedAutomatic(
                    fanID,
                    message: "Automatic recovery was verified. \(Self.sentence(message)) Review before applying manual control again."
                )
            }
        case .failed(let message), .recoveryRequired(let message):
            setWarning(.recoveryRetry, "Automatic recovery retry did not complete: \(message)")
            for fanID in affected.sorted() {
                guard let index = fans.firstIndex(where: { $0.id == fanID }) else { continue }
                fans[index].controlState = .failed
                fans[index].lastCommand = "Automatic recovery retry did not complete: \(Self.sentence(message)) The daemon recovery supervisor remains active."
            }
        }
        updateTrackedCurveFanIDs()
        save()
    }

    /// Triggers an off-main helper-state refresh (for example for `.unreachable`).
    func refreshHelperState() {
        scheduleHelperStateRefresh()
    }

    private func scheduleHelperStateRefresh() {
        guard !helperRefreshInFlight else { return }
        helperRefreshInFlight = true
        let control = fanControl
        controlQueue.async {
            let state = control.refreshHelperState()
            let legacyHelperRemains = control.hasLegacyPrivilegedHelper
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.helperRefreshInFlight = false
                self.updateHelperState(state)
                self.updateLegacyMigrationWarning(legacyHelperRemains: legacyHelperRemains)
            }
        }
    }

    private func updateHelperState(_ state: HardwareHelperState) {
        let changed = helperState != state
        if changed {
            helperState = state
        }
        if state == .ready {
            // Registration/approval and blocked-recovery warnings are resolved.
            clearWarning(.helperSetup)
            clearWarning(.recoveryRetry)
        }
        if changed {
            updateTrackedCurveFanIDs()
        }
    }

    private static func unavailableControlMessage(for state: HardwareHelperState) -> String {
        switch state {
        case .monitoringOnly:
            "Monitoring only: this build is not Developer ID signed or lacks its embedded Hardware Helper, so no hardware write was attempted."
        case .wrongLocation:
            "Move ThermoFan to /Applications and relaunch it to enable fan control. No hardware write was attempted."
        case .inactiveSession:
            "Fan control is available only to the active console user session. No hardware write was attempted."
        default:
            "Fan control is unavailable right now. No hardware write was attempted."
        }
    }

    // MARK: - Curve tracking

    /// Re-sends curve targets to hardware as temperature changes, so an applied
    /// curve actually tracks temperature instead of freezing at the RPM written
    /// by the last Apply. The target always comes from the APPLIED curve and
    /// the smoothed temperature, never from staged edits, so editing a curve
    /// (which marks it pending) does not stop the applied one from tracking.
    private func autoApplyCurveTargets(now: Date = Date()) {
        guard helperState == .ready, !wakeSafetyResetPending, expectedReleaseDepth == 0 else { return }
        let control = fanControl
        for fanID in appliedCurveConfigs.keys.sorted() {
            guard
                let applied = appliedCurveConfigs[fanID],
                let index = curveTrackingIndex(for: fanID),
                !curveWriteInFlightFanIDs.contains(fanID)
            else {
                continue
            }
            guard let tracking = trackingTarget(for: fans[index], applied: applied) else {
                handleMissingCurveSource(fanID: fanID, index: index, now: now)
                continue
            }
            curveSourceLoss[fanID] = nil
            noteCurveSource(fanID: fanID, index: index, applied: applied, tracking: tracking)

            if let previous = lastAppliedRPM[fanID],
               abs(previous - tracking.rpm) < Self.curveHysteresisRPM {
                continue
            }
            var target = fans[index]
            target.mode = .curve
            target.curve = applied.points
            target.linkedSensorID = applied.linkedSensorID
            target.targetRPM = tracking.rpm
            let snapshot = target
            curveWriteInFlightFanIDs.insert(fanID)
            controlQueue.async {
                let result = control.applyWithPersistentHelper(snapshot)
                Task { @MainActor [weak self] in
                    self?.finishAutomaticCurveApply(snapshot, result: result)
                }
            }
        }
    }

    /// The fan's index when its applied curve may retarget hardware right now.
    private func curveTrackingIndex(for fanID: String) -> Int? {
        guard
            activeHardwareFanIDs.contains(fanID),
            appliedCurveConfigs[fanID] != nil,
            !automaticRecoveryFanIDs.contains(fanID),
            pendingWakeReapplyAttempts[fanID] == nil,
            !applyingFanIDs.contains(fanID),
            let index = fans.firstIndex(where: { $0.id == fanID }),
            fans[index].source != .estimated,
            fans[index].controlInterface.isAvailable
        else {
            return nil
        }
        return index
    }

    private func trackingTarget(
        for fan: FanDevice,
        applied: AppliedCurve
    ) -> (rpm: Int, sensor: ThermalSensor, isFallback: Bool)? {
        let resolved = curveSensor(linkedSensorID: applied.linkedSensorID)
        guard let sensor = resolved.sensor else { return nil }
        let rpm = FanCurveMath.interpolatedRPM(
            temperature: smoothedTemperature(sensor),
            points: applied.points,
            minRPM: applied.minRPM,
            maxRPM: applied.maxRPM,
            fallback: lastAppliedRPM[fan.id] ?? applied.minRPM
        )
        // Stay inside the range the firmware reports now, too.
        let lower = max(applied.minRPM, fan.minRPM)
        let upper = min(applied.maxRPM, fan.maxRPM)
        let bounded = lower <= upper ? clamp(rpm, min: lower, max: upper) : rpm
        return (bounded, sensor, resolved.isFallback)
    }

    private func noteCurveSource(
        fanID: String,
        index: Int,
        applied: AppliedCurve,
        tracking: (rpm: Int, sensor: ThermalSensor, isFallback: Bool)
    ) {
        if tracking.isFallback {
            curveFallbackFanIDs.insert(fanID)
            let linkedName = applied.linkedSensorID.flatMap { linkedID in
                sensors.first(where: { $0.id == linkedID })?.name
            } ?? "The linked curve sensor"
            let note = "\(linkedName) is unavailable, so the curve is temporarily following \(tracking.sensor.name). The linked sensor setting is unchanged."
            if fans[index].lastCommand != note {
                fans[index].lastCommand = note
            }
        } else if curveFallbackFanIDs.remove(fanID) != nil, fans[index].controlState != .pending {
            fans[index].lastCommand = "The linked curve sensor is available again."
        }
    }

    /// Without any fresh sensor the fan holds its last target. After 3
    /// consecutive ticks and at least 10 s it goes back to Auto.
    private func handleMissingCurveSource(fanID: String, index: Int, now: Date) {
        var loss = curveSourceLoss[fanID] ?? CurveSourceLoss(ticks: 0, since: now)
        loss.ticks += 1
        curveSourceLoss[fanID] = loss
        let held = lastAppliedRPM[fanID].map { "\($0) RPM" } ?? "its last target"
        let note = "No fresh temperature sensor is available for this curve; holding \(held)."
        if fans[index].lastCommand != note {
            fans[index].lastCommand = note
        }
        guard
            loss.ticks >= Self.curveSourceLossTicks,
            now.timeIntervalSince(loss.since) >= Self.curveSourceLossSeconds
        else {
            return
        }
        setWarning(
            .curveSource(fanID: fanID),
            "\(fans[index].name): no fresh temperature sensor was available for its curve, so ThermoFan returned it to automatic control."
        )
        releaseFanToAutomatic(fanID, reason: "No fresh temperature sensor was available for this curve")
    }

    private func finishAutomaticCurveApply(_ appliedFan: FanDevice, result: FanControlService.ApplyResult) {
        let fanID = appliedFan.id
        curveWriteInFlightFanIDs.remove(fanID)
        // The lease may have ended, or the fan been released, while in flight.
        let stillTracking = activeHardwareFanIDs.contains(fanID) && appliedCurveConfigs[fanID] != nil
        let index = fans.firstIndex(where: { $0.id == fanID })
        switch result {
        case .applied:
            guard stillTracking else { break }
            lastAppliedRPM[fanID] = appliedFan.targetRPM
            lastAppliedConfigurations[fanID] = appliedFan
            curveWriteFailures[fanID] = nil
            clearWarning(.curveWrite(fanID: fanID))
            if let index, fans[index].controlState != .pending {
                fans[index].controlState = .active
                if !curveFallbackFanIDs.contains(fanID) {
                    fans[index].lastCommand = "Curve active at \(appliedFan.targetRPM) RPM."
                }
            }
        case .failed(let message):
            // A verified non-write: the previous target is still in effect, so
            // keep tracking and retry, but give up after repeated failures.
            guard stillTracking else { break }
            let failures = (curveWriteFailures[fanID] ?? 0) + 1
            curveWriteFailures[fanID] = failures
            if let index {
                fans[index].controlState = .failed
                fans[index].lastCommand = "Curve update to \(appliedFan.targetRPM) RPM failed (\(failures) of \(Self.maximumCurveWriteFailures)): \(message)"
            }
            if failures >= Self.maximumCurveWriteFailures {
                curveWriteFailures[fanID] = nil
                let name = index.map { fans[$0].name } ?? fanID
                setWarning(
                    .curveWrite(fanID: fanID),
                    "\(name): curve updates failed repeatedly, so ThermoFan returned the fan to automatic control."
                )
                releaseFanToAutomatic(fanID, reason: "Curve updates failed \(Self.maximumCurveWriteFailures) times in a row")
            }
        case .recoveryRequired(let message):
            activeHardwareFanIDs.insert(fanID)
            if let index {
                fans[index].controlState = .failed
                fans[index].lastCommand = message
            }
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "Curve control failed and automatic rollback could not be verified."
            )
        }
        updateTrackedCurveFanIDs()
    }

    /// Returns one fan's hardware to Auto through the normal per-fan path
    /// without discarding the user's staged configuration.
    private func releaseFanToAutomatic(_ fanID: String, reason: String) {
        guard
            !applyingFanIDs.contains(fanID),
            let index = fans.firstIndex(where: { $0.id == fanID })
        else {
            return
        }
        var automatic = lastAppliedConfigurations[fanID] ?? fans[index]
        automatic.mode = .automatic
        automatic.controlInterface = fans[index].controlInterface
        let snapshot = automatic
        appliedCurveConfigs[fanID] = nil
        curveFallbackFanIDs.remove(fanID)
        curveSourceLoss[fanID] = nil
        applyingFanIDs.insert(fanID)
        fans[index].lastCommand = "\(Self.sentence(reason)) Returning this fan to automatic control."
        updateTrackedCurveFanIDs()
        let control = fanControl
        controlQueue.async {
            let result = control.applyWithPersistentHelper(snapshot)
            let helperState = control.persistentHelperState
            Task { @MainActor [weak self] in
                self?.finishRelease(fanID: fanID, reason: reason, result: result, helperState: helperState)
            }
        }
    }

    private func finishRelease(
        fanID: String,
        reason: String,
        result: FanControlService.ApplyResult,
        helperState: HardwareHelperState
    ) {
        applyingFanIDs.remove(fanID)
        updateHelperState(helperState)
        let index = fans.firstIndex(where: { $0.id == fanID })
        switch result {
        case .applied:
            clearLeaseState(for: fanID)
            if let index {
                fans[index].controlState = .failed
                fans[index].lastCommand = "\(Self.sentence(reason)) The fan was verified back in automatic control; apply again to resume manual control."
            }
        case .failed(let message), .recoveryRequired(let message):
            // The fan may still be held at a manual target with nothing
            // tracking it, so escalate to all-fan automatic recovery.
            activeHardwareFanIDs.insert(fanID)
            if let index {
                fans[index].controlState = .failed
                fans[index].lastCommand = "\(Self.sentence(reason)) Returning to automatic control was not verified: \(message)"
            }
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "\(Self.sentence(reason)) The automatic-control request was not verified."
            )
        }
        save()
        dequeueQueuedPresetApply(for: fanID)
        updateTrackedCurveFanIDs()
    }

    private func updateTrackedCurveFanIDs() {
        var tracked: Set<String> = []
        if helperState == .ready, !wakeSafetyResetPending, expectedReleaseDepth == 0 {
            for fanID in appliedCurveConfigs.keys
            where curveTrackingIndex(for: fanID) != nil && curveSourceLoss[fanID] == nil {
                tracked.insert(fanID)
            }
        }
        if tracked != trackedCurveFanIDs {
            trackedCurveFanIDs = tracked
        }
    }

    // MARK: - Lease loss and reconciliation

    private func handleLeaseLost(fanIDs: [String], reason: String) {
        // During an app-initiated all-fan release the client reports the leases
        // that operation itself released; its result reconciles those fans.
        guard expectedReleaseDepth == 0 else { return }
        endLease(fanIDs: fanIDs, reason: reason)
    }

    /// The daemon (or macOS) took these fans back without the app asking.
    private func endLease(fanIDs: [String], reason: String) {
        for fanID in fanIDs {
            // A fan that is only waiting for its post-wake restore holds no
            // lease (the verified reset released it), so a late report about
            // that old lease must not cancel the restore.
            let mayHoldLease = activeHardwareFanIDs.contains(fanID)
                || automaticRecoveryFanIDs.contains(fanID)
                || applyingFanIDs.contains(fanID)
                || curveWriteInFlightFanIDs.contains(fanID)
            guard mayHoldLease else { continue }
            clearLeaseState(for: fanID)
            guard let index = fans.firstIndex(where: { $0.id == fanID }) else { continue }
            fans[index].controlState = .failed
            fans[index].lastCommand = "Hardware Helper returned this fan to automatic control: \(Self.sentence(reason))"
            setWarning(
                .leaseLost(fanID: fanID),
                "\(fans[index].name) was returned to automatic control by the Hardware Helper: \(Self.sentence(reason)) Apply again to resume manual control."
            )
        }
        updateTrackedCurveFanIDs()
    }

    /// A leased fan that reads back as Auto on two consecutive samples was
    /// taken back by the daemon or macOS; stop claiming the lease.
    private func reconcileHardwareReportedAutomatic() {
        for fanID in activeHardwareFanIDs.sorted() {
            guard
                let fan = fans.first(where: { $0.id == fanID }),
                fan.source != .estimated,
                fan.hardwareMode == .automatic,
                !applyingFanIDs.contains(fanID),
                !curveWriteInFlightFanIDs.contains(fanID),
                !automaticRecoveryFanIDs.contains(fanID),
                pendingWakeReapplyAttempts[fanID] == nil,
                !wakeSafetyResetPending,
                expectedReleaseDepth == 0
            else {
                automaticReadbackCounts[fanID] = nil
                continue
            }
            let count = (automaticReadbackCounts[fanID] ?? 0) + 1
            if count >= Self.automaticReadbacksBeforeReconcile {
                automaticReadbackCounts[fanID] = nil
                endLease(
                    fanIDs: [fanID],
                    reason: "the hardware reported automatic mode on \(count) consecutive samples."
                )
            } else {
                automaticReadbackCounts[fanID] = count
            }
        }
        automaticReadbackCounts = automaticReadbackCounts.filter { activeHardwareFanIDs.contains($0.key) }
    }

    /// Fans for which this app may hold, restore, or be recovering a lease.
    private var leaseRelevantFanIDs: Set<String> {
        activeHardwareFanIDs
            .union(automaticRecoveryFanIDs)
            .union(pendingWakeReapplyAttempts.keys)
            .union(appliedCurveConfigs.keys)
    }

    /// Forgets every lease-related record for one fan. Keyed warnings that
    /// explain what happened (lease loss, curve source, curve writes) stay
    /// until the next successful apply.
    private func clearLeaseState(for fanID: String) {
        activeHardwareFanIDs.remove(fanID)
        automaticRecoveryFanIDs.remove(fanID)
        automaticRecoveryAttempts[fanID] = nil
        automaticRecoveryReasons[fanID] = nil
        pendingWakeReapplyAttempts[fanID] = nil
        lastAppliedConfigurations[fanID] = nil
        appliedCurveConfigs[fanID] = nil
        lastAppliedRPM[fanID] = nil
        curveWriteFailures[fanID] = nil
        curveSourceLoss[fanID] = nil
        curveFallbackFanIDs.remove(fanID)
        automaticReadbackCounts[fanID] = nil
        clearWarning(.automaticRecovery(fanID: fanID))
        clearWarning(.recoveryLimit(fanID: fanID))
    }

    /// The fan was verified in automatic control by an all-fan operation.
    private func markVerifiedAutomatic(_ fanID: String, message: String) {
        clearLeaseState(for: fanID)
        guard
            !applyingFanIDs.contains(fanID),
            let index = fans.firstIndex(where: { $0.id == fanID })
        else {
            return
        }
        fans[index].controlState = fans[index].mode == .automatic ? .idle : .pending
        fans[index].lastCommand = message
    }

    // MARK: - Quit

    /// Returns every daemon-owned fan to automatic control before the app exits.
    /// The daemon also recovers on connection invalidation, heartbeat expiry,
    /// and process exit, so this bounded request is only the first safety path.
    func restoreAutomaticControlOnQuit() {
        flushSaveSynchronously()
        guard mayHoldLease else { return }
        // `returnAllToAutomatic(timeout:)` was not available on
        // FanControlService when this was written, so bound the wait here. The
        // call stays on the control queue; if the helper is busy or hung, the
        // app exits anyway and the root daemon returns leased fans to Auto.
        let control = fanControl
        let finished = DispatchSemaphore(value: 0)
        controlQueue.async {
            _ = control.returnAllToAutomatic()
            finished.signal()
        }
        _ = finished.wait(timeout: .now() + Self.quitRecoveryTimeout)
    }

    private var mayHoldLease: Bool {
        if !leaseRelevantFanIDs.isEmpty
            || !applyingFanIDs.isEmpty
            || !curveWriteInFlightFanIDs.isEmpty {
            return true
        }
        switch helperState {
        case .missing, .monitoringOnly, .wrongLocation:
            return false
        case .ready, .recoveryBlocked, .unreachable, .updateRequired, .inactiveSession,
             .legacyCleanupRequired, .approvalRequired:
            return true
        }
    }

    /// Keeps App Nap and automatic termination away while a fan lease is held,
    /// so the main-queue heartbeat is never throttled into a lease expiry.
    private func updateLeaseActivity() {
        if !activeHardwareFanIDs.isEmpty {
            guard leaseActivity == nil else { return }
            // `.userInitiated` would also block idle system sleep for as long as
            // a curve stays applied; sleep is already handled by the wake reset,
            // so only App Nap and termination are suppressed here.
            leaseActivity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiatedAllowingIdleSystemSleep,
                    .suddenTerminationDisabled,
                    .automaticTerminationDisabled
                ],
                reason: "ThermoFan holds a fan-control lease whose heartbeat must keep running."
            )
        } else if let activity = leaseActivity {
            ProcessInfo.processInfo.endActivity(activity)
            leaseActivity = nil
        }
    }

    // MARK: - Persistence

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
        var migratedPreferences: [String: SensorPreference] = [:]
        for (sensorID, preference) in state.sensorPreferences
        where Self.migratedSensorID(sensorID) != sensorID {
            migratedPreferences[Self.migratedSensorID(sensorID)] = preference
        }
        for (sensorID, preference) in state.sensorPreferences
        where Self.migratedSensorID(sensorID) == sensorID {
            // A key already in the current format wins over a legacy duplicate.
            migratedPreferences[sensorID] = preference
        }
        sensorPreferences = migratedPreferences
        customIndexes = state.customIndexes.map { index in
            var migrated = index
            migrated.sensorIDs = index.sensorIDs.map(Self.migratedSensorID)
            return migrated
        }
        // Saved fans start as `.estimated` placeholders. They are replaced only
        // when a real fan with the same ID is discovered, never dropped because
        // a sample lacked them, so a bad first sample cannot wipe settings.
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
        .sorted { $0.id < $1.id }
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
        saveSequence &+= 1
        let sequence = saveSequence
        let state = snapshotState()
        let persistence = self.persistence
        persistenceQueue.async {
            persistence.save(state, sequence: sequence)
        }
    }

    func flushSaveSynchronously() {
        pendingSave?.cancel()
        pendingSave = nil
        saveSequence &+= 1
        let sequence = saveSequence
        let state = snapshotState()
        let persistence = self.persistence
        // Runs behind every background save already queued; the sequence number
        // also stops any older snapshot from overwriting this final one.
        persistenceQueue.sync {
            persistence.save(state, sequence: sequence)
        }
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
        Dictionary(fans.map { fan in
            (
                fan.id,
                FanPresetSetting(
                    mode: fan.mode,
                    targetRPM: fan.targetRPM,
                    linkedSensorID: fan.linkedSensorID,
                    curve: fan.curve
                )
            )
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Fan settings for "did anything worth saving change?" A curve's target
    /// follows temperature on every tick, so it is not a user setting and must
    /// not rewrite state.json each tick.
    private func fanSettingsForChangeDetection() -> [String: FanPresetSetting] {
        currentFanSettings().mapValues { setting in
            guard setting.mode == .curve else { return setting }
            var stable = setting
            stable.targetRPM = 0
            return stable
        }
    }

    // MARK: - Sensors and indexes

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
        // Estimated readings are placeholders, never measurements; no index a
        // curve can follow may be built from them.
        let measured = baseSensors.filter { $0.source != .estimated }
        let builtIn = builtInIndexes(from: measured)
        let availableForCustom = measured + builtIn
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
        let lookup = Dictionary(
            sensors.filter { $0.source != .estimated }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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

    // MARK: - Fans

    private func mergeFans(_ incoming: [FanDevice]) -> [FanDevice] {
        let existing = Dictionary(fans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var mergedFans = incoming.map { fan -> FanDevice in
            guard let saved = existing[fan.id] else {
                var discovered = fan
                discovered.curve = FanCurveMath.normalized(
                    fan.curve,
                    minRPM: fan.minRPM,
                    maxRPM: fan.maxRPM
                )
                switch fan.hardwareMode {
                case .fixed, .curve:
                    discovered.controlState = .pending
                    discovered.lastCommand = "Hardware reports manual fan control. Choose Auto or review the target, then apply."
                case .automatic, nil:
                    // `nil` is an unreadable (unknown) mode, not manual control.
                    break
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
                // A saved placeholder now matches a real fan: restore its
                // settings, but never claim they are active on hardware.
                if saved.mode == .automatic {
                    switch fan.hardwareMode {
                    case .fixed, .curve:
                        merged.controlState = .pending
                        merged.lastCommand = "Hardware is in manual mode. Apply Auto to return control to macOS."
                    case .automatic, nil:
                        merged.controlState = .idle
                        merged.lastCommand = nil
                    }
                } else {
                    merged.controlState = .pending
                    merged.lastCommand = "Saved \(saved.mode.title) settings are not active yet. Review them, then apply."
                }
            }
            return merged
        }

        let incomingIDs = Set(incoming.map(\.id))
        for missing in fans where !incomingIDs.contains(missing.id) {
            guard missing.source != .estimated else {
                // Keep saved placeholders untouched until the real fan appears.
                mergedFans.append(missing)
                continue
            }
            var stale = missing
            stale.controlInterface = .unavailable
            stale.hardwareMode = nil
            stale.controlState = .failed
            stale.lastCommand = "Fan telemetry is temporarily unavailable. Last reading is shown; hardware writes are disabled."
            mergedFans.append(stale)
        }
        return mergedFans.sorted { $0.id < $1.id }
    }

    /// Recomputes the staged (displayed) target of every curve-mode fan from
    /// the smoothed temperature. It never writes hardware, never changes the
    /// user's linked sensor, and never marks a fan pending; hardware tracking
    /// uses the applied curve in `autoApplyCurveTargets`.
    private func applyCurveTargets() {
        for index in fans.indices where fans[index].mode == .curve && fans[index].source != .estimated {
            fans[index].curve = FanCurveMath.normalized(
                fans[index].curve,
                minRPM: fans[index].minRPM,
                maxRPM: fans[index].maxRPM
            )
            guard let sensor = curveSensor(linkedSensorID: fans[index].linkedSensorID).sensor else {
                continue
            }
            fans[index].targetRPM = FanCurveMath.interpolatedRPM(
                temperature: smoothedTemperature(sensor),
                points: fans[index].curve,
                minRPM: fans[index].minRPM,
                maxRPM: fans[index].maxRPM,
                fallback: fans[index].targetRPM
            )
        }
    }

    /// Resolves the sensor a curve follows. `nil` means "Hottest sensor". A
    /// linked sensor that is missing, stale, or estimated falls back to the
    /// recommended sensor for this tick only; the link itself never changes.
    private func curveSensor(linkedSensorID: String?) -> (sensor: ThermalSensor?, isFallback: Bool) {
        guard let linkedSensorID else {
            return (recommendedCurveSensor, false)
        }
        if let linked = sensors.first(where: { $0.id == linkedSensorID }), isUsableForControl(linked) {
            return (linked, false)
        }
        return (recommendedCurveSensor, true)
    }

    private var recommendedCurveSensor: ThermalSensor? {
        let candidates = sensors.filter { !$0.isHidden && isUsableForControl($0) }
        return candidates.first { $0.id == "index-system-hotspot" }
            ?? candidates.first { $0.id == "TCMz" }
            ?? candidates
                .filter { [.cpu, .gpu, .power].contains($0.category) }
                .max { smoothedTemperature($0) < smoothedTemperature($1) }
    }

    /// Marks staged edits as not yet applied. This deliberately leaves the
    /// applied configuration alone: a curve already on the hardware keeps
    /// tracking temperature with its APPLIED points (`appliedCurveConfigs`)
    /// until the user applies the staged edits or returns the fan to Auto.
    private func markFanPending(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
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

    /// Whether two fans carry the same user configuration. A curve's current
    /// target follows temperature, so it is not part of a curve's identity.
    private func sameConfiguration(_ lhs: FanDevice, _ rhs: FanDevice) -> Bool {
        guard lhs.mode == rhs.mode else { return false }
        switch lhs.mode {
        case .automatic:
            return true
        case .fixed:
            return lhs.targetRPM == rhs.targetRPM
        case .curve:
            return lhs.linkedSensorID == rhs.linkedSensorID
                && lhs.curve == rhs.curve
        }
    }

    private func dequeueQueuedPresetApply(for fanID: String) {
        guard !applyingFanIDs.contains(fanID) else { return }
        if automaticRecoveryFanIDs.contains(fanID) {
            // Never follow an unverified hardware state with a queued write.
            queuedPresetApplies[fanID] = nil
            return
        }
        guard
            let queued = queuedPresetApplies.removeValue(forKey: fanID),
            let current = fans.first(where: { $0.id == fanID }),
            sameConfiguration(current, queued)
        else {
            return
        }
        applyFanWithAdmin(fanID)
    }

    // MARK: - Sleep and wake

    private func handleWake() {
        sampleGeneration &+= 1
        for fanID in activeHardwareFanIDs where !automaticRecoveryFanIDs.contains(fanID) {
            guard let applied = lastAppliedConfigurations[fanID], applied.mode != .automatic else { continue }
            pendingWakeReapplyAttempts[fanID] = 0
        }
        if !activeHardwareFanIDs.isEmpty {
            // Pause curve tracking and return every leased fan to Auto before
            // anything is re-armed against post-wake firmware state.
            wakeSafetyResetsInFlight += 1
            expectedReleaseDepth += 1
            let control = fanControl
            controlQueue.async {
                let result = control.returnAllToAutomatic()
                let helperState = control.persistentHelperState
                Task { @MainActor [weak self] in
                    self?.finishWakeSafetyReset(result, helperState: helperState)
                }
            }
        }
        updateTrackedCurveFanIDs()
        restartTimer()
        isSampling = true
        let prefs = preferences
        let probe = self.probe
        let generation = sampleGeneration
        // Serialized behind any pre-wake sample already on the queue, and
        // delayed so the SMC settles before its first post-wake read.
        sampleQueue.asyncAfter(deadline: .now() + Self.postWakeSampleDelay) {
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
        wakeSafetyResetsInFlight = max(0, wakeSafetyResetsInFlight - 1)
        expectedReleaseDepth = max(0, expectedReleaseDepth - 1)
        updateHelperState(helperState)
        switch result {
        case .applied:
            // Every lease was released and verified in Auto. Keep what must be
            // restored, but stop claiming a lease until re-apply arms a new one.
            for fanID in activeHardwareFanIDs.union(automaticRecoveryFanIDs).sorted() {
                if automaticRecoveryFanIDs.contains(fanID) {
                    markVerifiedAutomatic(
                        fanID,
                        message: "The fan was verified back in automatic control after wake. Review before applying manual control again."
                    )
                    continue
                }
                if let applied = lastAppliedConfigurations[fanID], applied.mode != .automatic {
                    if pendingWakeReapplyAttempts[fanID] == nil {
                        pendingWakeReapplyAttempts[fanID] = 0
                    }
                    activeHardwareFanIDs.remove(fanID)
                    lastAppliedRPM[fanID] = nil
                    automaticReadbackCounts[fanID] = nil
                } else {
                    clearLeaseState(for: fanID)
                }
            }
            clearWarning(.wakeRestore)
            // Re-arm only after the post-wake topology sample has completed.
            if !isSampling {
                reapplyActiveFansAfterWake()
            }
        case .failed(let message), .recoveryRequired(let message):
            let affectedFanIDs = Set(pendingWakeReapplyAttempts.keys).union(activeHardwareFanIDs)
            pendingWakeReapplyAttempts.removeAll()
            setWarning(.wakeRestore, "Post-wake automatic recovery was not verified: \(message)")
            for fanID in affectedFanIDs.sorted() {
                // Fans that held a lease stay in `activeHardwareFanIDs`: their
                // state is unknown until recovery is verified.
                automaticRecoveryAttempts[fanID] = 0
                scheduleAutomaticRecovery(
                    fanID: fanID,
                    reason: "Post-wake automatic recovery must succeed before manual control can resume."
                )
            }
        }
        updateTrackedCurveFanIDs()
    }

    /// Restores each fan's APPLIED configuration after wake, never its staged
    /// edits; a curve is re-armed at the target for the current temperature.
    private func reapplyActiveFansAfterWake() {
        guard !wakeSafetyResetPending, !pendingWakeReapplyAttempts.isEmpty else { return }
        guard helperState == .ready else {
            setWarning(
                .wakeRestore,
                "Fan settings are waiting after wake because the verified Hardware Helper is unavailable (\(helperState.title)). The fans stay in automatic control meanwhile."
            )
            return
        }
        let control = fanControl
        for fanID in pendingWakeReapplyAttempts.keys.sorted() where !applyingFanIDs.contains(fanID) {
            guard
                !automaticRecoveryFanIDs.contains(fanID),
                var applied = lastAppliedConfigurations[fanID],
                applied.mode != .automatic
            else {
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
            applied.controlInterface = current.controlInterface
            if applied.mode == .curve {
                let curve = appliedCurveConfigs[fanID] ?? AppliedCurve(fan: applied)
                appliedCurveConfigs[fanID] = curve
                if let tracking = trackingTarget(for: current, applied: curve) {
                    applied.targetRPM = tracking.rpm
                }
            }
            let snapshot = applied
            let nextAttempt = attempts + 1
            let maximumAttempts = Self.maximumWakeReapplyAttempts
            applyingFanIDs.insert(fanID)
            controlQueue.async {
                let result: FanControlService.ApplyResult
                do {
                    try control.startWatchdog(
                        for: snapshot,
                        parentPID: ProcessInfo.processInfo.processIdentifier
                    )
                    result = control.applyWithPersistentHelper(snapshot)
                } catch {
                    result = .failed(
                        "Wake restore was blocked because a fresh crash-watchdog lease could not be armed: \(error.localizedDescription)"
                    )
                }
                let shouldRecoverAutomatically: Bool
                switch result {
                case .recoveryRequired:
                    shouldRecoverAutomatically = true
                case .failed:
                    shouldRecoverAutomatically = nextAttempt >= maximumAttempts
                case .applied:
                    shouldRecoverAutomatically = false
                }
                var recoveryResult: FanControlService.ApplyResult?
                if shouldRecoverAutomatically {
                    var reset = snapshot
                    reset.mode = .automatic
                    recoveryResult = control.applyWithPersistentHelper(reset)
                }
                let finalRecoveryResult = recoveryResult
                let helperState = control.persistentHelperState
                Task { @MainActor [weak self] in
                    self?.finishWakeReapply(
                        appliedFan: snapshot,
                        result: result,
                        attempt: nextAttempt,
                        recoveryResult: finalRecoveryResult,
                        helperState: helperState
                    )
                }
            }
        }
        updateTrackedCurveFanIDs()
    }

    private func finishWakeReapply(
        appliedFan: FanDevice,
        result: FanControlService.ApplyResult,
        attempt: Int,
        recoveryResult: FanControlService.ApplyResult?,
        helperState: HardwareHelperState
    ) {
        let fanID = appliedFan.id
        applyingFanIDs.remove(fanID)
        updateHelperState(helperState)

        switch result {
        case .applied:
            pendingWakeReapplyAttempts[fanID] = nil
            automaticRecoveryFanIDs.remove(fanID)
            automaticRecoveryAttempts[fanID] = nil
            automaticRecoveryReasons[fanID] = nil
            clearWarning(.leaseLost(fanID: fanID))
            activeHardwareFanIDs.insert(fanID)
            // The re-applied configuration is the applied one (never staged
            // edits), so it is safe to resume tracking from it.
            lastAppliedConfigurations[fanID] = appliedFan
            lastAppliedRPM[fanID] = appliedFan.targetRPM
            if appliedFan.mode == .curve {
                appliedCurveConfigs[fanID] = appliedCurveConfigs[fanID] ?? AppliedCurve(fan: appliedFan)
            } else {
                appliedCurveConfigs[fanID] = nil
            }
            if let index = fans.firstIndex(where: { $0.id == fanID }) {
                if sameConfiguration(fans[index], appliedFan) {
                    fans[index].controlState = .active
                    fans[index].lastCommand = "Fan settings restored after wake."
                } else {
                    fans[index].controlState = .pending
                    fans[index].lastCommand = "The applied fan settings were restored after wake. Newer edits are still pending."
                }
            }
            if pendingWakeReapplyAttempts.isEmpty {
                clearWarning(.wakeRestore)
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
        dequeueQueuedPresetApply(for: fanID)
        updateTrackedCurveFanIDs()
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
            pendingWakeReapplyAttempts[fanID] = nil
            switch recoveryResult {
            case .applied:
                clearLeaseState(for: fanID)
                if let index = fans.firstIndex(where: { $0.id == fanID }) {
                    fans[index].controlState = .pending
                    fans[index].lastCommand = "Wake restore failed after \(attempt) attempt(s), so the fan was verified back in automatic control. Review and apply again if needed."
                }
            case .failed(let recoveryMessage), .recoveryRequired(let recoveryMessage):
                activeHardwareFanIDs.insert(fanID)
                appliedCurveConfigs[fanID] = nil
                automaticRecoveryAttempts[fanID] = 0
                if let index = fans.firstIndex(where: { $0.id == fanID }) {
                    fans[index].controlState = .failed
                    fans[index].lastCommand = "Wake restore failed: \(message) Automatic recovery also failed: \(recoveryMessage) The daemon recovery supervisor remains active with backoff retries."
                }
                setWarning(.wakeRestore, "Automatic fan recovery after wake failed and will be retried.")
                scheduleAutomaticRecovery(
                    fanID: fanID,
                    reason: "Wake restore and its immediate automatic rollback both failed."
                )
            }
            return
        }

        if recoveryWasRequired {
            pendingWakeReapplyAttempts[fanID] = nil
            activeHardwareFanIDs.insert(fanID)
            appliedCurveConfigs[fanID] = nil
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

    // MARK: - Automatic recovery

    /// A fan that was actively controlled must never keep a stale manual target
    /// after its write interface disappears. The helper independently re-probes
    /// the firmware and verifies Auto/System mode; failures remain retryable.
    private func recoverFansRequiringAutomaticControl() {
        for fanID in activeHardwareFanIDs.sorted() where !automaticRecoveryFanIDs.contains(fanID) {
            guard
                let fan = fans.first(where: { $0.id == fanID }),
                !fan.controlInterface.isAvailable
            else {
                continue
            }
            scheduleAutomaticRecovery(
                fanID: fanID,
                reason: "Automatic control is required because the fan-control interface could not be verified."
            )
        }

        // Past the UI retry limit the daemon's supervisor owns recovery; keep
        // watching the read-back and finish once the fan reports Auto.
        for fanID in automaticRecoveryFanIDs.sorted()
        where (automaticRecoveryAttempts[fanID] ?? 0) >= Self.maximumAutomaticRecoveryAttempts
            && !applyingFanIDs.contains(fanID) {
            guard
                let fan = fans.first(where: { $0.id == fanID }),
                fan.source != .estimated,
                fan.hardwareMode == .automatic
            else {
                continue
            }
            markVerifiedAutomatic(
                fanID,
                message: "The hardware now reports automatic control, so recovery is complete. Review before applying manual control again."
            )
        }

        runAutomaticRecoveryIfNeeded()
    }

    private func scheduleAutomaticRecovery(fanID: String, reason: String) {
        automaticRecoveryFanIDs.insert(fanID)
        automaticRecoveryReasons[fanID] = reason
        if automaticRecoveryAttempts[fanID] == nil {
            automaticRecoveryAttempts[fanID] = 0
        }
        pendingWakeReapplyAttempts[fanID] = nil
        appliedCurveConfigs[fanID] = nil
        lastAppliedRPM[fanID] = nil
        curveSourceLoss[fanID] = nil
        curveFallbackFanIDs.remove(fanID)
        runAutomaticRecoveryIfNeeded()
        updateTrackedCurveFanIDs()
    }

    /// Issues at most one all-fan automatic recovery at a time. The request
    /// returns every ThermoFan-owned fan to Auto, so its result reconciles
    /// every fan that held a lease, not only the ones being recovered.
    private func runAutomaticRecoveryIfNeeded() {
        guard !automaticRecoveryFanIDs.isEmpty else {
            clearWarning(.recoveryWaitingForHelper)
            return
        }
        // Another all-fan release (recovery, user retry, wake reset) will
        // reconcile these fans itself.
        guard !automaticRecoveryInFlight, !recoveryRetryInFlight, !wakeSafetyResetPending else { return }

        var eligible: [String] = []
        for fanID in automaticRecoveryFanIDs.sorted() where !applyingFanIDs.contains(fanID) {
            if (automaticRecoveryAttempts[fanID] ?? 0) >= Self.maximumAutomaticRecoveryAttempts {
                reportRecoveryLimit(fanID)
            } else {
                eligible.append(fanID)
            }
        }
        let candidates = eligible
        guard !candidates.isEmpty else { return }
        guard helperState == .ready || helperState == .recoveryBlocked else {
            setWarning(
                .recoveryWaitingForHelper,
                "Automatic fan recovery is waiting for the authenticated Hardware Helper (\(helperState.title)). The root daemon's own recovery remains active."
            )
            return
        }
        clearWarning(.recoveryWaitingForHelper)

        for fanID in candidates {
            automaticRecoveryAttempts[fanID] = (automaticRecoveryAttempts[fanID] ?? 0) + 1
        }
        automaticRecoveryInFlight = true
        expectedReleaseDepth += 1
        applyingFanIDs.formUnion(candidates)
        updateTrackedCurveFanIDs()
        let control = fanControl
        controlQueue.async {
            let result = control.returnAllToAutomatic()
            let helperState = control.persistentHelperState
            Task { @MainActor [weak self] in
                self?.finishAutomaticRecovery(candidates: candidates, result: result, helperState: helperState)
            }
        }
    }

    private func reportRecoveryLimit(_ fanID: String) {
        guard let index = fans.firstIndex(where: { $0.id == fanID }) else { return }
        let message = "The UI recovery retry limit was reached. The root daemon's recovery supervisor remains active; ThermoFan clears this once the fan reads back as automatic."
        if fans[index].controlState != .failed {
            fans[index].controlState = .failed
        }
        if fans[index].lastCommand != message {
            fans[index].lastCommand = message
        }
        setWarning(
            .recoveryLimit(fanID: fanID),
            "Automatic recovery for \(fans[index].name) reached its UI retry limit; the daemon recovery supervisor remains active."
        )
    }

    private func finishAutomaticRecovery(
        candidates: [String],
        result: FanControlService.ApplyResult,
        helperState: HardwareHelperState
    ) {
        automaticRecoveryInFlight = false
        expectedReleaseDepth = max(0, expectedReleaseDepth - 1)
        applyingFanIDs.subtract(candidates)
        updateHelperState(helperState)

        switch result {
        case .applied:
            let recovering = automaticRecoveryFanIDs.union(candidates)
            for fanID in recovering.union(activeHardwareFanIDs).sorted() {
                let message: String
                if recovering.contains(fanID) {
                    let reason = automaticRecoveryReasons[fanID].map { "\(Self.sentence($0)) " } ?? ""
                    message = "\(reason)The fan was verified back in automatic control. Review before applying manual control again."
                } else {
                    message = "ThermoFan returned all fans to automatic control while recovering another fan. Review and apply again to resume manual control."
                }
                markVerifiedAutomatic(fanID, message: message)
            }
            if automaticRecoveryFanIDs.isEmpty {
                clearWarning(.wakeRestore)
                clearWarning(.recoveryWaitingForHelper)
            }
        case .failed(let message), .recoveryRequired(let message):
            let outcome: String
            if case .recoveryRequired = result {
                outcome = "could not be verified"
            } else {
                outcome = "failed"
            }
            for fanID in candidates {
                // Never follow an unverified recovery with a queued manual write.
                queuedPresetApplies[fanID] = nil
                guard let index = fans.firstIndex(where: { $0.id == fanID }) else { continue }
                let reason = automaticRecoveryReasons[fanID].map { "\(Self.sentence($0)) " } ?? ""
                fans[index].controlState = .failed
                fans[index].lastCommand = "\(reason)Automatic recovery \(outcome): \(Self.sentence(message)) The daemon recovery supervisor remains active and will retry."
                setWarning(
                    .automaticRecovery(fanID: fanID),
                    "Automatic recovery for \(fans[index].name) \(outcome) and will be retried."
                )
            }
        }
        save()
        for fanID in candidates {
            dequeueQueuedPresetApply(for: fanID)
        }
        updateTrackedCurveFanIDs()
    }

    // MARK: - Warnings

    private func setWarning(_ key: AppWarningKey, _ message: String) {
        guard appWarnings[key] != message else { return }
        if appWarnings[key] == nil {
            appWarningOrder.append(key)
        }
        appWarnings[key] = message
        publishWarnings()
    }

    private func clearWarning(_ key: AppWarningKey) {
        guard appWarnings.removeValue(forKey: key) != nil else { return }
        appWarningOrder.removeAll { $0 == key }
        publishWarnings()
    }

    private func publishWarnings() {
        var combined = hardwareWarnings
        for key in appWarningOrder {
            if let message = appWarnings[key], !combined.contains(message) {
                combined.append(message)
            }
        }
        if combined != warnings {
            warnings = combined
        }
    }

    private func updateLegacyMigrationWarning(legacyHelperRemains: Bool) {
        if legacyHelperRemains {
            setWarning(.legacyMigration, Self.legacyMigrationWarning)
        } else {
            clearWarning(.legacyMigration)
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: Int, min minimum: Int, max maximum: Int) -> Int {
        Swift.max(minimum, Swift.min(maximum, value))
    }

    /// Ensures a message fragment ends with sentence punctuation.
    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - Median smoothing

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
    /// to the raw value when no history is available yet. Used for the menu
    /// bar and for curve evaluation alike.
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
