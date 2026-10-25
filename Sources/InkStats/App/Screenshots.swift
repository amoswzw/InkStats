import InkKit
import AppKit

/// `InkStats --render-screenshots <folder>` writes the README slides. Readings are live, but
/// anything personal (process names, addresses, devices, volumes) is replaced with samples.
enum Screenshots {
    static func run(output: URL) {
        Fonts.registerBundled()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let settings = Settings.shared
        let savedPlace = settings.weatherPlace
        let place = WeatherPlace(name: "Hangzhou", detail: "Zhejiang, China", latitude: 30.29, longitude: 120.16)
        settings.weatherPlace = place
        defer { settings.weatherPlace = savedPlace }
        WeatherService.shared.refreshIfNeeded(enabled: true, place: place)

        let sampler = Sampler(), history = History(persist: false)
        var snapshot = Snapshot()
        for _ in 0..<40 {
            snapshot = sampler.sample()
            history.record(snapshot)
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        snapshot.processes = [("Safari", 14.2, 2.1e9), ("Xcode", 9.6, 3.4e9), ("Music", 3.1, 0.6e9),
                              ("Mail", 1.4, 0.4e9), ("Finder", 0.9, 0.2e9)].enumerated().map {
            ProcessUsage(pid: pid_t(400 + $0.offset), name: $0.element.0, cpu: $0.element.1, memory: $0.element.2)
        }
        snapshot.networkDetails = NetworkDetails()
        snapshot.appTraffic = []
        snapshot.bluetooth = []
        snapshot.volumes = []
        snapshot.weather = WeatherService.shared.cached(for: place)

        let icon = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/nonexistent"))
        let ink = painter(.ink, dark: false), sketch = painter(.sketch, dark: false)
        // Laying a panel out draws into whatever context is current, so render them all
        // before any slide makes its own context current.
        let cpu = panel(.cpu, snapshot, history, ink), sensors = panel(.sensors, snapshot, history, ink)
        let themed = [(ThemeID.ink, false), (.sketch, false), (.ink, true), (.sketch, true)].map {
            panel(.cpu, snapshot, history, painter($0.0, dark: $0.1), labels: $0.0.defaultLabels)
        }
        let sky = [panel(.weather, snapshot, history, ink), panel(.time, snapshot, history, ink)]
        let hardware = (snapshot.battery.present ? [ModuleID.sensors, .power, .battery] : [.sensors, .power])
            .map { panel($0, snapshot, history, sketch, labels: .english) }

        Promo.slide(title: "Your Mac, in ink", subtitle: "CPU, memory, sensors and power, brushed into the menu bar",
                    icon: icon, to: output.appendingPathComponent("1-menubar.png")) { ctx in
            let desk = Promo.content
            let bar: CGFloat = 60
            Promo.desktop(ctx, desk, menuBar: bar)
            if let apple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 30, weight: .regular).applying(.init(paletteColors: [.white]))) {
                Promo.image(apple, in: CGRect(x: desk.minX + 40, y: desk.minY + (bar - apple.size.height) / 2, width: apple.size.width, height: apple.size.height))
            }
            Promo.menuText("Finder", at: CGPoint(x: desk.minX + 92, y: desk.minY + 14), bold: true)
            Promo.menuText("File    Edit    View    Go    Window    Help", at: CGPoint(x: desk.minX + 210, y: desk.minY + 14))
            let clock = "Sun Oct 25  10:41"
            Promo.menuText(clock, at: CGPoint(x: desk.maxX - 270, y: desk.minY + 14))

            let modules: [ModuleID] = [.cpu, .gpu, .memory, .network, .sensors, .power, .weather]
            let dark = painter(.ink, dark: true)
            let images = modules.map { StatusBarController.image($0, parts: barParts($0, snapshot, history), painter: dark, labels: .chinese) }
            let scale: CGFloat = 2
            var x = desk.maxX - 300 - images.reduce(0) { $0 + $1.size.width * scale + 24 }
            var itemX: [ModuleID: CGFloat] = [:]
            for (module, image) in zip(modules, images) {
                itemX[module] = x
                Promo.image(image, in: CGRect(x: x, y: desk.minY + (bar - image.size.height * scale) / 2, width: image.size.width * scale, height: image.size.height * scale))
                x += image.size.width * scale + 24
            }
            let room = desk.height - bar - 40
            for (module, image) in [(ModuleID.cpu, cpu), (.sensors, sensors)] {
                let s = min(2, room / image.size.height)
                Promo.image(image, in: CGRect(x: (itemX[module] ?? desk.midX) - 20, y: desk.minY + bar + 16,
                                              width: image.size.width * s, height: image.size.height * s))
            }
        }

        Promo.slide(title: "Ink-wash or hand-drawn", subtitle: "Two themes, each in light and dark",
                    icon: icon, to: output.appendingPathComponent("2-themes.png")) { _ in
            row(themed, in: Promo.content)
        }

        Promo.slide(title: "Weather, sun and moon", subtitle: "Forecast, sunrise and a lunar calendar, worked out on your Mac",
                    icon: icon, to: output.appendingPathComponent("3-weather-time.png")) { _ in
            row(sky, in: Promo.content)
        }

        Promo.slide(title: "Every sensor, every watt", subtitle: "Temperatures, fans, power and battery health",
                    icon: icon, to: output.appendingPathComponent("4-sensors.png")) { _ in
            row(hardware, in: Promo.content)
        }
    }

    private static func painter(_ theme: ThemeID, dark: Bool) -> Painter {
        Painter(theme: theme, palette: .make(theme, dark: dark), texture: 1)
    }

    private static func panel(_ module: ModuleID, _ snapshot: Snapshot, _ history: History, _ painter: Painter, labels: LabelStyle = .chinese) -> NSImage {
        let view = PanelView()
        view.spec = panelSpec(module, snapshot, history)
        view.painter = painter
        view.labels = labels
        view.appearance = NSAppearance(named: painter.palette.isDark ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: PanelView.width, height: view.requiredHeight())
        let image = NSImage(size: view.bounds.size)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    /// Lays panels side by side, centered, as large as fits (at most 2×).
    private static func row(_ images: [NSImage], in rect: CGRect) {
        let gap: CGFloat = 56
        let width = images.reduce(0) { $0 + $1.size.width } , height = images.map(\.size.height).max() ?? 1
        let scale = min(2, (rect.width - gap * CGFloat(images.count - 1)) / width, rect.height / height)
        var x = rect.midX - (width * scale + gap * CGFloat(images.count - 1)) / 2
        for image in images {
            let frame = CGRect(x: x, y: rect.midY - height * scale / 2, width: image.size.width * scale, height: image.size.height * scale)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 44, color: CGColor(gray: 0, alpha: 0.22))
                Promo.image(image, in: frame)
                ctx.restoreGState()
            }
            x += frame.width + gap
        }
    }
}
