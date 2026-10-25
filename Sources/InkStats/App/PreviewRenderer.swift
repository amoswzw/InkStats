import AppKit
import SwiftUI

/// `InkStats --render-preview <folder>` samples live data for a few seconds, then writes
/// every menu bar item and panel, in both themes and appearances, as PNG files.
enum PreviewRenderer {
    static func run(output: URL) {
        Fonts.registerBundled()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        renderSettings(SettingsView(), to: output.appendingPathComponent("settings.png"))

        renderGlyphs(to: output.appendingPathComponent("weather-glyphs.png"))
        // Only fetches when a place has been chosen in Settings → Weather.
        WeatherService.shared.refreshIfNeeded(enabled: true, place: Settings.shared.weatherPlace)

        let sampler = Sampler(), history = History(persist: false)
        sampler.setWantsProcesses(true)
        sampler.setWantsTraffic(true)
        var snapshot = Snapshot()
        for _ in 0..<24 {
            snapshot = sampler.sample()
            history.record(snapshot)
            usleep(250_000)
        }

        renderStored(.cpu, .hour, snapshot, to: output.appendingPathComponent("panel-cpu-1h.png"))
        renderStored(.battery, .week, snapshot, to: output.appendingPathComponent("panel-battery-7d.png"))
        LiveData.shared.snapshot = snapshot
        renderSettings(SensorsSettings(), to: output.appendingPathComponent("settings-sensors.png"))
        renderSettings(AlertsSettings(), to: output.appendingPathComponent("settings-alerts.png"))
        renderSettings(WeatherSettings(), to: output.appendingPathComponent("settings-weather.png"))
        renderSettings(ClockSettings(), to: output.appendingPathComponent("settings-clock.png"))

        for theme in ThemeID.allCases {
            for dark in [false, true] {
                let painter = Painter(theme: theme, palette: .make(theme, dark: dark), texture: 1)
                let suffix = "\(theme.rawValue)-\(dark ? "dark" : "light")"
                let modules = ModuleID.allCases.filter { $0 != .battery || snapshot.battery.present }

                let images = modules.map { StatusBarController.image($0, parts: barParts($0, snapshot, history), painter: painter, labels: theme.defaultLabels) }
                let width = images.reduce(16) { $0 + $1.size.width + 12 }
                let strip = NSImage(size: NSSize(width: width, height: 26), flipped: true) { rect in
                    (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                    rect.fill()
                    var x: CGFloat = 8
                    for image in images {
                        image.draw(in: NSRect(x: x, y: 2, width: image.size.width, height: image.size.height))
                        x += image.size.width + 12
                    }
                    return true
                }
                write(strip, to: output.appendingPathComponent("menubar-\(suffix).png"))

                for module in modules {
                    let view = PanelView()
                    view.spec = panelSpec(module, snapshot, history)
                    view.painter = painter
                    view.labels = theme.defaultLabels
                    view.frame = NSRect(x: 0, y: 0, width: PanelView.width, height: view.requiredHeight())
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("panel-\(module.rawValue)-\(suffix).png"))
                }
            }
        }
    }

    /// Every weather condition, day and night, in both themes and appearances.
    private static func renderGlyphs(to url: URL) {
        let conditions: [WeatherCondition] = [.clear, .partlyCloudy, .cloudy, .fog, .drizzle, .rain, .snow, .thunder]
        let cell: CGFloat = 40
        let image = NSImage(size: NSSize(width: cell * CGFloat(conditions.count * 2), height: cell * 4), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            for (row, (theme, dark)) in [(ThemeID.ink, false), (.ink, true), (.sketch, false), (.sketch, true)].enumerated() {
                let painter = Painter(theme: theme, palette: .make(theme, dark: dark), texture: 1)
                ctx.setFillColor(painter.palette.paper)
                ctx.fill(CGRect(x: 0, y: CGFloat(row) * cell, width: cell * CGFloat(conditions.count * 2), height: cell))
                for (i, condition) in conditions.enumerated() {
                    for (j, day) in [true, false].enumerated() {
                        let rect = CGRect(x: CGFloat(i * 2 + j) * cell + 6, y: CGFloat(row) * cell + 6, width: cell - 12, height: cell - 12)
                        painter.weatherGlyph(ctx, condition, day: day, in: rect, seed: i * 2 + j)
                    }
                }
            }
            return true
        }
        write(image, to: url)
    }

    /// A panel whose graph reads saved history instead of live samples.
    private static func renderStored(_ module: ModuleID, _ range: GraphRange, _ snapshot: Snapshot, to url: URL) {
        let view = PanelView()
        view.range = range
        view.spec = panelSpec(module, snapshot, StoredSeries(range: range))
        view.painter = Painter(theme: .ink, palette: .make(.ink, dark: false), texture: 1)
        view.labels = .chinese
        view.frame = NSRect(x: 0, y: 0, width: PanelView.width, height: view.requiredHeight())
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func renderSettings<V: View>(_ root: V, to url: URL) {
        let view = NSHostingView(rootView: root.frame(width: 480))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func write(_ image: NSImage, to url: URL) {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale), pixelsHigh: Int(image.size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
