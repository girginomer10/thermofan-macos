import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var store: ThermalStore

    private var displayedSensors: [ThermalSensor] {
        Array(store.menuSensors.prefix(3))
    }

    /// Keep the NSStatusItem width stable while the first asynchronous hardware
    /// sample is arriving. Resizing the status item while its window is opening
    /// can make macOS immediately dismiss the window on the first click.
    private var sensorSlotCount: Int {
        min(3, max(1, store.preferences.menuSensorIDs.count))
    }

    var body: some View {
        let sensors = displayedSensors
        let unit = store.preferences.temperatureUnit
        HStack(spacing: 5) {
            Image(systemName: "fan.fill")
            ForEach(0..<sensorSlotCount, id: \.self) { offset in
                if offset > 0 {
                    Text("·").foregroundStyle(.secondary)
                }
                let sensor = sensors.indices.contains(offset) ? sensors[offset] : nil
                // Estimated readings keep the "~" prefix and italics here too,
                // so the menu bar never passes one off as a measured value.
                Text(sensor.map { SensorReadingCopy.value($0, unit: unit) } ?? "--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .italic(sensor?.source == .estimated)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 42, alignment: .trailing)
                    .opacity(sensor.map { store.isSensorFresh($0) } ?? true ? 1 : 0.55)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: sensors))
    }

    private func accessibilityText(for sensors: [ThermalSensor]) -> String {
        guard !sensors.isEmpty else { return "No sensor reading available" }
        let unit = store.preferences.temperatureUnit
        return sensors
            .map {
                let estimate = $0.source == .estimated ? ", estimated" : ""
                let freshness = store.isSensorFresh($0) ? "" : ", last reading"
                return "\($0.name) \(unit.format($0.temperatureC))\(estimate)\(freshness)"
            }
            .joined(separator: ", ")
    }
}

struct StatusPanelView: View {
    @EnvironmentObject private var store: ThermalStore
    /// Uncommitted numeric drafts in the compact fan cards. Apply and presets
    /// flush them first so a click never sends the previously staged value.
    @State private var drafts = FanDraftCommitRegistry()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 14) {
                    quickStats
                    warnings
                    sensorsSection
                    fansSection
                    presetsSection
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 390, height: 640)
    }

    private var header: some View {
        let reading = headerReading
        let tint = thermalTint(for: reading)
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: "fan.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("ThermoFan")
                    .font(.headline)
                Text("\(store.machine.chipName) · \(store.activePresetName)")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(reading.map { SensorReadingCopy.value($0, unit: store.preferences.temperatureUnit) } ?? "--")
                    .font(.title3.weight(.bold))
                    .italic(reading?.source == .estimated)
                Text(reading?.name ?? "No sensor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(reading?.source == .estimated ? "Estimated reading; hardware sensor data was unavailable." : "")
        }
        .padding(14)
    }

    /// The hottest sensor, carrying the same median-smoothed value the menu bar
    /// shows for it so the header and the menu bar never disagree. Falls back to
    /// the raw reading only when the store publishes no smoothed copy of it.
    private var headerReading: ThermalSensor? {
        guard let hottest = store.hottestSensor else { return nil }
        return store.menuSensors.first { $0.id == hottest.id } ?? hottest
    }

    private var quickStats: some View {
        HStack(spacing: 8) {
            MetricPill(title: "Load", value: "\(Int(store.machine.cpuLoad * 100))%", symbol: "speedometer")
            MetricPill(title: "Fans", value: "\(store.fans.count)", symbol: "fan")
            MetricPill(title: "Sensors", value: "\(store.panelSensors.count)", symbol: "sensor")
        }
    }

    @ViewBuilder
    private var warnings: some View {
        if !store.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Offsets keep identities unique even when two sources report
                // the same text.
                ForEach(Array(store.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var sensorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Sensors", systemImage: "thermometer.medium")
            SensorTableView(sensors: Array(store.panelSensors.prefix(18)), compact: true)
        }
    }

    private var fansSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fans", systemImage: "fan")
            if store.fans.isEmpty {
                Label("No controllable fan was reported by this Mac.", systemImage: "fan.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(store.fans) { fan in
                    CompactFanCard(fan: fan, drafts: drafts)
                }
            }
        }
    }

    private var presetsSection: some View {
        // Presets write hardware through Apply, so they follow the same helper
        // gate as the fan cards (for example, disabled while recovery is blocked).
        let blockReason = HelperControlGate.presetBlockReason(for: store.helperState)
        let presetsLocked = blockReason != nil || store.installingHelper
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Presets", systemImage: "dial.low")
            if store.presets.isEmpty {
                Text("No presets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(store.presets) { preset in
                        let isActive = store.activePresetName == preset.name
                        Button {
                            drafts.commit()
                            store.applyPreset(preset)
                        } label: {
                            Label(preset.name, systemImage: isActive ? "checkmark" : "dial.low")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? Color.accentColor : nil)
                        .disabled(presetsLocked)
                        .accessibilityHint("Applies the \(preset.name) preset to the detected fans.")
                    }
                }
                if let blockReason {
                    FanControlFootnote(text: blockReason)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }

            Spacer()

            Button {
                AppWindowBridge.showSettings?()
            } label: {
                Label("Preferences", systemImage: "slider.horizontal.3")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .padding(10)
    }

    private func thermalTint(for reading: ThermalSensor?) -> Color {
        guard let hottest = reading?.temperatureC else { return .blue }
        if hottest < 55 {
            return Color.green
        } else if hottest < 75 {
            return Color.yellow
        } else if hottest < 90 {
            return Color.orange
        } else {
            return Color.red
        }
    }
}

struct PreferencesView: View {
    @State private var selectedSection = SettingsSection.general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        Label(section.title, systemImage: section.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(selectedSection == section ? Color.accentColor : .primary)
                    .background(
                        selectedSection == section ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                }
                Spacer()
            }
            .frame(width: 150)
            .padding(12)

            Divider()

            selectedPane
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selectedSection {
        case .general: GeneralSettingsPane()
        case .sensors: SensorsSettingsPane()
        case .indexes: IndexesSettingsPane()
        case .fans: FansSettingsPane()
        case .presets: PresetsSettingsPane()
        case .menuBar: MenuBarSettingsPane()
        case .about: AboutSettingsPane()
        }
    }

    private enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case sensors
        case indexes
        case fans
        case presets
        case menuBar
        case about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .sensors: "Sensors"
            case .indexes: "Indexes"
            case .fans: "Fans"
            case .presets: "Presets"
            case .menuBar: "Menu Bar"
            case .about: "About"
            }
        }

        var systemImage: String {
            switch self {
            case .general: "gearshape"
            case .sensors: "sensor"
            case .indexes: "chart.line.uptrend.xyaxis"
            case .fans: "fan"
            case .presets: "dial.low"
            case .menuBar: "menubar.rectangle"
            case .about: "info.circle"
            }
        }
    }
}

struct GeneralSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        SettingsPage(title: "General", subtitle: "\(store.machine.modelIdentifier) · \(store.machine.osVersion)") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 16) {
                GridRow {
                    Text("Temperature")
                    Picker("Temperature", selection: Binding(
                        get: { store.preferences.temperatureUnit },
                        set: { unit in store.updatePreferences { $0.temperatureUnit = unit } }
                    )) {
                        Text("Celsius").tag(TemperatureUnit.celsius)
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                GridRow {
                    Text("Refresh")
                    HStack {
                        Slider(value: Binding(
                            get: { store.preferences.refreshInterval },
                            set: { interval in store.updatePreferences { $0.refreshInterval = interval } }
                        ), in: 1...60, step: 1) // Matches the store's 1-60 s clamp.
                        Text("\(Int(store.preferences.refreshInterval))s")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .frame(width: 280)
                }

                GridRow {
                    Text("Readings")
                    Toggle("Show estimated fallback", isOn: Binding(
                        get: { store.preferences.showEstimatedReadings },
                        set: { enabled in store.updatePreferences { $0.showEstimatedReadings = enabled } }
                    ))
                }

                GridRow {
                    Text("Dock")
                    Toggle("Show Dock icon", isOn: Binding(
                        get: { store.preferences.showDockIcon },
                        set: { enabled in store.updatePreferences { $0.showDockIcon = enabled } }
                    ))
                }

                GridRow {
                    Text("Startup")
                    Toggle("Launch at login", isOn: Binding(
                        get: { store.preferences.launchAtLogin },
                        set: { enabled in store.updatePreferences { $0.launchAtLogin = enabled } }
                    ))
                }

                GridRow {
                    Text("Hardware Helper")
                    HelperStatusRow()
                }
            }

            SystemSummaryView()
        }
    }
}

struct HelperStatusRow: View {
    @EnvironmentObject private var store: ThermalStore
    @State private var confirmingUnregister = false

    private static let readmeURL = URL(string: "https://github.com/girginomer10/thermofan-macos#build-and-install")!
    private static let unregisterableStates: Set<HardwareHelperState> = [.ready, .updateRequired, .recoveryBlocked]

    var body: some View {
        // A fan card's "… & Apply" may be registering the helper or writing
        // hardware right now; helper actions wait so the two never race.
        let fanOperationInFlight = !store.applyingFanIDs.isEmpty
        HStack(spacing: 10) {
            Image(systemName: helperSymbol)
                .foregroundStyle(helperTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(helperTitle)
                    .fontWeight(.medium)
                Text(helperDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.helperState == .monitoringOnly {
                    Link("README: Build and Install", destination: Self.readmeURL)
                        .font(.caption)
                }
            }
            Spacer(minLength: 8)
            if store.installingHelper {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    // Ready and the informational states have nothing to offer.
                    if store.helperState.isActionable {
                        Button {
                            performHelperAction()
                        } label: {
                            Label(helperActionTitle, systemImage: helperActionSymbol)
                        }
                        .disabled(fanOperationInFlight)
                    }
                    if Self.unregisterableStates.contains(store.helperState) {
                        Button(role: .destructive) {
                            confirmingUnregister = true
                        } label: {
                            Label("Unregister", systemImage: "xmark.shield")
                        }
                        .disabled(fanOperationInFlight)
                    }
                }
                .help(fanOperationInFlight ? "Wait for the current fan operation to finish." : "")
            }
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .leading)
        .confirmationDialog(
            "Unregister the Hardware Helper?",
            isPresented: $confirmingUnregister,
            titleVisibility: .visible
        ) {
            Button("Unregister", role: .destructive) {
                store.unregisterHelper()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ThermoFan first verifies that every fan is back in Auto, then asks macOS to remove the service. Fan control stays unavailable until you register the helper again.")
        }
    }

    private func performHelperAction() {
        switch store.helperState {
        case .recoveryBlocked:
            // Never re-registers the service or writes a manual target.
            store.retryAutomaticRecovery()
        case .unreachable:
            store.refreshHelperState()
        case .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired:
            store.installHelper()
        case .ready, .monitoringOnly, .wrongLocation, .inactiveSession:
            break
        }
    }

    private var helperTitle: String {
        switch store.helperState {
        case .missing: "Hardware Helper not registered"
        case .legacyCleanupRequired: "Legacy helper security upgrade required"
        case .approvalRequired: "Administrator approval required"
        case .updateRequired: "Hardware Helper update required"
        case .recoveryBlocked: "Hardware recovery requires attention"
        case .ready: "Hardware Helper ready"
        case .monitoringOnly: "Monitoring-only build"
        case .wrongLocation: "Move ThermoFan to Applications"
        case .inactiveSession: "Fan control belongs to the active user"
        case .unreachable: "Hardware Helper not responding"
        }
    }

    private var helperDetail: String {
        switch store.helperState {
        case .missing: "Register the signed macOS service once; no password is sent to ThermoFan."
        case .legacyCleanupRequired: "Approve migration now; manual writes stay blocked until the older privileged helper is revoked and removed."
        case .approvalRequired: "Approve ThermoFan in System Settings → General → Login Items, then retry."
        case .updateRequired: "Install the notarized app in Applications and re-register its authenticated service."
        case .recoveryBlocked: "\(HelperControlGate.recoveryBlockedFootnote) Use Retry Recovery."
        case .ready: "Authenticated fan writes, curve tracking, heartbeat, and crash recovery are available."
        case .monitoringOnly: "This build is not Developer ID signed, or its embedded helper payload is missing, so ThermoFan can only monitor. See the README's Build and Install section."
        case .wrongLocation: "Fan control needs the app at /Applications/ThermoFan.app. Move ThermoFan.app to /Applications, then relaunch it."
        case .inactiveSession: "The active console user owns fan control. Switch to that login session to change fans; this session can only monitor."
        case .unreachable: "The registered helper did not answer in time. It may be busy recovering; retry shortly."
        }
    }

    private var helperSymbol: String {
        switch store.helperState {
        case .missing: "lock.shield"
        case .legacyCleanupRequired: "exclamationmark.triangle.fill"
        case .approvalRequired: "person.badge.shield.checkmark"
        case .updateRequired: "exclamationmark.shield.fill"
        case .recoveryBlocked: "exclamationmark.triangle.fill"
        case .ready: "checkmark.shield.fill"
        case .monitoringOnly: "eye"
        case .wrongLocation: "folder.badge.questionmark"
        case .inactiveSession: "person.crop.circle.badge.xmark"
        case .unreachable: "clock.badge.exclamationmark"
        }
    }

    /// Only shown when `helperState.isActionable`.
    private var helperActionTitle: String {
        switch store.helperState {
        case .missing: "Register"
        case .legacyCleanupRequired: "Secure Upgrade"
        case .approvalRequired: "Open Settings"
        case .updateRequired: "Update"
        case .recoveryBlocked: "Retry Recovery"
        case .unreachable: "Retry"
        case .ready, .monitoringOnly, .wrongLocation, .inactiveSession: store.helperState.title
        }
    }

    private var helperActionSymbol: String {
        switch store.helperState {
        case .approvalRequired: "gear"
        case .legacyCleanupRequired: "lock.shield"
        case .recoveryBlocked: "arrow.uturn.backward.circle"
        case .unreachable: "arrow.clockwise"
        default: "arrow.down.circle"
        }
    }

    private var helperTint: Color {
        switch store.helperState {
        case .ready: .green
        case .monitoringOnly, .inactiveSession: .secondary
        default: .orange
        }
    }
}

struct SensorsSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        let hiddenCount = store.sensors.filter { $0.isHidden }.count
        let subtitle = hiddenCount > 0
            ? "\(store.sensors.count) sensors · \(hiddenCount) hidden"
            : "\(store.sensors.count) sensors"
        return SettingsPage(title: "Sensors", subtitle: subtitle) {
            HStack(spacing: 12) {
                TextField("Search", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Category", selection: Binding<SensorCategory?>(
                    get: { store.selectedCategory },
                    set: { store.selectedCategory = $0 }
                )) {
                    Text("All").tag(SensorCategory?.none)
                    ForEach(SensorCategory.allCases) { category in
                        Text(category.title).tag(Optional(category))
                    }
                }
                .frame(width: 160)
            }

            Text("Switch a sensor off to hide it from readouts and pickers. Hidden sensors stay listed here (dimmed) so you can switch them back on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SensorTableView(sensors: store.settingsSensors, compact: false)
                .frame(minHeight: 360)
        }
    }
}

struct IndexesSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        SettingsPage(title: "Indexes", subtitle: "\(store.customIndexes.count) custom") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    TextField("Index name", text: $store.newIndexName)
                        .textFieldStyle(.roundedBorder)
                    Picker("Mode", selection: $store.newIndexMode) {
                        ForEach(ThermalIndexMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .frame(width: 130)
                    Button {
                        store.createCustomIndex()
                    } label: {
                        Label("Create", systemImage: "plus")
                    }
                    .disabled(
                        store.newIndexName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.newIndexSensorIDs.isEmpty
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Source Sensors", systemImage: "sensor")
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                            ForEach(store.indexInputSensors) { sensor in
                                IndexSourceToggle(sensor: sensor)
                            }
                        }
                        .padding(2)
                    }
                    .frame(height: 220)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Custom Indexes", systemImage: "chart.line.uptrend.xyaxis")
                    if store.customIndexes.isEmpty {
                        EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "No custom indexes")
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(store.customIndexes) { index in
                                CustomIndexRow(index: index)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct IndexSourceToggle: View {
    @EnvironmentObject private var store: ThermalStore
    var sensor: ThermalSensor

    var body: some View {
        Toggle(isOn: Binding(
            get: { store.newIndexSensorIDs.contains(sensor.id) },
            set: { _ in store.toggleDraftIndexSensor(sensor.id) }
        )) {
            HStack(spacing: 8) {
                SensorIcon(category: sensor.category)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sensor.name)
                        .lineLimit(1)
                    Text(indexSourceDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var indexSourceDetail: String {
        let freshness = store.isSensorFresh(sensor) ? "" : " · Last reading"
        return "\(sensor.source.label) · \(SensorReadingCopy.value(sensor, unit: store.preferences.temperatureUnit))\(freshness)"
    }
}

struct CustomIndexRow: View {
    @EnvironmentObject private var store: ThermalStore
    var index: ThermalIndex

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(index.name)
                    .fontWeight(.medium)
                Text("\(index.mode.title) · \(index.sensorIDs.count) sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                store.deleteCustomIndex(index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct FansSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore
    /// Uncommitted numeric drafts in the fan cards on this page; Apply flushes
    /// them first so it never sends the previously staged value.
    @State private var drafts = FanDraftCommitRegistry()

    var body: some View {
        let controllableCount = store.fans.filter { $0.controlInterface.isAvailable }.count
        return SettingsPage(title: "Fans", subtitle: "\(controllableCount) controllable · \(store.fans.count) detected") {
            if store.fans.isEmpty {
                EmptyStateView(symbol: "fan.slash", title: "No controllable fan detected")
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.fans) { fan in
                            FullFanCard(fan: fan, drafts: drafts)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

struct PresetsSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        // Applying a preset writes hardware, so it follows the fan-card gate.
        let blockReason = HelperControlGate.presetBlockReason(for: store.helperState)
        let applyLocked = blockReason != nil || store.installingHelper
        return SettingsPage(title: "Presets", subtitle: store.activePresetName) {
            HStack {
                TextField("Preset name", text: $store.newPresetName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    store.savePreset()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .disabled(store.newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let blockReason {
                FanControlFootnote(text: blockReason)
            }

            if store.presets.isEmpty {
                EmptyStateView(symbol: "dial.low", title: "No presets")
            } else {
                List {
                    ForEach(store.presets) { preset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                    .fontWeight(.medium)
                                Text("\(preset.fanSettings.count) fan settings")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                            Button("Apply") {
                                store.applyPreset(preset)
                            }
                            .disabled(applyLocked)
                            Button(role: .destructive) {
                                store.deletePreset(preset)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct MenuBarSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        let selectedCount = store.preferences.menuSensorIDs.count
        let subtitle = selectedCount == 0
            ? "Showing hottest sensor (default) · up to 3 shown"
            : "\(selectedCount) selected · up to 3 shown"
        return SettingsPage(title: "Menu Bar", subtitle: subtitle) {
            Text("Pick which sensors appear in the menu bar. With none selected, the hottest sensor is shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(Array(store.sensors.filter { !$0.isHidden }), id: \.id) { sensor in
                    MenuSensorButton(
                        sensor: sensor,
                        selected: store.preferences.menuSensorIDs.contains(sensor.id)
                    )
                }
            }
        }
    }
}

struct MenuSensorButton: View {
    @EnvironmentObject private var store: ThermalStore
    var sensor: ThermalSensor
    var selected: Bool

    var body: some View {
        Button {
            store.toggleMenuSensor(sensor)
        } label: {
            HStack {
                SensorIcon(category: sensor.category)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SensorReadingCopy.name(sensor))
                        .italic(sensor.source == .estimated)
                        .lineLimit(1)
                    Text(sensor.source == .estimated ? "\(sensor.category.title) · Estimated" : sensor.category.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(!store.canToggleMenuSensor(sensor))
        .help(!selected && !store.canToggleMenuSensor(sensor) ? "Remove a selected sensor first (maximum 3)." : "")
    }
}

struct AboutSettingsPane: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        SettingsPage(title: "ThermoFan", subtitle: "Native macOS thermal monitor") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(width: 76, height: 76)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("ThermoFan")
                            .font(.title2.bold())
                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                        Text(store.machine.chipName)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                LabeledContent("Hardware Helper", value: store.helperState.title)
                LabeledContent("Data", value: "Stored locally")

                HStack(spacing: 16) {
                    Link(destination: URL(string: "https://github.com/girginomer10/thermofan-macos")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/girginomer10/thermofan-macos/issues")!) {
                        Label("Report an Issue", systemImage: "exclamationmark.bubble")
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
}

struct SensorTableView: View {
    @EnvironmentObject private var store: ThermalStore
    var sensors: [ThermalSensor]
    var compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sensor")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Temp")
                    .font(.caption.weight(.semibold))
                    .frame(width: 76, alignment: .trailing)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            if sensors.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: compact ? 60 : 120)
            } else {
                rows
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        )
    }

    private var emptyMessage: String {
        if compact {
            // The menu panel lists every unhidden sensor; it never follows
            // the Settings search or category filter.
            return store.sensors.isEmpty
                ? "No readable sensors on this Mac."
                : "All sensors are hidden. Show them in Settings → Sensors."
        }
        return store.searchText.isEmpty && store.selectedCategory == nil
            ? "No readable sensors on this Mac."
            : "No sensors match the current filter."
    }

    @ViewBuilder
    private var rows: some View {
        let content = LazyVStack(spacing: 0) {
            ForEach(Array(sensors.enumerated()), id: \.element.id) { index, sensor in
                SensorRow(sensor: sensor, index: index, compact: compact)
            }
        }
        // In the compact panel the whole StatusPanelView already scrolls, so
        // rendering rows inline (no inner ScrollView) avoids nested-scroll capture.
        if compact {
            content
        } else {
            ScrollView { content }
        }
    }
}

struct SensorRow: View {
    @EnvironmentObject private var store: ThermalStore
    var sensor: ThermalSensor
    var index: Int
    var compact: Bool

    private var isEstimated: Bool { sensor.source == .estimated }
    private var isStale: Bool { !store.isSensorFresh(sensor) }
    private var inMenuBar: Bool { store.preferences.menuSensorIDs.contains(sensor.id) }

    var body: some View {
        HStack(spacing: 8) {
            SensorIcon(category: sensor.category)
            VStack(alignment: .leading, spacing: 1) {
                Text(sensor.name)
                    .lineLimit(1)
                    .font(.system(size: compact ? 12 : 13, weight: sensor.isFavorite ? .semibold : .regular))
                if !compact {
                    Text(sensorDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text("\(isEstimated ? "~" : "")\(store.preferences.temperatureUnit.format(sensor.temperatureC))")
                .font(.system(size: compact ? 12 : 13, weight: .semibold, design: .rounded))
                .italic(isEstimated)
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
                .foregroundStyle(isStale ? Color.secondary : Color.primary)
                .help(temperatureHelp)

            if !compact {
                Button {
                    store.toggleFavorite(sensor)
                } label: {
                    Image(systemName: sensor.isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(sensor.isFavorite ? "Remove favorite" : "Mark favorite")
                .help(sensor.isFavorite ? "Remove favorite" : "Mark favorite")

                Button {
                    store.toggleMenuSensor(sensor)
                } label: {
                    Image(systemName: inMenuBar ? "menubar.rectangle" : "menubar.dock.rectangle")
                        .foregroundStyle(inMenuBar ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                // A hidden sensor is excluded from every readout, so it cannot
                // be added to the menu bar until it is shown again.
                .disabled(!store.canToggleMenuSensor(sensor) || (sensor.isHidden && !inMenuBar))
                .accessibilityLabel(inMenuBar ? "Remove from menu bar" : "Show in menu bar")
                .help(menuBarHelp)

                Toggle("Visible", isOn: Binding(
                    get: { !sensor.isHidden },
                    set: { store.setHidden(sensor, hidden: !$0) }
                ))
                .labelsHidden()
                .accessibilityLabel(sensor.isHidden ? "Hidden — switch on to show" : "Visible — switch off to hide")
                .help("Show or hide this sensor")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, compact ? 5 : 7)
        .opacity(sensor.isHidden ? 0.5 : 1)
        .background(index.isMultiple(of: 2) ? Color(nsColor: .textBackgroundColor).opacity(0.24) : Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var menuBarHelp: String {
        if sensor.isHidden && !inMenuBar {
            return "Show this sensor before adding it to the menu bar."
        }
        return inMenuBar ? "Remove from menu bar" : "Show in menu bar"
    }

    private var sensorDetail: String {
        if sensor.isHidden {
            return "\(sensor.source.label) · Hidden"
        }
        return isStale ? "\(sensor.source.label) · Last reading" : sensor.source.label
    }

    private var temperatureHelp: String {
        if isEstimated {
            return "Estimated reading; hardware sensor data was unavailable."
        }
        if isStale {
            return "The SMC key is temporarily unavailable; showing its last valid reading."
        }
        return ""
    }
}

struct CompactFanCard: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice
    /// Page-level draft registry; Apply commits this fan's drafts first.
    var drafts: FanDraftCommitRegistry?

    private var isEstimated: Bool { fan.source == .estimated }
    /// The firmware exposes a verified write surface for this fan.
    private var hasVerifiedControl: Bool { !isEstimated && fan.controlInterface.isAvailable }
    private var gate: HelperControlGate { HelperControlGate(store.helperState) }
    /// Staging and applying are allowed: the fan is writable and the helper is
    /// ready, or Apply can register, approve, update, or upgrade it first.
    private var isControllable: Bool { hasVerifiedControl && gate == .open }
    /// While recovery is blocked the controls stay visible (so the staged
    /// configuration can be reviewed) but locked.
    private var showsControls: Bool { hasVerifiedControl && (gate == .open || gate == .recoveryBlocked) }
    private var isApplying: Bool { store.applyingFanIDs.contains(fan.id) }
    private var editingLocked: Bool { isApplying || !isControllable }
    private var hardwareOperationInFlight: Bool { store.installingHelper || !store.applyingFanIDs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(fan.name, systemImage: "fan")
                    .fontWeight(.semibold)
                Spacer()
                Text("\(isEstimated ? "~" : "")\(fan.currentRPM) RPM")
                    .monospacedDigit()
                    .italic(isEstimated)
                    .fontWeight(.semibold)
            }

            if !hasVerifiedControl {
                FanMonitoringOnlyNotice(fan: fan, compact: true, isRecovering: isApplying)
                if gate == .recoveryBlocked && !isEstimated {
                    FanRecoveryButton(title: "Retry Recovery", isRunning: isApplying, isDisabled: hardwareOperationInFlight)
                        .controlSize(.small)
                }
            } else if !showsControls {
                FanHelperUnavailableNotice(fan: fan, helperState: store.helperState, compact: true)
                if gate == .unreachable {
                    Button {
                        store.refreshHelperState()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.installingHelper)
                }
            } else {
                FanControlStatusLine(
                    fan: fan,
                    isApplying: isApplying,
                    isRecovering: isApplying && gate == .recoveryBlocked,
                    tracksAppliedCurve: store.trackedCurveFanIDs.contains(fan.id),
                    helperState: store.helperState
                )

                Picker("Mode", selection: Binding(
                    get: { fan.mode },
                    set: { store.setFanMode(fan.id, mode: $0) }
                )) {
                    ForEach(FanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingLocked)

                switch fan.mode {
                case .automatic:
                    Text(FanHardwareCopy.autoModeCaption(fan, compact: true))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .fixed:
                    HStack {
                        Slider(value: Binding(
                            get: { Double(fan.targetRPM) },
                            set: { store.setFanTarget(fan.id, rpm: Int($0.rounded())) }
                        ), in: Double(fan.minRPM)...Double(fan.maxRPM), step: 50)
                        .accessibilityLabel("Fixed RPM")
                        FanTargetRPMField(fan: fan, drafts: drafts)
                            .frame(width: 70)
                    }
                    .disabled(editingLocked)
                case .curve:
                    LinkedSensorPicker(fan: fan)
                        .disabled(editingLocked)
                    CurveEditor(fan: fan, compact: true, drafts: drafts)
                        .disabled(editingLocked)
                }

                if gate == .recoveryBlocked {
                    // The only permitted action: never Apply or Auto, which
                    // would go through registration and a manual write path.
                    FanControlFootnote(text: HelperControlGate.recoveryBlockedFootnote)
                    FanRecoveryButton(title: "Retry Recovery", isRunning: isApplying, isDisabled: hardwareOperationInFlight)
                        .controlSize(.small)
                } else {
                    HStack {
                        Button {
                            drafts?.commit(scope: fan.id)
                            store.applyFanWithAdmin(fan.id)
                        } label: {
                            if isApplying {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(applyButtonTitle, systemImage: store.helperInstalled ? "checkmark.circle" : "key")
                            }
                        }
                        .disabled(isApplying || store.installingHelper)
                        .buttonStyle(.borderedProminent)
                        Button {
                            store.resetFanToAutomatic(fan.id)
                        } label: {
                            Label("Auto", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isApplying || store.installingHelper || (fan.mode == .automatic && fan.hardwareMode == .automatic))
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.small)
                }
            }

            if let command = FanHardwareCopy.visibleCommand(fan, showsControls: showsControls) {
                Label(command, systemImage: FanHardwareCopy.commandSymbol(fan, helperState: store.helperState))
                    .font(.caption2)
                    .foregroundStyle(FanHardwareCopy.commandTint(fan, helperState: store.helperState))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var applyButtonTitle: String {
        switch store.helperState {
        case .missing: "Install & Apply"
        case .legacyCleanupRequired: "Secure Upgrade & Apply"
        case .approvalRequired: "Approve & Apply"
        case .updateRequired: "Update & Apply"
        case .ready: fan.controlState == .failed ? "Retry" : "Apply"
        // Never shown: these states render recovery, retry, or an
        // informational notice instead of Apply.
        case .recoveryBlocked, .monitoringOnly, .wrongLocation, .inactiveSession, .unreachable: "Apply"
        }
    }
}

struct FullFanCard: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice
    /// Page-level draft registry; Apply commits this fan's drafts first.
    var drafts: FanDraftCommitRegistry?

    private var isEstimated: Bool { fan.source == .estimated }
    /// The firmware exposes a verified write surface for this fan.
    private var hasVerifiedControl: Bool { !isEstimated && fan.controlInterface.isAvailable }
    private var gate: HelperControlGate { HelperControlGate(store.helperState) }
    /// Staging and applying are allowed: the fan is writable and the helper is
    /// ready, or Apply can register, approve, update, or upgrade it first.
    private var isControllable: Bool { hasVerifiedControl && gate == .open }
    /// While recovery is blocked the controls stay visible (so the staged
    /// configuration can be reviewed) but locked.
    private var showsControls: Bool { hasVerifiedControl && (gate == .open || gate == .recoveryBlocked) }
    private var isApplying: Bool { store.applyingFanIDs.contains(fan.id) }
    private var editingLocked: Bool { isApplying || !isControllable }
    private var hardwareOperationInFlight: Bool { store.installingHelper || !store.applyingFanIDs.isEmpty }
    private var tracksAppliedCurve: Bool { store.trackedCurveFanIDs.contains(fan.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(fan.name, systemImage: "fan.fill")
                        .font(.headline)
                    Text("\(fan.source.label) · \(fan.minRPM)-\(fan.maxRPM) RPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(isEstimated ? "~" : "")\(fan.currentRPM) RPM")
                        .font(.title3.bold())
                        .italic(isEstimated)
                        .monospacedDigit()
                    Text(targetSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(targetAccessibilitySummary)
                }
            }

            if !hasVerifiedControl {
                FanMonitoringOnlyNotice(fan: fan, compact: false, isRecovering: isApplying)
                if gate == .recoveryBlocked && !isEstimated {
                    FanRecoveryButton(title: "Retry Automatic Recovery", isRunning: isApplying, isDisabled: hardwareOperationInFlight)
                }
            } else if !showsControls {
                FanHelperUnavailableNotice(fan: fan, helperState: store.helperState, compact: false)
                if gate == .unreachable {
                    Button {
                        store.refreshHelperState()
                    } label: {
                        Label("Retry Helper", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.installingHelper)
                }
            } else {
                FanControlStatusLine(
                    fan: fan,
                    isApplying: isApplying,
                    isRecovering: isApplying && gate == .recoveryBlocked,
                    tracksAppliedCurve: tracksAppliedCurve,
                    helperState: store.helperState
                )

                Picker("Mode", selection: Binding(
                    get: { fan.mode },
                    set: { store.setFanMode(fan.id, mode: $0) }
                )) {
                    ForEach(FanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editingLocked)

                switch fan.mode {
                case .automatic:
                    Text(FanHardwareCopy.autoModeCaption(fan, compact: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .fixed:
                    VStack(alignment: .leading) {
                        Text("Fixed RPM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Slider(value: Binding(
                                get: { Double(fan.targetRPM) },
                                set: { store.setFanTarget(fan.id, rpm: Int($0.rounded())) }
                            ), in: Double(fan.minRPM)...Double(fan.maxRPM), step: 50)
                            .accessibilityLabel("Fixed RPM")
                            FanTargetRPMField(fan: fan, drafts: drafts)
                                .frame(width: 82)
                        }
                    }
                    .disabled(editingLocked)
                case .curve:
                    VStack(alignment: .leading) {
                        Text("Linked Sensor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LinkedSensorPicker(fan: fan)
                            .frame(width: 230)
                    }
                    .disabled(editingLocked)
                    CurveEditor(fan: fan, drafts: drafts)
                        .disabled(editingLocked)
                }

                if gate == .recoveryBlocked {
                    // The only permitted action: never Apply or Return to Auto,
                    // which would go through registration and a manual write path.
                    FanControlFootnote(text: HelperControlGate.recoveryBlockedFootnote)
                    FanRecoveryButton(title: "Retry Automatic Recovery", isRunning: isApplying, isDisabled: hardwareOperationInFlight)
                } else {
                    HStack {
                        Button {
                            drafts?.commit(scope: fan.id)
                            store.applyFanWithAdmin(fan.id)
                        } label: {
                            if isApplying {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Applying…")
                                }
                            } else {
                                Label(applyButtonTitle, systemImage: store.helperInstalled ? "checkmark.circle" : "key")
                            }
                        }
                        .disabled(isApplying || store.installingHelper)
                        .buttonStyle(.borderedProminent)
                        Button {
                            store.resetFanToAutomatic(fan.id)
                        } label: {
                            Label("Return to Auto", systemImage: "arrow.uturn.backward")
                        }
                        .disabled(isApplying || store.installingHelper || (fan.mode == .automatic && fan.hardwareMode == .automatic))
                        .buttonStyle(.bordered)
                    }

                    if fan.mode == .curve {
                        Label(curveFootnote, systemImage: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let command = FanHardwareCopy.visibleCommand(fan, showsControls: showsControls) {
                Label(command, systemImage: FanHardwareCopy.commandSymbol(fan, helperState: store.helperState))
                    .font(.caption)
                    .foregroundStyle(FanHardwareCopy.commandTint(fan, helperState: store.helperState))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Staged targets are labelled as such; otherwise the hardware's raw
    /// target register is shown as read, never the staged value.
    private var targetSummary: String {
        let staged = fan.controlState == .pending
        switch (showsControls, fan.mode) {
        case (true, .fixed):
            return staged ? "Staged fixed target \(fan.targetRPM)" : "Fixed target \(fan.targetRPM)"
        case (true, .curve):
            return staged ? "Staged curve target \(fan.targetRPM)" : "Curve target \(fan.targetRPM)"
        default:
            return fan.hardwareTargetRPM.map { "Hardware target \($0) (raw)" } ?? "Hardware target unknown"
        }
    }

    private var targetAccessibilitySummary: String {
        switch (showsControls, fan.mode) {
        case (true, .fixed), (true, .curve):
            return targetSummary
        default:
            return fan.hardwareTargetRPM.map { "Raw hardware target register \($0) RPM" } ?? "Hardware target unknown"
        }
    }

    private var curveFootnote: String {
        if tracksAppliedCurve && fan.controlState == .pending {
            return "The applied curve keeps tracking temperature; your edits take effect only after you apply them."
        }
        return "With the helper installed, a curve keeps tracking temperature automatically after you apply it once."
    }

    private var applyButtonTitle: String {
        switch store.helperState {
        case .missing: "Install Helper & Apply"
        case .legacyCleanupRequired: "Secure Upgrade & Apply"
        case .approvalRequired: "Approve Helper & Apply"
        case .updateRequired: "Update Helper & Apply"
        case .ready: fan.controlState == .failed ? "Retry Hardware Write" : "Apply to Hardware"
        // Never shown: these states render recovery, retry, or an
        // informational notice instead of Apply.
        case .recoveryBlocked, .monitoringOnly, .wrongLocation, .inactiveSession, .unreachable: "Apply to Hardware"
        }
    }
}

/// Headline for a controllable fan. It is derived from both the app's control
/// state and the mode read back from hardware, so it never claims manual
/// control the hardware does not report.
struct FanControlStatusLine: View {
    var fan: FanDevice
    var isApplying: Bool
    /// The in-flight operation is automatic recovery, not a manual write.
    var isRecovering = false
    /// The applied curve is still tracking temperature (store-owned).
    var tracksAppliedCurve = false
    var helperState: HardwareHelperState = .ready

    var body: some View {
        let status = self.status
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(status.title, systemImage: status.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if status.showsHardwareSummary {
                FanHardwareSummaryText(fan: fan)
            }
        }
    }

    private struct Status {
        var title: String
        var symbol: String
        var tint: Color
        var showsHardwareSummary = true
    }

    private var status: Status {
        if isApplying {
            return isRecovering
                ? Status(title: "Recovering…", symbol: "arrow.uturn.backward.circle", tint: .orange)
                : Status(title: "Applying…", symbol: "arrow.triangle.2.circlepath", tint: .blue)
        }
        switch fan.controlState {
        case .pending:
            if tracksAppliedCurve {
                return Status(
                    title: "Curve tracking active (applied curve) · edits pending — Apply to use the new curve",
                    symbol: "clock",
                    tint: .orange
                )
            }
            return Status(title: "Changes pending", symbol: "clock", tint: .orange)
        case .failed:
            // "Approve & Apply" stops at macOS approval; nothing was written.
            if helperState == .approvalRequired {
                return Status(title: "Approval pending", symbol: "person.badge.shield.checkmark", tint: .orange)
            }
            return Status(title: "Write failed", symbol: "xmark.octagon.fill", tint: .red)
        case .active:
            switch fan.hardwareMode {
            case .automatic?:
                return Status(title: "Hardware returned to Auto", symbol: "exclamationmark.triangle.fill", tint: .orange)
            case nil:
                return Status(title: "Hardware: unknown", symbol: "questionmark.circle", tint: .orange, showsHardwareSummary: false)
            case .fixed?, .curve?:
                if fan.mode == .curve {
                    return Status(
                        title: tracksAppliedCurve ? "Curve tracking active" : "Curve active",
                        symbol: "checkmark.shield.fill",
                        tint: .green
                    )
                }
                return Status(title: "Manual control active", symbol: "checkmark.shield.fill", tint: .green)
            }
        case .idle:
            switch fan.hardwareMode {
            case .automatic?:
                return Status(title: "macOS control", symbol: "checkmark.circle", tint: .green)
            case nil:
                return Status(title: "Hardware: unknown", symbol: "questionmark.circle", tint: .secondary, showsHardwareSummary: false)
            case .fixed?, .curve?:
                return Status(title: "Hardware reports manual control", symbol: "exclamationmark.triangle", tint: .orange)
            }
        }
    }
}

/// Curve source picker. "Hottest sensor" stays a nil link that the store
/// re-evaluates on every sample. The currently linked sensor is always listed,
/// even when hidden or gone, so the selection keeps a matching tag.
struct LinkedSensorPicker: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice

    var body: some View {
        Picker("Linked Sensor", selection: Binding<String>(
            get: { fan.linkedSensorID ?? "" },
            set: { store.setLinkedSensor(fan.id, sensorID: $0.isEmpty ? nil : $0) }
        )) {
            Text("Hottest sensor").tag("")
            ForEach(options, id: \.id) { option in
                Text(option.title)
                    .italic(option.isEstimated)
                    .tag(option.id)
            }
        }
        .labelsHidden()
    }

    private struct Option {
        var id: String
        var title: String
        var isEstimated: Bool
    }

    private var options: [Option] {
        var result = store.curveSourceSensors.map(Self.option(for:))
        guard
            let linkedID = fan.linkedSensorID,
            !linkedID.isEmpty,
            !result.contains(where: { $0.id == linkedID })
        else {
            return result
        }
        if let linked = store.sensors.first(where: { $0.id == linkedID }) {
            var option = Self.option(for: linked)
            if linked.isHidden {
                option.title += " (hidden)"
            }
            result.append(option)
        } else {
            result.append(Option(id: linkedID, title: "Unavailable sensor", isEstimated: false))
        }
        return result
    }

    private static func option(for sensor: ThermalSensor) -> Option {
        let base = sensor.source == .index ? "\(sensor.name) · Index" : sensor.name
        let isEstimated = sensor.source == .estimated
        return Option(id: sensor.id, title: isEstimated ? "~\(base)" : base, isEstimated: isEstimated)
    }
}

/// How much of a fan card's control surface the current helper state allows.
private enum HelperControlGate {
    /// The helper is ready, or registration, approval, update, or the legacy
    /// security upgrade can run as part of "… & Apply".
    case open
    /// Automatic control must be re-verified; retrying automatic recovery is
    /// the only permitted action and every manual control is locked.
    case recoveryBlocked
    /// The registered helper did not answer; the only action is re-checking it.
    case unreachable
    /// This build, location, or login session cannot control fans at all.
    case unavailable

    init(_ state: HardwareHelperState) {
        switch state {
        case .ready, .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired:
            self = .open
        case .recoveryBlocked:
            self = .recoveryBlocked
        case .unreachable:
            self = .unreachable
        case .monitoringOnly, .wrongLocation, .inactiveSession:
            self = .unavailable
        }
    }

    static let recoveryBlockedFootnote = "Manual control is disabled until automatic control is verified. Do not retry manual control."

    /// One-line reason for hidden or locked fan controls; nil when open.
    static func reason(for state: HardwareHelperState) -> String? {
        switch state {
        case .ready, .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired:
            return nil
        case .recoveryBlocked:
            return recoveryBlockedFootnote
        case .unreachable:
            return "Fan controls are paused: the Hardware Helper is not responding."
        case .monitoringOnly:
            return "Monitoring-only build (not Developer ID signed or missing its helper). See the README."
        case .wrongLocation:
            return "Move ThermoFan.app to /Applications and relaunch it to control fans."
        case .inactiveSession:
            return "The active console user owns fan control; this session can only monitor."
        }
    }

    /// Presets write hardware through Apply, so they follow the same gate.
    static func presetBlockReason(for state: HardwareHelperState) -> String? {
        HelperControlGate(state) == .open ? nil : reason(for: state)
    }
}

/// Copy derived from what the hardware reports. A nil `hardwareMode` is
/// unknown, never manual, and `hardwareTargetRPM` is the raw register value.
private enum FanHardwareCopy {
    static func modeTitle(_ fan: FanDevice) -> String {
        switch fan.hardwareMode {
        case .automatic?: return "Auto"
        case .fixed?, .curve?: return "Manual"
        case nil: return "unknown"
        }
    }

    static func summary(_ fan: FanDevice) -> String {
        switch fan.hardwareMode {
        case .automatic?:
            return "Hardware: Auto"
        case .fixed?, .curve?:
            return fan.hardwareTargetRPM.map { "Hardware: Manual · \($0) RPM" } ?? "Hardware: Manual"
        case nil:
            return "Hardware: unknown"
        }
    }

    static func accessibilitySummary(_ fan: FanDevice) -> String {
        switch fan.hardwareMode {
        case .automatic?:
            return "Hardware mode automatic"
        case .fixed?, .curve?:
            return fan.hardwareTargetRPM.map { "Hardware mode manual, raw target register \($0) RPM" }
                ?? "Hardware mode manual, raw target unknown"
        case nil:
            return "Hardware mode unknown"
        }
    }

    static func autoModeCaption(_ fan: FanDevice, compact: Bool) -> String {
        switch fan.hardwareMode {
        case .automatic?:
            return "macOS is controlling this fan."
        case nil:
            return "Auto is selected; the hardware mode could not be read."
        case .fixed?, .curve?:
            return compact
                ? "Auto is selected but has not reached the hardware yet."
                : "Auto is selected, but the hardware still reports manual control."
        }
    }

    static func monitoringReason(_ fan: FanDevice, compact: Bool) -> String {
        if fan.source == .estimated {
            return compact
                ? "No controllable fan was detected on this Mac; values are estimated."
                : "No controllable fan was detected on this Mac. Values above are estimated."
        }
        return compact
            ? "This firmware exposes no verified fan-control interface."
            : "RPM telemetry is readable, but this firmware exposes no verified fan-control interface. No hardware writes will be attempted."
    }

    /// Staging and applying messages only make sense next to the controls.
    /// Where controls are hidden, keep only failures, which stay informative.
    static func visibleCommand(_ fan: FanDevice, showsControls: Bool) -> String? {
        guard let command = fan.lastCommand else { return nil }
        return showsControls || fan.controlState == .failed ? command : nil
    }

    /// A failed "Approve & Apply" is waiting for macOS approval, not a write.
    private static func awaitsApproval(_ fan: FanDevice, helperState: HardwareHelperState) -> Bool {
        fan.controlState == .failed && helperState == .approvalRequired
    }

    static func commandSymbol(_ fan: FanDevice, helperState: HardwareHelperState) -> String {
        if awaitsApproval(fan, helperState: helperState) { return "person.badge.shield.checkmark" }
        switch fan.controlState {
        case .failed: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .active: return "checkmark.circle.fill"
        case .idle: return "info.circle"
        }
    }

    static func commandTint(_ fan: FanDevice, helperState: HardwareHelperState) -> Color {
        if awaitsApproval(fan, helperState: helperState) { return .orange }
        switch fan.controlState {
        case .failed: return .red
        case .pending: return .orange
        case .active: return .green
        case .idle: return .secondary
        }
    }
}

/// "Hardware: Auto / Manual · N RPM / unknown", where N is the raw target
/// register read back from the fan controller, never the staged target.
private struct FanHardwareSummaryText: View {
    var fan: FanDevice

    var body: some View {
        Text(FanHardwareCopy.summary(fan))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
            .accessibilityLabel(FanHardwareCopy.accessibilitySummary(fan))
            .help("Mode and raw target register read back from the fan controller.")
    }
}

/// Replaces the controls of a fan without a verified write surface.
private struct FanMonitoringOnlyNotice: View {
    var fan: FanDevice
    var compact: Bool
    /// Only automatic recovery can be in flight for a fan without a verified
    /// control interface; the store never starts a manual write for one.
    var isRecovering: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Monitoring only · Hardware: \(FanHardwareCopy.modeTitle(fan))", systemImage: "eye")
                .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
            Text(FanHardwareCopy.monitoringReason(fan, compact: compact))
                .font(compact ? .caption2 : .caption)
                .fixedSize(horizontal: false, vertical: true)
            if isRecovering {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Recovering…")
                        .font(.caption)
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// Replaces the controls when the helper state rules out fan control.
private struct FanHelperUnavailableNotice: View {
    var fan: FanDevice
    var helperState: HardwareHelperState
    var compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(
                HelperControlGate.reason(for: helperState) ?? "Fan control is unavailable.",
                systemImage: helperState == .unreachable ? "clock.badge.exclamationmark" : "lock"
            )
            .font(compact ? .caption : .callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            FanHardwareSummaryText(fan: fan)
        }
    }
}

private struct FanControlFootnote: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The only fan action while automatic control is unverified. It asks the
/// helper to retry verified automatic recovery and never writes a manual
/// target or touches the service registration.
private struct FanRecoveryButton: View {
    @EnvironmentObject private var store: ThermalStore
    var title: String
    var isRunning: Bool
    var isDisabled: Bool

    var body: some View {
        Button {
            store.retryAutomaticRecovery()
        } label: {
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Recovering…")
                }
            } else {
                Label(title, systemImage: "arrow.uturn.backward.circle")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isDisabled)
        .help("Asks the Hardware Helper to verify automatic control again. No manual target is written.")
    }
}

/// Estimated readings always carry a "~" prefix (and italics, applied by the
/// caller) so they never pass for a measured SMC or HID value.
private enum SensorReadingCopy {
    static func value(_ sensor: ThermalSensor, unit: TemperatureUnit) -> String {
        "\(sensor.source == .estimated ? "~" : "")\(unit.format(sensor.temperatureC))"
    }

    static func name(_ sensor: ThermalSensor) -> String {
        sensor.source == .estimated ? "~\(sensor.name)" : sensor.name
    }
}

struct CurveEditor: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice
    var compact = false
    /// Page-level registry that Apply and presets flush before they read the
    /// store, so a typed but uncommitted point is never skipped.
    var drafts: FanDraftCommitRegistry?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Curve")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // While edits are pending this is the new curve's target; an
                // applied curve may still be tracking with its own target.
                Text(fan.controlState == .pending ? "Staged target \(fan.targetRPM) RPM" : "Target \(fan.targetRPM) RPM")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    store.addCurvePoint(fanID: fan.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(!store.canAddCurvePoint(fanID: fan.id))
                .help(store.canAddCurvePoint(fanID: fan.id) ? "Add curve point" : "Maximum 8 curve points")
            }

            FanCurveGraph(fan: fan)
                .frame(height: compact ? 150 : 180)

            if compact {
                compactPointEditor
            } else {
                fullPointEditor
            }
        }
    }

    private var sortedPoints: [FanCurvePoint] {
        fan.curve.sorted { $0.temperatureC < $1.temperatureC }
    }

    private var compactPointEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Text(store.preferences.temperatureUnit.degreeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text("RPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 68, alignment: .leading)
                Color.clear.frame(width: 24, height: 1)
            }

            ForEach(sortedPoints) { point in
                GridRow {
                    temperatureField(for: point)
                        .frame(width: 48)
                    rpmField(for: point)
                        .frame(width: 68)
                    removePointButton(point)
                }
            }
        }
    }

    private var fullPointEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text(store.preferences.temperatureUnit.degreeLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Color.clear.frame(height: 1)
                Text("RPM")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 78, alignment: .leading)
                Color.clear.frame(height: 1)
                Color.clear.frame(width: 24, height: 1)
            }

            ForEach(sortedPoints) { point in
                GridRow {
                    temperatureField(for: point)
                        .frame(width: 58)
                    Slider(value: Binding(
                        get: { point.temperatureC },
                        set: { store.updateCurvePoint(fanID: fan.id, pointID: point.id, temperature: $0) }
                    ), in: 30...110, step: 1)
                    rpmField(for: point)
                        .frame(width: 78)
                    Slider(value: Binding(
                        get: { Double(point.rpm) },
                        set: { store.updateCurvePoint(fanID: fan.id, pointID: point.id, rpm: Int($0.rounded())) }
                    ), in: Double(fan.minRPM)...Double(fan.maxRPM), step: 50)
                    removePointButton(point)
                }
            }
        }
    }

    private func temperatureField(for point: FanCurvePoint) -> some View {
        let unit = store.preferences.temperatureUnit
        return StagedNumberField(
            placeholder: unit.degreeLabel,
            value: formattedTemperature(unit.toDisplay(point.temperatureC)),
            drafts: drafts,
            draftScope: fan.id
        ) { input in
            guard
                let entered = FanNumericInput.decimal(input),
                let current = editablePoint(point.id)
            else { return nil }
            // Re-committing an unchanged value must not re-stage the fan.
            if formattedTemperature(entered) != formattedTemperature(unit.toDisplay(current.temperatureC)) {
                store.updateCurvePoint(
                    fanID: fan.id,
                    pointID: point.id,
                    temperature: unit.toCelsius(entered)
                )
            }
            return editablePoint(point.id).map { formattedTemperature(unit.toDisplay($0.temperatureC)) }
        }
    }

    private func rpmField(for point: FanCurvePoint) -> some View {
        StagedNumberField(
            placeholder: "RPM",
            value: String(point.rpm),
            drafts: drafts,
            draftScope: fan.id
        ) { input in
            guard
                let entered = FanNumericInput.rpm(input),
                let live = store.fans.first(where: { $0.id == fan.id }),
                let current = editablePoint(point.id)
            else { return nil }
            let rpm = Int(min(Double(live.maxRPM), max(Double(live.minRPM), entered)).rounded())
            if rpm != current.rpm {
                store.updateCurvePoint(fanID: fan.id, pointID: point.id, rpm: rpm)
            }
            return editablePoint(point.id).map { String($0.rpm) }
        }
    }

    /// The live point, but only while this fan is still an editable curve. A
    /// draft left behind by a mode switch, a preset, a removed point, or a
    /// recovery lock is discarded instead of turning the fan back into a curve.
    private func editablePoint(_ pointID: UUID) -> FanCurvePoint? {
        guard
            store.helperState != .recoveryBlocked,
            let live = store.fans.first(where: { $0.id == fan.id }),
            live.mode == .curve
        else { return nil }
        return live.curve.first { $0.id == pointID }
    }

    private func formattedTemperature(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    private func removePointButton(_ point: FanCurvePoint) -> some View {
        Button {
            store.removeCurvePoint(fanID: fan.id, pointID: point.id)
        } label: {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .disabled(fan.curve.count <= 2)
    }
}

/// Fixed-target RPM entry. Its draft is committed by Apply before the store
/// reads the target, and discarded if the fan has left Fixed mode meanwhile.
private struct FanTargetRPMField: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice
    var drafts: FanDraftCommitRegistry?

    var body: some View {
        StagedNumberField(
            placeholder: "RPM",
            value: String(fan.targetRPM),
            drafts: drafts,
            draftScope: fan.id
        ) { input in
            guard
                store.helperState != .recoveryBlocked,
                let requested = FanNumericInput.rpm(input),
                let live = store.fans.first(where: { $0.id == fan.id }),
                live.mode == .fixed
            else { return nil }
            let rpm = Int(min(Double(live.maxRPM), max(Double(live.minRPM), requested)).rounded())
            // Re-committing an unchanged value must not re-stage the fan.
            if rpm != live.targetRPM {
                store.setFanTarget(fan.id, rpm: rpm)
            }
            return store.fans.first(where: { $0.id == fan.id }).map { String($0.targetRPM) }
        }
        .accessibilityLabel("Fixed RPM")
    }
}

/// A numeric field with a local text draft. SwiftUI's value-based TextField
/// writes through on every keystroke, so deleting the old number briefly
/// produces an invalid value and the model immediately restores it. Keeping a
/// draft lets people clear, replace, and correct the whole value naturally.
///
/// The draft is validated and committed on Return, when focus leaves the
/// field, when the field disappears (a Settings page switch or closing the
/// panel), and, through `FanDraftCommitRegistry`, right before Apply or a
/// preset. Clicking a button does not take focus from the text field, so
/// relying on focus loss alone would apply the previously staged value.
private struct StagedNumberField: View {
    let placeholder: String
    let value: String
    var drafts: FanDraftCommitRegistry?
    /// Fan ID used to flush only this fan's drafts on Apply.
    var draftScope = ""
    /// Validates and stores the input, returning the normalized value the
    /// store now holds, or nil to reject (and revert) the draft.
    let onCommit: (String) -> String?

    @State private var draft = ""
    @State private var lastCommittedValue = ""
    @State private var token = UUID()
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($isFocused)
            .onAppear {
                draft = value
                lastCommittedValue = value
            }
            .onChange(of: value) { _, newValue in
                // Our own commit already recorded this value. Any other change
                // (slider, graph drag, preset, unit switch) wins over an
                // in-progress draft, which is then dropped.
                if isFocused && newValue == lastCommittedValue { return }
                drafts?.clear(token)
                draft = newValue
                lastCommittedValue = newValue
            }
            .onChange(of: draft) { _, newDraft in
                guard isFocused else { return }
                if newDraft.trimmingCharacters(in: .whitespacesAndNewlines) == lastCommittedValue {
                    drafts?.clear(token)
                } else {
                    drafts?.stage(token, scope: draftScope) { commit(newDraft) }
                }
            }
            .onSubmit { commit(draft) }
            .onChange(of: isFocused) { wasFocused, focused in
                if wasFocused && !focused {
                    commit(draft)
                }
            }
            .onDisappear {
                // Keep an uncommitted edit across Settings page switches and
                // panel closes; `onCommit` discards it if the fan's mode changed.
                commit(draft)
            }
    }

    private func commit(_ text: String) {
        drafts?.clear(token)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastCommittedValue else {
            if draft != lastCommittedValue {
                draft = lastCommittedValue
            }
            return
        }
        guard !trimmed.isEmpty, let committed = onCommit(trimmed) else {
            draft = lastCommittedValue
            return
        }
        draft = committed
        lastCommittedValue = committed
    }
}

/// Numeric drafts that have been typed but not committed yet, so Apply or a
/// preset can commit them synchronously before it reads the store.
@MainActor
final class FanDraftCommitRegistry {
    private struct Entry {
        var scope: String
        var commit: @MainActor () -> Void
    }

    private var entries: [UUID: Entry] = [:]

    nonisolated init() {}

    func stage(_ token: UUID, scope: String, commit: @escaping @MainActor () -> Void) {
        entries[token] = Entry(scope: scope, commit: commit)
    }

    func clear(_ token: UUID) {
        entries[token] = nil
    }

    /// Commits the drafts staged for one fan, or every staged draft when
    /// `scope` is nil. Each field validates and clamps its own input.
    func commit(scope: String? = nil) {
        let due = entries.filter { scope == nil || $0.value.scope == scope }
        for token in due.keys {
            entries[token] = nil
        }
        for entry in due.values {
            entry.commit()
        }
    }
}

private enum FanNumericInput {
    /// Temperatures: "," is accepted as the decimal separator.
    static func decimal(_ input: String) -> Double? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// RPM: parsed with the current locale first, so a grouping separator
    /// ("3,500" or "3.500") is not mistaken for a decimal point.
    static func rpm(_ input: String) -> Double? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed), number.doubleValue.isFinite {
            return number.doubleValue
        }
        return decimal(trimmed)
    }
}

struct FanCurveGraph: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice

    private let minTemperature = 30.0
    private let maxTemperature = 110.0
    private let leftInset = 42.0
    private let rightInset = 10.0
    private let topInset = 12.0
    private let bottomInset = 30.0

    var body: some View {
        GeometryReader { proxy in
            let chart = chartFrame(in: proxy.size)
            let points = normalizedPoints(chart: chart)
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))

                Path { path in
                    for index in 0...3 {
                        let y = chart.minY + (chart.height / 3 * Double(index))
                        path.move(to: CGPoint(x: chart.minX, y: y))
                        path.addLine(to: CGPoint(x: chart.maxX, y: y))
                    }
                    for index in 0...4 {
                        let x = chart.minX + (chart.width / 4 * Double(index))
                        path.move(to: CGPoint(x: x, y: chart.minY))
                        path.addLine(to: CGPoint(x: x, y: chart.maxY))
                    }
                }
                .stroke(.separator.opacity(0.45), lineWidth: 1)

                Path { path in
                    path.move(to: CGPoint(x: chart.minX, y: chart.minY))
                    path.addLine(to: CGPoint(x: chart.minX, y: chart.maxY))
                    path.addLine(to: CGPoint(x: chart.maxX, y: chart.maxY))
                }
                .stroke(.secondary.opacity(0.65), lineWidth: 1)

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first.position)
                    for point in points.dropFirst() {
                        path.addLine(to: point.position)
                    }
                }
                .stroke(.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(points) { plotted in
                    Circle()
                        .fill(.blue)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
                        .position(plotted.position)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let temperature = temperature(at: value.location.x, chart: chart)
                                    let rpm = rpm(at: value.location.y, chart: chart)
                                    store.updateCurvePoint(
                                        fanID: fan.id,
                                        pointID: plotted.point.id,
                                        temperature: temperature,
                                        rpm: nearestRPM(rpm)
                                    )
                                }
                        )
                }

                axisLabels(chart: chart)
            }
        }
    }

    private struct PlottedPoint: Identifiable {
        var point: FanCurvePoint
        var position: CGPoint

        var id: UUID { point.id }
    }

    private func normalizedPoints(chart: CGRect) -> [PlottedPoint] {
        let points = fan.curve.sorted { $0.temperatureC < $1.temperatureC }
        return points.map { point in
            let x = chart.minX + ((point.temperatureC - minTemperature) / (maxTemperature - minTemperature) * chart.width)
            let rpmProgress = Double(point.rpm - fan.minRPM) / Double(max(1, fan.maxRPM - fan.minRPM))
            let y = chart.maxY - (rpmProgress * chart.height)
            return PlottedPoint(
                point: point,
                position: CGPoint(
                    x: max(chart.minX, min(chart.maxX, x)),
                    y: max(chart.minY, min(chart.maxY, y))
                )
            )
        }
    }

    private func chartFrame(in size: CGSize) -> CGRect {
        CGRect(
            x: leftInset,
            y: topInset,
            width: max(1, size.width - leftInset - rightInset),
            height: max(1, size.height - topInset - bottomInset)
        )
    }

    private func temperature(at x: CGFloat, chart: CGRect) -> Double {
        let progress = max(0, min(1, (x - chart.minX) / chart.width))
        return (minTemperature + (Double(progress) * (maxTemperature - minTemperature))).rounded()
    }

    private func rpm(at y: CGFloat, chart: CGRect) -> Double {
        let progress = max(0, min(1, (chart.maxY - y) / chart.height))
        return Double(fan.minRPM) + (Double(progress) * Double(fan.maxRPM - fan.minRPM))
    }

    private func nearestRPM(_ rpm: Double) -> Int {
        Int((rpm / 50).rounded() * 50)
    }

    private func axisLabels(chart: CGRect) -> some View {
        ZStack {
            Text("\(fan.maxRPM)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .position(x: chart.minX - 22, y: chart.minY + 2)

            Text("\(fan.minRPM)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .position(x: chart.minX - 22, y: chart.maxY)

            Text("RPM")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .position(x: chart.minX - 22, y: chart.midY)

            Text("\(Int(store.preferences.temperatureUnit.toDisplay(minTemperature).rounded()))°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .position(x: chart.minX, y: chart.maxY + 17)

            Text("\(Int(store.preferences.temperatureUnit.toDisplay(maxTemperature).rounded()))\(store.preferences.temperatureUnit.degreeLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .position(x: chart.maxX - 4, y: chart.maxY + 17)
        }
    }
}

struct SystemSummaryView: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "System", systemImage: "desktopcomputer")
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(store.machine.modelIdentifier)
                }
                GridRow {
                    Text("Chip").foregroundStyle(.secondary)
                    Text(store.machine.chipName)
                }
                GridRow {
                    Text("Uptime").foregroundStyle(.secondary)
                    Text(uptimeString(store.machine.uptime))
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func uptimeString(_ uptime: TimeInterval) -> String {
        let hours = Int(uptime) / 3600
        let days = hours / 24
        if days > 0 {
            return "\(days)d \(hours % 24)h"
        }
        return "\(hours)h"
    }
}

struct SettingsPage<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MetricPill: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SectionHeader: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
    }
}

struct SensorIcon: View {
    var category: SensorCategory

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(category.tint)
            .frame(width: 18, height: 18)
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MERGE-STUB: remove at merge
// No-op stand-ins for the members the store agent adds to ThermalStore.swift
// (`retryAutomaticRecovery()`, `refreshHelperState()`, `trackedCurveFanIDs`).
// They exist only so this file compiles on its own branch; the real
// declarations conflict with these, so delete this whole extension when merging.
extension ThermalStore {
    var trackedCurveFanIDs: Set<String> { [] }
    func retryAutomaticRecovery() {}
    func refreshHelperState() {}
}
