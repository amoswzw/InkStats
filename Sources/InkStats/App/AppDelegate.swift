import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let sampler = Sampler()
    private let history = History()
    private let events = HardwareEvents()
    private let statusBar = StatusBarController()
    private let panel = PanelController()
    private let settingsWindow = SettingsWindowController()
    private let alerts = AlertEngine()
    private var latest = Snapshot()
    private var hasSample = false
    private var interval = 0.0
    private var pruneTimer: Timer?
    private var minuteTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.registerBundled()

        statusBar.onClick = { [weak self] module, button in
            guard let self else { return }
            self.panel.toggle(module, from: button)
            self.render()
        }
        statusBar.onRightClick = { [weak self] button in
            guard let self else { return }
            self.panel.hide()
            self.makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
        panel.onSettings = { [weak self] _, _ in
            self?.panel.hide()
            self?.settingsWindow.show()
        }
        panel.onRange = { [weak self] range in
            self?.panel.range = range
            self?.render()
        }

        sampler.onSample = { [weak self] snapshot, regular in
            guard let self else { return }
            self.latest = snapshot
            self.hasSample = true
            if regular {
                self.history.record(snapshot)
                self.alerts.evaluate(snapshot, chinese: self.settings.labelStyle == .chinese)
            }
            LiveData.shared.snapshot = snapshot
            self.render()
        }
        events.onEvent = { [weak self] event in self?.sampler.refresh(after: event) }
        events.start()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        HistoryStore.shared.prune(keepingDays: settings.historyDays)
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            HistoryStore.shared.prune(keepingDays: self.settings.historyDays)
        }
        applySettings()
        scheduleMinuteTick()
    }

    /// Redraws on each minute boundary so the clock never lags behind the sampling interval.
    private func scheduleMinuteTick() {
        let next = (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60 + 60.05
        minuteTimer = Timer(fire: Date(timeIntervalSinceReferenceDate: next), interval: 60, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(minuteTimer!, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        history.flush()
        HistoryStore.shared.waitForPendingWrites()
    }

    private func visibleModules() -> [ModuleID] {
        settings.enabledModules.filter { $0 != .battery || !hasSample || latest.battery.present }
    }

    private func applySettings() {
        if settings.interval != interval {
            interval = settings.interval
            sampler.start(interval: interval)
        }
        alerts.requestAuthorizationIfNeeded()
        render()
    }

    private func render() {
        statusBar.setModules(visibleModules(), combined: settings.combineItems)
        statusBar.render(latest, history, settings: settings, highlighted: panel.module)
        sampler.setWantsProcesses(panel.module == .cpu || panel.module == .memory)
        sampler.setWantsTraffic(panel.module == .network)
        HelperClient.shared.refresh(wantPower: panel.module == .power, wantProcesses: panel.module == .cpu || panel.module == .memory)
        WeatherService.shared.refreshIfNeeded(enabled: visibleModules().contains(.weather), place: settings.weatherPlace)

        guard let module = panel.module else { return }
        let dark: Bool
        switch settings.appearance {
        case .system: dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        case .light: dark = false
        case .dark: dark = true
        }
        let painter = Painter(theme: settings.theme, palette: Palette.make(settings.theme, dark: dark), texture: CGFloat(settings.texture))
        let source: SeriesSource = panel.range == .live ? history : StoredSeries(range: panel.range)
        panel.show(panelSpec(module, latest, source), painter: painter, labels: settings.labelStyle,
                   appearance: NSAppearance(named: dark ? .darkAqua : .aqua))
    }

    // MARK: - Quick menu (right-click)

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let s = settings

        let settingsItem = ActionItem("Settings…", checked: false) { [weak self] in self?.settingsWindow.show() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let theme = NSMenu()
        for t in ThemeID.allCases { theme.addItem(ActionItem(t.title, checked: s.theme == t) { s.theme = t }) }
        menu.addItem(submenu("Theme", theme))

        let labels = NSMenu()
        labels.addItem(ActionItem("Theme default (\(s.theme.defaultLabels == .chinese ? "汉字" : "English"))", checked: s.labels == .theme) { s.labels = .theme })
        labels.addItem(ActionItem("English", checked: s.labels == .english) { s.labels = .english })
        labels.addItem(ActionItem("汉字", checked: s.labels == .chinese) { s.labels = .chinese })
        menu.addItem(submenu("Labels", labels))

        let modules = NSMenu()
        for m in ModuleID.allCases {
            modules.addItem(ActionItem("\(m.names.english) · \(m.names.chinese)", checked: s.enabledModules.contains(m)) { s.toggle(m) })
        }
        menu.addItem(submenu("Menu Bar Items", modules))

        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit InkStats", checked: false) { NSApp.terminate(nil) })
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
