import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var store: ThermalStore

    private var displayedSensors: [ThermalSensor] {
        Array(store.menuSensors.prefix(3))
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "fan.fill")
            if displayedSensors.isEmpty {
                Text("--")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            } else {
                ForEach(Array(displayedSensors.enumerated()), id: \.element.id) { offset, sensor in
                    if offset > 0 {
                        Text("·").foregroundStyle(.secondary)
                    }
                    Text(store.preferences.temperatureUnit.format(sensor.temperatureC))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .opacity(store.isSensorFresh(sensor) ? 1 : 0.55)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard !displayedSensors.isEmpty else { return "No sensor reading available" }
        return displayedSensors
            .map {
                let freshness = store.isSensorFresh($0) ? "" : ", last reading"
                return "\($0.name) \(store.preferences.temperatureUnit.format($0.temperatureC))\(freshness)"
            }
            .joined(separator: ", ")
    }
}

struct StatusPanelView: View {
    @EnvironmentObject private var store: ThermalStore
    @State private var spinAngle = 0.0

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
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(thermalTint.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: "fan.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(thermalTint)
                    .rotationEffect(.degrees(spinAngle))
                    .onChange(of: store.isRefreshing) { _, refreshing in
                        if refreshing {
                            withAnimation(.easeInOut(duration: 0.7)) { spinAngle += 180 }
                        }
                    }
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
                Text(store.hottestSensor.map { store.preferences.temperatureUnit.format($0.temperatureC) } ?? "--")
                    .font(.title3.weight(.bold))
                Text(store.hottestSensor?.name ?? "No sensor")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
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
                ForEach(store.warnings, id: \.self) { warning in
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
                    CompactFanCard(fan: fan)
                }
            }
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            store.applyPreset(preset)
                        } label: {
                            Label(preset.name, systemImage: isActive ? "checkmark" : "dial.low")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(isActive ? Color.accentColor : nil)
                        .accessibilityHint("Applies the \(preset.name) preset to the detected fans.")
                    }
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

            SettingsLink {
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

    private var thermalTint: Color {
        guard let hottest = store.hottestSensor?.temperatureC else { return .blue }
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
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("General", systemImage: "gearshape") }

            SensorsSettingsPane()
                .tabItem { Label("Sensors", systemImage: "sensor") }

            IndexesSettingsPane()
                .tabItem { Label("Indexes", systemImage: "chart.line.uptrend.xyaxis") }

            FansSettingsPane()
                .tabItem { Label("Fans", systemImage: "fan") }

            PresetsSettingsPane()
                .tabItem { Label("Presets", systemImage: "dial.low") }

            MenuBarSettingsPane()
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            AboutSettingsPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(18)
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
                        ), in: 1...10, step: 1)
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
                    Text("Helper")
                    HelperStatusRow()
                }
            }

            SystemSummaryView()
        }
    }
}

struct HelperStatusRow: View {
    @EnvironmentObject private var store: ThermalStore

    var body: some View {
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
            }
            Spacer(minLength: 8)
            if store.installingHelper {
                ProgressView().controlSize(.small)
            } else if store.helperState != .ready {
                Button {
                    store.installHelper()
                } label: {
                    Label(store.helperState == .missing ? "Install" : "Update", systemImage: "arrow.down.circle")
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .leading)
    }

    private var helperTitle: String {
        switch store.helperState {
        case .missing: "Hardware Helper not installed"
        case .updateRequired: "Hardware Helper update required"
        case .legacyCompatible: "Compatible Hardware Helper ready"
        case .ready: "Hardware Helper ready"
        }
    }

    private var helperDetail: String {
        switch store.helperState {
        case .missing: "Install once to control fans without repeated password prompts."
        case .updateRequired: "Update once to enable reliable curve tracking and crash recovery."
        case .legacyCompatible: "Fan control works now. Update once to adopt the public helper identity."
        case .ready: "Fan writes, curve tracking, and crash recovery are available."
        }
    }

    private var helperSymbol: String {
        switch store.helperState {
        case .missing: "lock.shield"
        case .updateRequired: "exclamationmark.shield.fill"
        case .legacyCompatible: "checkmark.shield"
        case .ready: "checkmark.shield.fill"
        }
    }

    private var helperTint: Color {
        store.helperState == .ready ? .green : .orange
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
        return "\(sensor.source.label) · \(store.preferences.temperatureUnit.format(sensor.temperatureC))\(freshness)"
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

    var body: some View {
        SettingsPage(title: "Fans", subtitle: "\(store.fans.count) controllable profiles") {
            if store.fans.isEmpty {
                EmptyStateView(symbol: "fan.slash", title: "No controllable fan detected")
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.fans) { fan in
                            FullFanCard(fan: fan)
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
        SettingsPage(title: "Presets", subtitle: store.activePresetName) {
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
                    Text(sensor.name)
                        .lineLimit(1)
                    Text(sensor.category.title)
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
                Text(store.searchText.isEmpty && store.selectedCategory == nil
                    ? "No readable sensors on this Mac."
                    : "No sensors match the current filter.")
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
                .disabled(!store.canToggleMenuSensor(sensor))
                .accessibilityLabel(inMenuBar ? "Remove from menu bar" : "Show in menu bar")
                .help(inMenuBar ? "Remove from menu bar" : "Show in menu bar")

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

    private var isEstimated: Bool { fan.source == .estimated }
    private var isApplying: Bool { store.applyingFanIDs.contains(fan.id) }

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

            if isEstimated {
                Label("Fan control unavailable — no controllable fan detected on this Mac.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FanControlStatusLine(fan: fan, isApplying: isApplying)

                Picker("Mode", selection: Binding(
                    get: { fan.mode },
                    set: { store.setFanMode(fan.id, mode: $0) }
                )) {
                    ForEach(FanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isApplying)

                switch fan.mode {
                case .automatic:
                    Text(fan.hardwareMode == .automatic
                        ? "macOS is controlling this fan."
                        : "Auto is selected but has not reached the hardware yet.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .fixed:
                    HStack {
                        Slider(value: Binding(
                            get: { Double(fan.targetRPM) },
                            set: { store.setFanTarget(fan.id, rpm: Int($0.rounded())) }
                        ), in: Double(fan.minRPM)...Double(fan.maxRPM), step: 50)
                        TextField("RPM", value: Binding<Int>(
                            get: { fan.targetRPM },
                            set: { store.setFanTarget(fan.id, rpm: $0) }
                        ), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 70)
                    }
                    .disabled(isApplying)
                case .curve:
                    CompactLinkedSensorPicker(fan: fan)
                        .disabled(isApplying)
                    CurveEditor(fan: fan, compact: true)
                        .disabled(isApplying)
                }

                HStack {
                    Button {
                        store.applyFanWithAdmin(fan.id)
                    } label: {
                        if isApplying {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(applyButtonTitle, systemImage: store.helperInstalled ? "checkmark.circle" : "key")
                        }
                    }
                    .disabled(isApplying)
                    .buttonStyle(.borderedProminent)
                    Button {
                        store.resetFanToAutomatic(fan.id)
                    } label: {
                        Label("Auto", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isApplying || (fan.mode == .automatic && fan.hardwareMode == .automatic))
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }

            if let command = fan.lastCommand {
                Label(command, systemImage: commandSymbol)
                    .font(.caption2)
                    .foregroundStyle(commandTint)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var applyButtonTitle: String {
        switch store.helperState {
        case .missing: "Install & Apply"
        case .updateRequired: "Update & Apply"
        case .legacyCompatible, .ready: fan.controlState == .failed ? "Retry" : "Apply"
        }
    }

    private var commandSymbol: String {
        switch fan.controlState {
        case .failed: "xmark.octagon.fill"
        case .pending: "clock.fill"
        case .active: "checkmark.circle.fill"
        case .idle: "info.circle"
        }
    }

    private var commandTint: Color {
        switch fan.controlState {
        case .failed: .red
        case .pending: .orange
        case .active: .green
        case .idle: .secondary
        }
    }

}

struct FullFanCard: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice

    private var isEstimated: Bool { fan.source == .estimated }
    private var isApplying: Bool { store.applyingFanIDs.contains(fan.id) }

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
                }
            }

            if isEstimated {
                Label("Fan control is unavailable — no controllable fan was detected on this Mac (SMC fan keys are not readable). Values above are estimated.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FanControlStatusLine(fan: fan, isApplying: isApplying)

                Picker("Mode", selection: Binding(
                    get: { fan.mode },
                    set: { store.setFanMode(fan.id, mode: $0) }
                )) {
                    ForEach(FanMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isApplying)

                switch fan.mode {
                case .automatic:
                    Text(fan.hardwareMode == .automatic
                        ? "macOS is controlling this fan."
                        : "Auto is selected, but the hardware still reports manual control.")
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
                            TextField("RPM", value: Binding<Int>(
                                get: { fan.targetRPM },
                                set: { store.setFanTarget(fan.id, rpm: $0) }
                            ), format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 82)
                        }
                    }
                    .disabled(isApplying)
                case .curve:
                    VStack(alignment: .leading) {
                        Text("Linked Sensor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Linked Sensor", selection: Binding<String>(
                            get: { fan.linkedSensorID ?? "" },
                            set: { store.setLinkedSensor(fan.id, sensorID: $0.isEmpty ? nil : $0) }
                        )) {
                            Text("Hottest sensor").tag("")
                            ForEach(store.curveSourceSensors) { sensor in
                                Text(sensor.source == .index ? "\(sensor.name) · Index" : sensor.name).tag(sensor.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    .disabled(isApplying)
                    CurveEditor(fan: fan)
                        .disabled(isApplying)
                }

                HStack {
                    Button {
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
                    .disabled(isApplying)
                    .buttonStyle(.borderedProminent)
                    Button {
                        store.resetFanToAutomatic(fan.id)
                    } label: {
                        Label("Return to Auto", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(isApplying || (fan.mode == .automatic && fan.hardwareMode == .automatic))
                    .buttonStyle(.bordered)
                }

                if fan.mode == .curve {
                    Label("With the helper installed, a curve keeps tracking temperature automatically after you apply it once.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let command = fan.lastCommand {
                Label(command, systemImage: commandSymbol)
                    .font(.caption)
                    .foregroundStyle(commandTint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var targetSummary: String {
        switch fan.mode {
        case .automatic:
            return "Hardware target \(fan.hardwareTargetRPM ?? fan.targetRPM)"
        case .fixed:
            return "Fixed target \(fan.targetRPM)"
        case .curve:
            return "Curve target \(fan.targetRPM)"
        }
    }

    private var applyButtonTitle: String {
        switch store.helperState {
        case .missing: "Install Helper & Apply"
        case .updateRequired: "Update Helper & Apply"
        case .legacyCompatible, .ready: fan.controlState == .failed ? "Retry Hardware Write" : "Apply to Hardware"
        }
    }

    private var commandSymbol: String {
        switch fan.controlState {
        case .failed: "xmark.octagon.fill"
        case .pending: "clock.fill"
        case .active: "checkmark.circle.fill"
        case .idle: "info.circle"
        }
    }

    private var commandTint: Color {
        switch fan.controlState {
        case .failed: .red
        case .pending: .orange
        case .active: .green
        case .idle: .secondary
        }
    }
}

struct FanControlStatusLine: View {
    var fan: FanDevice
    var isApplying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(statusTitle, systemImage: statusSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusTint)
            Spacer()
            Text(hardwareSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var statusTitle: String {
        if isApplying { return "Applying" }
        return switch fan.controlState {
        case .idle: "macOS control"
        case .pending: "Changes pending"
        case .active: fan.mode == .curve ? "Curve active" : "Manual control active"
        case .failed: "Write failed"
        }
    }

    private var statusSymbol: String {
        if isApplying { return "arrow.triangle.2.circlepath" }
        return switch fan.controlState {
        case .idle: "checkmark.circle"
        case .pending: "clock"
        case .active: "checkmark.shield.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var statusTint: Color {
        if isApplying { return .blue }
        return switch fan.controlState {
        case .idle, .active: .green
        case .pending: .orange
        case .failed: .red
        }
    }

    private var hardwareSummary: String {
        guard let hardwareMode = fan.hardwareMode else { return "Reading hardware" }
        switch hardwareMode {
        case .automatic:
            return "Hardware: Auto"
        case .fixed, .curve:
            return "Hardware: Manual · \(fan.hardwareTargetRPM ?? fan.targetRPM) RPM"
        }
    }
}

struct CompactLinkedSensorPicker: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice

    var body: some View {
        Picker("Linked Sensor", selection: Binding<String>(
            get: { fan.linkedSensorID ?? "" },
            set: { store.setLinkedSensor(fan.id, sensorID: $0.isEmpty ? nil : $0) }
        )) {
            Text("Sensor").tag("")
            ForEach(store.curveSourceSensors) { sensor in
                Text(sensor.source == .index ? "\(sensor.name) · Index" : sensor.name).tag(sensor.id)
            }
        }
        .labelsHidden()
    }
}

struct CurveEditor: View {
    @EnvironmentObject private var store: ThermalStore
    var fan: FanDevice
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Curve")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(fan.targetRPM) RPM")
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
        return TextField(unit.degreeLabel, value: Binding<Double>(
            get: { unit.toDisplay(point.temperatureC) },
            set: { store.updateCurvePoint(fanID: fan.id, pointID: point.id, temperature: unit.toCelsius($0)) }
        ), format: .number.precision(.fractionLength(0)))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
    }

    private func rpmField(for point: FanCurvePoint) -> some View {
        TextField("RPM", value: Binding<Int>(
            get: { point.rpm },
            set: { store.updateCurvePoint(fanID: fan.id, pointID: point.id, rpm: $0) }
        ), format: .number)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
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
