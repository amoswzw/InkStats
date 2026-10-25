import AppKit

/// One status item per enabled module, or a single combined item, drawn in the active theme.
final class StatusBarController {
    private static let combinedID = "combined"
    private static let combinedGap: CGFloat = 10

    private var items: [String: NSStatusItem] = [:]
    private var order: [ModuleID] = []
    private var combined = false
    /// Horizontal extent of each module inside the combined item, for click routing.
    private var segments: [(ModuleID, ClosedRange<CGFloat>)] = []

    var onClick: ((ModuleID, NSStatusBarButton) -> Void)?
    var onRightClick: ((NSStatusBarButton) -> Void)?

    func setModules(_ modules: [ModuleID], combined: Bool) {
        guard modules != order || combined != self.combined else { return }
        items.values.forEach { NSStatusBar.system.removeStatusItem($0) }
        items.removeAll()
        // New status items appear to the left of existing ones, so add in reverse.
        let ids = combined ? (modules.isEmpty ? [] : [Self.combinedID]) : modules.reversed().map(\.rawValue)
        for id in ids {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "inkstats.\(id)"
            if let button = item.button {
                button.identifier = NSUserInterfaceItemIdentifier(id)
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.setAccessibilityLabel(ModuleID(rawValue: id)?.names.english ?? "InkStats")
            }
            items[id] = item
        }
        order = modules
        self.combined = combined
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp { onRightClick?(sender); return }
        if id == Self.combinedID {
            // Accessibility presses (VoiceOver) carry no mouse position; they open the first panel.
            guard let event, event.type == .leftMouseUp else {
                if let first = segments.first?.0 { onClick?(first, sender) }
                return
            }
            let x = sender.convert(event.locationInWindow, from: nil).x
            let hit = segments.first { $0.1.contains(x) }?.0 ?? segments.min { abs($0.1.lowerBound - x) < abs($1.1.lowerBound - x) }?.0
            if let hit { onClick?(hit, sender) }
        } else if let module = ModuleID(rawValue: id) {
            onClick?(module, sender)
        }
    }

    func render(_ snapshot: Snapshot, _ history: History, settings: Settings, highlighted: ModuleID?) {
        for (id, item) in items {
            guard let button = item.button else { continue }
            let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let painter = Painter(theme: settings.theme, palette: Palette.make(settings.theme, dark: dark), texture: CGFloat(settings.texture))
            if id == Self.combinedID {
                let images = order.map { ($0, Self.image($0, parts: barParts($0, snapshot, history), painter: painter, labels: settings.labelStyle)) }
                button.image = combine(images)
                button.highlight(highlighted != nil)
            } else if let module = ModuleID(rawValue: id) {
                button.image = Self.image(module, parts: barParts(module, snapshot, history), painter: painter, labels: settings.labelStyle)
                button.highlight(module == highlighted)
            }
        }
    }

    private func combine(_ images: [(ModuleID, NSImage)]) -> NSImage {
        let gap = Self.combinedGap
        let width = images.reduce(0) { $0 + $1.1.size.width } + gap * CGFloat(max(0, images.count - 1))
        var x: CGFloat = 0
        segments = images.map { module, image in
            defer { x += image.size.width + gap }
            return (module, (x - gap / 2)...(x + image.size.width + gap / 2))
        }
        let result = NSImage(size: NSSize(width: max(1, width), height: 22), flipped: true) { _ in
            var x: CGFloat = 0
            for (_, image) in images {
                image.draw(in: NSRect(x: x, y: 0, width: image.size.width, height: image.size.height))
                x += image.size.width + gap
            }
            return true
        }
        result.isTemplate = false
        return result
    }

    static func image(_ module: ModuleID, parts: [BarPart], painter: Painter, labels: LabelStyle) -> NSImage {
        let height: CGFloat = 22, gap: CGFloat = 4
        let ink = painter.theme == .ink
        let palette = painter.palette

        let label: NSAttributedString? = {
            let hasGlyph = parts.contains { if case .weather = $0 { return true } else { return false } }
            if module == .battery || module == .time || hasGlyph { return nil }
            if labels == .chinese {
                return .styled(module.names.character, painter.fonts.chinese(ink ? 15 : 13), palette.ink)
            }
            let font = ink ? Fonts.serif(9, weight: .semibold) : Fonts.hand(10)
            return .styled(module.names.tag, font, palette.sub)
        }()
        let number = painter.fonts.number(ink ? 12.5 : 13)
        let small = painter.fonts.text(ink ? 9 : 9.5)

        let widths: [CGFloat] = parts.map { part in
            switch part {
            case .spark: return 30
            case .meter: return 6
            case .battery: return 22
            case .weather: return 18
            case .text(let s): return ceil(NSAttributedString.styled(s, number, palette.ink).size().width)
            case .twoLines(let a, let b):
                return ceil(max(NSAttributedString.styled(a, small, palette.ink).size().width,
                                NSAttributedString.styled(b, small, palette.ink).size().width, 38))
            }
        }
        let labelWidth = label.map { ceil($0.size().width) } ?? 0
        let count = CGFloat(parts.count + (label == nil ? 0 : 1))
        let width = labelWidth + widths.reduce(0, +) + gap * max(0, count - 1) + 4

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 2
            if let label {
                let size = label.size()
                label.draw(at: CGPoint(x: x, y: (height - size.height) / 2))
                x += labelWidth + gap
            }
            let seedBase = module.rawValue.unicodeScalars.reduce(7) { $0 &* 31 &+ Int($1.value) }
            for (index, part) in parts.enumerated() {
                let w = widths[index], seed = seedBase &+ index * 7
                switch part {
                case let .spark(values, minValue, maxValue):
                    let rect = CGRect(x: x, y: 4, width: w, height: 14)
                    let points = sparkPoints(values, in: rect, min: minValue, max: maxValue)
                    painter.area(ctx, points, base: rect.maxY, hue: .ink, strength: 0.9, seed: seed, small: true)
                    painter.line(ctx, points, hue: .ink, width: ink ? 1.4 : 1.2, seed: seed + 3, small: true)
                case .meter(let fraction):
                    painter.bar(ctx, CGRect(x: x, y: 4, width: w, height: 14), fraction: fraction, hue: ink ? .ink : .violet, seed: seed, vertical: true)
                case .battery(let fraction):
                    painter.battery(ctx, CGRect(x: x, y: 6, width: w, height: 10), fraction: fraction, seed: seed)
                case let .weather(condition, day):
                    painter.weatherGlyph(ctx, condition, day: day, in: CGRect(x: x, y: 2, width: w, height: w), seed: seed)
                case .text(let s):
                    let text = NSAttributedString.styled(s, number, palette.ink)
                    text.draw(at: CGPoint(x: x, y: (height - text.size().height) / 2))
                case let .twoLines(a, b):
                    NSAttributedString.styled(a, small, palette.ink).draw(at: CGPoint(x: x, y: 0))
                    NSAttributedString.styled(b, small, palette.ink).draw(at: CGPoint(x: x, y: 10))
                }
                x += w + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

func sparkPoints(_ values: [Double], in rect: CGRect, min lo: Double, max hi: Double) -> [CGPoint] {
    let data = values.count >= 2 ? values : Array(repeating: values.first ?? lo, count: 2)
    let span = max(hi - lo, 0.0001)
    return data.enumerated().map { i, v in
        let t = CGFloat(min(max((v - lo) / span, 0), 1))
        return CGPoint(x: rect.minX + CGFloat(i) / CGFloat(data.count - 1) * rect.width, y: rect.maxY - t * rect.height)
    }
}
