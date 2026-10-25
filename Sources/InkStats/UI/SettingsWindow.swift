import InkKit
import ServiceManagement
import SwiftUI

final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            window = makeInkSettingsWindow(title: "InkStats Settings", size: CGSize(width: 820, height: 620), root: SettingsView())
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    static let pages = [
        InkPage(id: "general", chinese: "通用", english: "General"),
        InkPage(id: "menubar", chinese: "菜单栏", english: "Menu Bar"),
        InkPage(id: "sensors", chinese: "温度", english: "Sensors"),
        InkPage(id: "alerts", chinese: "提醒", english: "Alerts"),
        InkPage(id: "weather", chinese: "天气", english: "Weather"),
        InkPage(id: "clock", chinese: "时间", english: "Clock"),
        InkPage(id: "helper", chinese: "助手", english: "Helper"),
        InkPage(id: "history", chinese: "历史", english: "History"),
        InkPage(id: "about", chinese: "关于", english: "About"),
    ]
    @State var page = "general"

    var body: some View {
        InkSettingsShell(seal: "计", appChinese: "墨计", appEnglish: "InkStats", pages: Self.pages, selection: $page) { page in
            Group {
                switch page {
                case "menubar": MenuBarSettings()
                case "sensors": SensorsSettings()
                case "alerts": AlertsSettings()
                case "weather": WeatherSettings()
                case "clock": ClockSettings()
                case "helper": HelperSettings()
                case "history": HistorySettings()
                case "about": AboutView()
                default: GeneralSettings()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 820, minHeight: 620)
    }
}

private struct GeneralSettings: View {
    @AppStorage("theme") private var theme: ThemeID = .ink
    @AppStorage("labels") private var labels: LabelSetting = .theme
    @AppStorage("appearance") private var appearance: PanelAppearance = .system
    @AppStorage("texture") private var texture = 1.0
    @AppStorage("interval") private var interval = 2.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(ThemeID.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Labels", selection: $labels) {
                Text("Theme default (\(theme.defaultLabels == .chinese ? "汉字" : "English"))").tag(LabelSetting.theme)
                Text("English").tag(LabelSetting.english)
                Text("汉字").tag(LabelSetting.chinese)
            }
            Picker("Panel appearance", selection: $appearance) {
                Text("Match System").tag(PanelAppearance.system)
                Text("Light").tag(PanelAppearance.light)
                Text("Dark").tag(PanelAppearance.dark)
            }
            LabeledContent(theme == .ink ? "Ink texture" : "Roughness") {
                Slider(value: $texture, in: 0...2) { EmptyView() } minimumValueLabel: { Text("Off") } maximumValueLabel: { Text("Heavy") }
            }
            Picker("Update every", selection: $interval) {
                Text("1 second").tag(1.0)
                Text("2 seconds").tag(2.0)
                Text("5 seconds").tag(5.0)
            }
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let loginError {
                Text(loginError).font(.inkCaption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        guard enabled != (service.status == .enabled) else { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change Launch at Login: \(error.localizedDescription)"
            launchAtLogin = service.status == .enabled
        }
    }
}

private struct MenuBarSettings: View {
    @State private var enabled = Set(Settings.shared.enabledModules)
    @State private var combined = Settings.shared.combinedModules

    var body: some View {
        Form {
            Section {
                ForEach(ModuleID.allCases, id: \.self) { module in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { enabled.contains(module) },
                            set: { on in
                                if on { enabled.insert(module) } else { enabled.remove(module) }
                                Settings.shared.enabledModules = ModuleID.allCases.filter(enabled.contains)
                            }
                        )) {
                            HStack {
                                Text(module.names.english)
                                Text(module.names.chinese).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("Combine", isOn: Binding(
                            get: { combined.contains(module) },
                            set: { on in
                                if on { combined.insert(module) } else { combined.remove(module) }
                                Settings.shared.combinedModules = combined
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .disabled(!enabled.contains(module))
                        .padding(.leading, 12)
                    }
                }
            } header: {
                InkSectionHeader(chinese: "菜单栏项目", english: "Menu bar items")
            } footer: {
                Text("Items marked Combine share one menu bar item, placed where the first of them sits; click a part of it to open that panel. The rest keep an item each. Hold ⌘ and drag an item in the menu bar to reorder it. The battery item only appears on Macs with a battery.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { enabled = Set(Settings.shared.enabledModules) }
    }
}

struct ClockSettings: View {
    @State private var enabled = Settings.shared.enabledModules.contains(.time)
    @AppStorage("clockFormat") private var format: ClockFormat = .weekday
    @AppStorage("showEvents") private var showEvents = false
    @State private var clocks = Settings.shared.worldClocks
    @State private var query = ""
    @State private var eventsDenied = false

    private var matches: [String] {
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        return Array(TimeZone.knownTimeZoneIdentifiers
            .filter { WorldClock.city($0).localizedCaseInsensitiveContains(query) && !clocks.contains($0) }
            .prefix(6))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show the time in the menu bar", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on != Settings.shared.enabledModules.contains(.time) { Settings.shared.toggle(.time) }
                    }
                Picker("Format", selection: $format) {
                    ForEach(ClockFormat.allCases, id: \.self) { Text(Format.clock(Date(), $0, chinese: false)).tag($0) }
                }
            } footer: {
                Text("Sunrise, sunset and the sun graph use the place chosen in the Weather tab. They're calculated on your Mac, and choosing a place doesn't turn weather on.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(clocks, id: \.self) { identifier in
                    HStack {
                        Text(WorldClock.city(identifier))
                        Text(identifier).font(.inkCaption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { setClocks(clocks.filter { $0 != identifier }) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                }
                TextField("Add a city", text: $query, prompt: Text("Add a city, e.g. London"))
                    .labelsHidden()
                ForEach(matches, id: \.self) { identifier in
                    Button {
                        setClocks(clocks + [identifier])
                        query = ""
                    } label: {
                        HStack {
                            Text(WorldClock.city(identifier))
                            Text(identifier).font(.inkCaption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { InkSectionHeader(chinese: "世界时钟", english: "World clocks") }
            Section {
                Toggle("Show upcoming calendar events", isOn: $showEvents)
                    .onChange(of: showEvents) { _, on in
                        guard on, !CalendarEvents.shared.authorized else { return }
                        CalendarEvents.shared.requestAccess { granted in
                            eventsDenied = !granted
                            if !granted { showEvents = false }
                        }
                    }
                if eventsDenied {
                    Text("InkStats doesn't have access to your calendars. You can allow it in System Settings → Privacy & Security → Calendars.")
                        .font(.inkCaption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Today's and tomorrow's events are read from the Calendar app. They never leave your Mac.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { enabled = Settings.shared.enabledModules.contains(.time) }
    }

    private func setClocks(_ list: [String]) {
        clocks = list
        Settings.shared.worldClocks = list
    }
}

struct WeatherSettings: View {
    @State private var enabled = Settings.shared.enabledModules.contains(.weather)
    @State private var place = Settings.shared.weatherPlace
    @AppStorage("fahrenheit") private var fahrenheit = Locale.current.measurementSystem == .us
    @State private var query = ""
    @State private var results: [WeatherPlace] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Show weather in the menu bar", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        if on != Settings.shared.enabledModules.contains(.weather) { Settings.shared.toggle(.weather) }
                    }
                Picker("Units", selection: $fahrenheit) {
                    Text("°C and km/h").tag(false)
                    Text("°F and mph").tag(true)
                }
            } footer: {
                Text("Weather is the only part of InkStats that uses the network. While it's on, InkStats sends the chosen place's coordinates to Open-Meteo (open-meteo.com) about every 30 minutes. Searching sends the text you type. Nothing else leaves your Mac.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Showing", value: place.map { $0.detail.isEmpty ? $0.name : "\($0.name), \($0.detail)" } ?? "No place chosen")
                HStack {
                    TextField("City", text: $query, prompt: Text("Search for a city"))
                        .labelsHidden()
                        .onSubmit(search)
                    Button("Search", action: search)
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                }
                if let searchError {
                    Text(searchError).font(.inkCaption).foregroundStyle(.red)
                }
                ForEach(results, id: \.self) { result in
                    Button {
                        Settings.shared.weatherPlace = result
                        place = result
                        results = []
                        query = ""
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.name)
                            Text(result.detail).font(.inkCaption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { InkSectionHeader(chinese: "地点", english: "Place") }
        }
        .formStyle(.grouped)
        .onAppear { enabled = Settings.shared.enabledModules.contains(.weather) }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        searchError = nil
        Task {
            do {
                results = try await WeatherService.search(text)
                if results.isEmpty { searchError = "No places found for “\(text)”." }
            } catch {
                searchError = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
    }
}

private struct HistorySettings: View {
    @AppStorage("historyDays") private var days = 7
    @State private var size = HistoryStore.shared.sizeOnDisk()
    @State private var confirmClear = false

    var body: some View {
        Form {
            Picker("Keep history for", selection: $days) {
                Text("1 day").tag(1)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
            }
            LabeledContent("Stored on disk", value: Format.bytes(Double(size)))
            LabeledContent("Location") {
                Text(HistoryStore.shared.url.deletingLastPathComponent().path)
                    .font(.inkCaption)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            Button("Clear History…", role: .destructive) { confirmClear = true }
                .confirmationDialog("Clear all saved history?", isPresented: $confirmClear) {
                    Button("Clear History", role: .destructive) {
                        HistoryStore.shared.clear()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { size = HistoryStore.shared.sizeOnDisk() }
                    }
                } message: {
                    Text("Graphs for 1 hour, 24 hours and 7 days start again from now. This can't be undone.")
                }
        }
        .formStyle(.grouped)
        .onAppear { size = HistoryStore.shared.sizeOnDisk() }
    }
}

private struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("墨计").font(.custom("Xingkai SC", size: 40))
            Text("InkStats \(version)").font(.headline)
            Text("A menu bar system monitor. It only connects to the network for weather, which is off unless you turn it on.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("MIT License. Includes a Swift port of rough.js (MIT, © 2019 Preet Shihn) and Excalifont (SIL Open Font License 1.1, © 2024 Excalidraw).")
                .font(.inkCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

/// Latest snapshot for SwiftUI views that show live values.
final class LiveData: ObservableObject {
    static let shared = LiveData()
    @Published var snapshot = Snapshot()
}

struct SensorsSettings: View {
    @ObservedObject private var live = LiveData.shared
    @AppStorage("menuSensor") private var menuSensor = "cpuAverage"

    var body: some View {
        let sensors = live.snapshot.sensors
        Form {
            Picker("Menu bar shows", selection: $menuSensor) {
                Text("CPU average").tag("cpuAverage")
                Text("CPU hottest").tag("cpuHottest")
                Text("SSD").tag("ssd")
                Text("Battery").tag("battery")
                Divider()
                ForEach(sensors.all, id: \.key) { Text($0.name).tag($0.key) }
            }
            Section {
                if sensors.all.isEmpty { Text("No temperature sensors found.").foregroundStyle(.secondary) }
                ForEach(sensors.all, id: \.key) { sensor in
                    LabeledContent {
                        Text(String(format: "%.1f °C", sensor.celsius)).monospacedDigit()
                    } label: {
                        Text(sensor.name)
                        Text(sensor.key).font(.inkCaption).foregroundStyle(.secondary)
                    }
                }
            } header: { InkSectionHeader(chinese: "温度", english: "Temperatures") }
            if !sensors.fans.isEmpty {
                Section {
                    ForEach(sensors.fans, id: \.index) { FanRow(fan: $0, controllable: live.snapshot.helperRunning) }
                } header: {
                    Text("Fans")
                } footer: {
                    Text(live.snapshot.helperRunning
                         ? "Manual speeds last until InkStats quits, and fans return to automatic if any CPU sensor reaches 95 °C."
                         : "Install the helper in the Helper tab to set fan speeds.")
                        .font(.inkCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 420)
    }
}

struct AlertsSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(AlertRule.allCases, id: \.self) { AlertRow(rule: $0) }
            } footer: {
                Text("Each alert is sent once, then waits until the condition clears. The first time you turn one on, macOS asks to allow notifications from InkStats.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AlertRow: View {
    let rule: AlertRule
    @AppStorage private var enabled: Bool
    @AppStorage private var threshold: Double

    init(rule: AlertRule) {
        self.rule = rule
        _enabled = AppStorage(wrappedValue: false, rule.enabledKey)
        _threshold = AppStorage(wrappedValue: rule.threshold?.initial ?? 0, rule.thresholdKey)
    }

    var body: some View {
        HStack {
            Text(rule.title.english)
            Text(rule.title.chinese).foregroundStyle(.secondary)
            Spacer()
            if let t = rule.threshold {
                Stepper(value: $threshold, in: t.range, step: t.step) {
                    Text("\(Int(threshold)) \(t.unit)").monospacedDigit()
                }
                .disabled(!enabled)
            }
            Toggle("", isOn: $enabled).labelsHidden().toggleStyle(.switch)
        }
    }
}

private struct FanRow: View {
    let fan: Fan
    let controllable: Bool
    @State private var manual = false
    @State private var target = 0.0
    @State private var error: String?

    var body: some View {
        let minimum = fan.minRPM ?? 1000, maximum = fan.maxRPM ?? 6000
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Fan \(fan.index + 1)") {
                Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm)) rpm").monospacedDigit()
            }
            if controllable {
                Picker("Control", selection: $manual) {
                    Text("Automatic").tag(false)
                    Text("Manual").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: manual) { _, isManual in
                    if target < minimum { target = max(minimum, fan.rpm) }
                    apply(isManual ? target : 0)
                }
                if manual {
                    HStack {
                        Slider(value: $target, in: minimum...maximum, step: 100) { editing in
                            if !editing { apply(target) }
                        }
                        Text("\(Int(target)) rpm").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                if let error { Text(error).font(.inkCaption).foregroundStyle(.red) }
            }
        }
    }

    private func apply(_ rpm: Double) {
        HelperClient.shared.setFan(fan.index, rpm: rpm) { error = $0 }
    }
}

private struct HelperSettings: View {
    @State private var state = HelperClient.shared.state
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") { Text(statusText).foregroundStyle(state == .running ? .green : .secondary) }
                switch state {
                case .notInstalled:
                    Button("Install Helper…") { act { try HelperClient.shared.install() } }
                case .needsApproval:
                    Text("macOS needs your approval. Turn on InkStats under Allow in the Background.").font(.inkCaption)
                    Button("Open Login Items Settings") { HelperClient.shared.openApprovalSettings() }
                case .running:
                    Button("Remove Helper", role: .destructive) { act { try HelperClient.shared.uninstall() } }
                case .unavailable(let reason):
                    Text(reason).font(.inkCaption).foregroundStyle(.secondary)
                }
                if let message { Text(message).font(.inkCaption).foregroundStyle(.red) }
            }
            Section {
                Label("CPU and Neural Engine power, from Apple's powermetrics", systemImage: "bolt")
                Label("CPU and memory of every process, including the system's", systemImage: "list.bullet")
                Label("Manual fan speeds, with automatic fallback when hot", systemImage: "fan")
                Label("Low Power Mode and Wi-Fi switches in the panels", systemImage: "switch.2")
            } header: { InkSectionHeader(chinese: "助手能做什么", english: "What the helper adds") }
            Section {
                Text("The helper runs as root, starts only when InkStats connects, and accepts requests only from InkStats builds signed by the same developer team. It can only perform the actions listed above.")
                    .font(.inkCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { state = HelperClient.shared.state }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in state = HelperClient.shared.state }
    }

    private var statusText: String {
        switch state {
        case .notInstalled: return "Not installed"
        case .needsApproval: return "Waiting for approval"
        case .running: return "Installed"
        case .unavailable: return "Unavailable"
        }
    }

    private func act(_ body: () throws -> Void) {
        do {
            try body()
            message = nil
        } catch {
            message = error.localizedDescription
        }
        state = HelperClient.shared.state
    }
}
