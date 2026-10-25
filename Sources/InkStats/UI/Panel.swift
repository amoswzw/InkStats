import AppKit

/// The dropdown sheet shown under a status item.
final class PanelController {
    private let panel: NSPanel
    private let view = PanelView()
    private var clickMonitor: Any?
    private weak var anchor: NSStatusBarButton?
    private(set) var module: ModuleID?

    var onSettings: ((NSView, NSPoint) -> Void)? {
        get { view.onSettings }
        set { view.onSettings = newValue }
    }

    var onRange: ((GraphRange) -> Void)? {
        get { view.onRange }
        set { view.onRange = newValue }
    }

    var range: GraphRange {
        get { view.range }
        set { view.range = newValue }
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
        view.onQuit = { NSApp.terminate(nil) }
    }

    var isShown: Bool { panel.isVisible }

    func toggle(_ module: ModuleID, from button: NSStatusBarButton) {
        if isShown, self.module == module { hide(); return }
        self.module = module
        anchor = button
    }

    func show(_ spec: PanelSpec, painter: Painter, labels: LabelStyle, appearance: NSAppearance?) {
        view.spec = spec
        view.painter = painter
        view.labels = labels
        panel.appearance = appearance
        let height = view.requiredHeight()
        place(height: height)
        view.needsDisplay = true
        if !panel.isVisible {
            panel.orderFrontRegardless()
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.hide() }
        }
    }

    func hide() {
        panel.orderOut(nil)
        module = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func place(height: CGFloat) {
        guard let button = anchor, let window = button.window else { return }
        let anchorRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchorRect
        let x = min(max(anchorRect.minX, visible.minX + 8), visible.maxX - PanelView.width - 8)
        let top = anchorRect.minY - 6
        panel.setFrame(NSRect(x: x, y: top - height, width: PanelView.width, height: height), display: true)
    }
}

final class PanelView: NSView {
    static let width: CGFloat = 320
    private let pad: CGFloat = 16

    var spec: PanelSpec?
    var painter = Painter(theme: .ink, palette: .make(.ink, dark: false), texture: 1)
    var labels: LabelStyle = .chinese
    var range: GraphRange = .live
    var onSettings: ((NSView, NSPoint) -> Void)?
    var onQuit: (() -> Void)?
    var onRange: ((GraphRange) -> Void)?

    private var rangeRects: [GraphRange: CGRect] = [:]
    private var actionRects: [(CGRect, () -> Void)] = []
    private var settingsRect = CGRect.zero
    private var quitRect = CGRect.zero
    private var paperCache: (dark: Bool, image: CGImage)?

    override var isFlipped: Bool { true }

    func requiredHeight() -> CGFloat { layout(nil) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        _ = layout(ctx)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if settingsRect.contains(p) { onSettings?(self, CGPoint(x: settingsRect.minX, y: settingsRect.maxY + 4)) }
        else if quitRect.contains(p) { onQuit?() }
        else if let hit = rangeRects.first(where: { $0.value.contains(p) })?.key, hit != range { onRange?(hit) }
        else if let action = actionRects.first(where: { $0.0.contains(p) })?.1 { action() }
    }

    // MARK: Layout + drawing in one pass, so measured height always matches what is drawn.

    private func layout(_ ctx: CGContext?) -> CGFloat {
        guard let spec else { return 100 }
        let p = painter, pal = p.palette, ink = p.theme == .ink
        let inner = Self.width - pad * 2
        let seed = spec.module.rawValue.unicodeScalars.reduce(11) { $0 &* 31 &+ Int($1.value) }

        if let ctx { drawBackground(ctx, seed: seed) }
        var y = pad

        // Header: name, big value, and (ink) the seal.
        let names = spec.module.names
        let title = NSAttributedString.styled(names.chinese, p.fonts.chinese(ink ? 26 : 22), pal.ink)
        let english = NSAttributedString.styled(names.english, p.fonts.text(12), pal.sub)
        let big = NSAttributedString.styled(spec.big, p.fonts.number(ink ? 22 : 23), pal.ink)
        let headerHeight: CGFloat = 36
        if let ctx {
            let ts = title.size()
            title.draw(at: CGPoint(x: pad, y: y + (headerHeight - ts.height) / 2))
            english.draw(at: CGPoint(x: pad + ts.width + 8, y: y + (headerHeight - ts.height) / 2 + ts.height - english.size().height - 4))
            var right = Self.width - pad
            if ink {
                let seal = CGRect(x: right - 32, y: y + 2, width: 32, height: 32)
                InkBrush.seal(ctx, rect: seal, character: names.character, color: pal.red, font: Fonts.brush(22), seed: seed, texture: p.texture)
                right = seal.minX - 10
            }
            let bs = big.size()
            big.draw(at: CGPoint(x: right - bs.width, y: y + (headerHeight - bs.height) / 2))
        }
        y += headerHeight
        if !ink, let ctx { p.rule(ctx, from: CGPoint(x: pad, y: y + 3), to: CGPoint(x: Self.width - pad, y: y + 3), seed: seed + 401) }
        y += 6

        let sub = NSAttributedString.styled(spec.sub, p.fonts.text(12), pal.sub)
        sub.draw(at: CGPoint(x: pad, y: y))
        y += 22

        if let graph = spec.graph {
            let graphRect = CGRect(x: pad, y: y, width: inner, height: 104)
            if let ctx { drawGraph(ctx, graph, rect: graphRect, seed: seed) }
            y = graphRect.maxY + 10
        } else {
            rangeRects = [:]
        }

        if ctx != nil { actionRects = [] }
        for (i, extra) in spec.extras.enumerated() { y = drawExtra(ctx, extra, top: y, width: inner, seed: seed + 200 + i * 31) + 8 }

        for (index, row) in spec.rows.enumerated() {
            let rowHeight: CGFloat = 26
            if let ctx {
                let primary = labels == .chinese ? row.chinese : row.english
                let secondary = labels == .chinese ? row.english : row.chinese
                let primaryFont = labels == .chinese ? p.fonts.chinese(ink ? 17 : 14) : p.fonts.text(13)
                let label = NSAttributedString.styled(primary, primaryFont, pal.ink)
                let ls = label.size()
                label.draw(at: CGPoint(x: pad, y: y + (rowHeight - ls.height) / 2))
                let note = NSAttributedString.styled(secondary, labels == .chinese ? p.fonts.text(10) : Fonts.serif(10), pal.sub)
                note.draw(at: CGPoint(x: pad + ls.width + 6, y: y + (rowHeight - note.size().height) / 2 + 1))
                let value = NSAttributedString.styled(row.value, p.fonts.number(13), pal.ink)
                let vs = value.size()
                value.draw(at: CGPoint(x: Self.width - pad - vs.width, y: y + (rowHeight - vs.height) / 2))
                if index < spec.rows.count - 1 {
                    ctx.saveGState()
                    ctx.setStrokeColor(pal.ink.copy(alpha: 0.14)!)
                    ctx.setLineDash(phase: 0, lengths: [2, 3])
                    ctx.move(to: CGPoint(x: pad, y: y + rowHeight - 0.5))
                    ctx.addLine(to: CGPoint(x: Self.width - pad, y: y + rowHeight - 0.5))
                    ctx.strokePath()
                    ctx.restoreGState()
                }
            }
            y += rowHeight
        }
        for (i, extra) in spec.after.enumerated() { y = drawExtra(ctx, extra, top: y + 8, width: inner, seed: seed + 600 + i * 31) }

        // Footer actions.
        y += 8
        let settings = NSAttributedString.styled(labels == .chinese ? "设置 Settings" : "Settings", p.fonts.text(11), pal.sub)
        let quit = NSAttributedString.styled(labels == .chinese ? "退出 Quit" : "Quit", p.fonts.text(11), pal.sub)
        settingsRect = CGRect(origin: CGPoint(x: pad, y: y), size: settings.size()).insetBy(dx: -4, dy: -3)
        quitRect = CGRect(origin: CGPoint(x: Self.width - pad - quit.size().width, y: y), size: quit.size()).insetBy(dx: -4, dy: -3)
        if ctx != nil {
            settings.draw(at: CGPoint(x: pad, y: y))
            quit.draw(at: quitRect.origin.applying(CGAffineTransform(translationX: 4, y: 3)))
        }
        y += settings.size().height + pad
        return ceil(y)
    }

    private func drawBackground(_ ctx: CGContext, seed: Int) {
        let pal = painter.palette
        let rect = bounds
        switch painter.theme {
        case .ink:
            let shape = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            ctx.setFillColor(pal.paper)
            ctx.fill(rect)
            if paperCache?.dark != pal.isDark, let tile = InkBrush.paperTile(pal) { paperCache = (pal.isDark, tile) }
            if let tile = paperCache?.image {
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
            }
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setStrokeColor(pal.ink.copy(alpha: 0.12)!)
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        case .sketch:
            ctx.setFillColor(pal.paper)
            ctx.fill(rect)
            painter.outline(ctx, rect.insetBy(dx: 3, dy: 3), color: pal.ink, width: 1.6, seed: seed + 400, roughness: min(1.2, painter.texture))
        }
    }

    private func drawGraph(_ ctx: CGContext, _ g: GraphSpec, rect: CGRect, seed: Int) {
        let p = painter, pal = p.palette
        let plot = CGRect(x: rect.minX, y: rect.minY + 18, width: rect.width, height: rect.height - 22)
        let tiny = p.fonts.text(10)

        // Range chips on the left; the selected one is underlined in the theme's own stroke.
        var chipX = rect.minX
        rangeRects = [:]
        if let caption = g.caption {
            NSAttributedString.styled(caption, p.fonts.text(10.5), pal.sub).draw(at: CGPoint(x: chipX, y: rect.minY))
        }
        for option in GraphRange.allCases where g.caption == nil {
            let selected = option == range
            let text = NSAttributedString.styled(option.title, p.fonts.text(10.5), selected ? pal.ink : pal.sub)
            let size = text.size()
            text.draw(at: CGPoint(x: chipX, y: rect.minY))
            if selected {
                p.line(ctx, [CGPoint(x: chipX, y: rect.minY + size.height + 1), CGPoint(x: chipX + size.width, y: rect.minY + size.height + 0.5)],
                       hue: .red, width: 1.4, seed: seed + 900, small: true)
            }
            rangeRects[option] = CGRect(x: chipX - 3, y: rect.minY - 3, width: size.width + 6, height: size.height + 6)
            chipX += size.width + 10
        }
        if let label = g.maxLabel {
            NSAttributedString.styled(label, p.fonts.text(9), pal.sub.copy(alpha: 0.8)!).draw(at: CGPoint(x: plot.minX + 1, y: plot.minY))
        }
        var x = rect.maxX
        for (hue, name) in g.legend.reversed() {
            let text = NSAttributedString.styled(name, tiny, pal.sub)
            x -= text.size().width
            text.draw(at: CGPoint(x: x, y: rect.minY))
            x -= 14
            p.line(ctx, [CGPoint(x: x, y: rect.minY + 7), CGPoint(x: x + 5, y: rect.minY + 6.5), CGPoint(x: x + 10, y: rect.minY + 7)],
                   hue: hue, width: 2, seed: 5, small: true)
            x -= 10
        }

        ctx.saveGState()
        ctx.setStrokeColor(pal.ink.copy(alpha: 0.1)!)
        ctx.setLineDash(phase: 0, lengths: [2, 4])
        ctx.move(to: CGPoint(x: plot.minX, y: plot.midY))
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        ctx.strokePath()
        ctx.restoreGState()

        var hasData = false
        for (index, series) in g.series.enumerated() {
            let runs = segments(series.values, in: plot, min: g.minValue, max: g.maxValue)
            for (r, points) in runs.enumerated() {
                hasData = true
                let runSeed = seed + index * 13 + r * 101
                if series.area { p.area(ctx, points, base: plot.maxY, hue: series.hue, strength: index == 0 ? 1 : 0.6, seed: runSeed) }
                p.line(ctx, points, hue: series.hue, width: index == 0 ? 2.4 : 1.6, seed: runSeed + 5)
            }
            if index == 0, g.caption == nil, let end = runs.last?.last, series.values.last.flatMap({ $0 }) != nil {
                p.dot(ctx, CGPoint(x: end.x - 3, y: end.y), radius: 2.6, seed: seed + 7)
            }
        }
        if let marker = g.marker, let values = g.series.first?.values, values.count >= 2 {
            let position = min(max(marker, 0), 1) * Double(values.count - 1)
            let index = Int(position), next = min(index + 1, values.count - 1)
            if let a = values[index], let b = values[next] {
                let value = a + (b - a) * (position - Double(index))
                let t = CGFloat(min(max((value - g.minValue) / max(g.maxValue - g.minValue, 0.0001), 0), 1))
                p.dot(ctx, CGPoint(x: plot.minX + CGFloat(marker) * plot.width, y: plot.maxY - t * plot.height), radius: 2.6, seed: seed + 7)
            }
        }
        if !hasData {
            let text = NSAttributedString.styled(g.emptyText, p.fonts.text(11), pal.sub)
            let size = text.size()
            text.draw(at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2))
        }
    }

    /// Splits a series at missing values (times the app wasn't running) into separate runs.
    private func segments(_ values: [Double?], in rect: CGRect, min lo: Double, max hi: Double) -> [[CGPoint]] {
        guard values.count >= 2 else { return values.compactMap { $0 }.isEmpty ? [] : [sparkPoints(values.compactMap { $0 }, in: rect, min: lo, max: hi)] }
        let span = max(hi - lo, 0.0001)
        let step = rect.width / CGFloat(values.count - 1)
        var runs: [[CGPoint]] = [], current: [CGPoint] = []
        // A lone sample becomes a short tick so it stays visible.
        func close() {
            if current.count == 1, let p = current.first { current = [CGPoint(x: p.x - step / 2, y: p.y), p] }
            if current.count >= 2 { runs.append(current) }
            current = []
        }
        for (i, value) in values.enumerated() {
            guard let value else { close(); continue }
            let t = CGFloat(min(max((value - lo) / span, 0), 1))
            current.append(CGPoint(x: rect.minX + CGFloat(i) * step, y: rect.maxY - t * rect.height))
        }
        close()
        return runs
    }

    /// Draws (or just measures, when `ctx` is nil) the module-specific section. Returns its bottom edge.
    private func drawExtra(_ ctx: CGContext?, _ extra: PanelExtra, top: CGFloat, width: CGFloat, seed: Int) -> CGFloat {
        let p = painter, pal = p.palette, ink = p.theme == .ink
        let tiny = p.fonts.text(10)
        switch extra {
        case let .cores(values, clusters):
            let height: CGFloat = 62
            guard let ctx, !values.isEmpty else { return top + height }
            let gap: CGFloat = values.count > 12 ? 3 : 4
            let barWidth = (width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            let clusterOf = Dictionary(clusters.enumerated().flatMap { index, c in c.cpus.map { ($0, index) } }, uniquingKeysWith: { a, _ in a })
            let hues: [Hue] = [.ink, .a, .b]
            for (i, v) in values.enumerated() {
                let hue = hues[(clusterOf[i] ?? 0) % hues.count]
                p.bar(ctx, CGRect(x: pad + CGFloat(i) * (barWidth + gap), y: top, width: barWidth, height: 44), fraction: v / 100, hue: hue, seed: seed + i * 3, vertical: true)
            }
            for (index, cluster) in clusters.enumerated() {
                guard let first = cluster.cpus.min(), first < values.count else { continue }
                let label = NSAttributedString.styled("\(cluster.name) ×\(cluster.cpus.count)", tiny, p.stroke(hues[index % hues.count]))
                label.draw(at: CGPoint(x: pad + CGFloat(first) * (barWidth + gap), y: top + 48))
            }
            return top + height

        case let .stack(parts, total):
            let rect = CGRect(x: pad, y: top + 4, width: width, height: 16)
            guard let ctx, total > 0 else { return top + 26 }
            if ink {
                ctx.setFillColor(pal.ink.copy(alpha: 0.07)!)
                ctx.fill(rect)
            } else {
                p.outline(ctx, rect, color: pal.ink.copy(alpha: 0.35)!, seed: seed, small: true)
            }
            var x = rect.minX
            for (i, part) in parts.enumerated() {
                let w = CGFloat(part.0 / total) * rect.width
                guard w > 1 else { continue }
                let segment = CGRect(x: x, y: rect.minY, width: w, height: rect.height)
                if ink {
                    InkBrush.stroke(ctx, [CGPoint(x: segment.minX + 1, y: segment.midY), CGPoint(x: segment.midX, y: segment.midY - 0.3), CGPoint(x: segment.maxX - 1, y: segment.midY)],
                                    width: 13, color: p.stroke(part.1), paper: pal.paper, seed: seed + i * 5, texture: p.texture)
                } else {
                    var g = RoughGenerator(RoughOptions(roughness: p.texture * 0.5, hachureGap: 2.5, seed: Int32(truncatingIfNeeded: seed + i * 5)))
                    ctx.strokeRough(g.hachure([CGPoint(x: segment.minX, y: segment.minY), CGPoint(x: segment.maxX, y: segment.minY),
                                               CGPoint(x: segment.maxX, y: segment.maxY), CGPoint(x: segment.minX, y: segment.maxY)]),
                                    color: p.fill(part.1), width: 0.9)
                    p.outline(ctx, segment, color: p.stroke(part.1), seed: seed + i * 5 + 1, small: true)
                }
                x += w
            }
            return top + 26

        case let .gauges(section):
            let rowHeight: CGFloat = 25, titleHeight: CGFloat = 22
            let hasTitle = section.english != nil
            let total = top + (hasTitle ? titleHeight : 0) + CGFloat(section.lines.count) * rowHeight
            guard let ctx else { return total }
            var y = top
            if let english = section.english {
                drawTitle(ctx, chinese: section.chinese ?? english, english: english, top: y, width: width, seed: seed)
                y += titleHeight
            }
            let labelWidth: CGFloat = section.wideLabels ? 150 : 112, valueWidth: CGFloat = 76
            for (index, line) in section.lines.enumerated() {
                let text = labels == .chinese ? line.chinese : line.english
                let font = labels == .chinese && line.chinese != line.english ? p.fonts.chinese(ink ? 16 : 13) : p.fonts.text(12)
                var name = NSAttributedString.styled(text, font, pal.ink)
                let maxName = (line.fraction == nil ? width - valueWidth : labelWidth) - 6
                if name.size().width > maxName {
                    var trimmed = text
                    while trimmed.count > 1, NSAttributedString.styled(trimmed + "…", font, pal.ink).size().width > maxName { trimmed.removeLast() }
                    name = NSAttributedString.styled(trimmed + "…", font, pal.ink)
                }
                name.draw(at: CGPoint(x: pad, y: y + (rowHeight - name.size().height) / 2))
                if let fraction = line.fraction {
                    p.bar(ctx, CGRect(x: pad + labelWidth, y: y + rowHeight / 2 - 5, width: width - labelWidth - valueWidth, height: 10),
                          fraction: fraction, hue: line.hue, seed: seed + index * 17)
                }
                var valueRight = pad + width
                if let action = line.action {
                    let symbol = NSAttributedString.styled(action.symbol, p.fonts.text(13), pal.red)
                    let ss = symbol.size()
                    let rect = CGRect(x: valueRight - ss.width, y: y + (rowHeight - ss.height) / 2, width: ss.width, height: ss.height)
                    symbol.draw(at: rect.origin)
                    actionRects.append((rect.insetBy(dx: -5, dy: -4), action.run))
                    valueRight = rect.minX - 6
                }
                let value = NSAttributedString.styled(line.value, p.fonts.number(12.5), pal.ink)
                value.draw(at: CGPoint(x: valueRight - value.size().width, y: y + (rowHeight - value.size().height) / 2))
                y += rowHeight
            }
            return total

        case let .forecast(days):
            let rowHeight: CGFloat = 24, titleHeight: CGFloat = 22
            let total = top + titleHeight + CGFloat(days.count) * rowHeight
            guard let ctx, let low = days.map(\.low).min(), let high = days.map(\.high).max() else { return total }
            drawTitle(ctx, chinese: "七日预报", english: "7-day forecast", top: top, width: width, seed: seed)
            let span = max(high - low, 1)
            let barLeft = pad + 146, barRight = pad + width - 36
            for (index, day) in days.enumerated() {
                let y = top + titleHeight + CGFloat(index) * rowHeight, mid = y + rowHeight / 2
                let font = labels == .chinese ? p.fonts.chinese(ink ? 16 : 13) : p.fonts.text(12)
                let name = NSAttributedString.styled(labels == .chinese ? day.chinese : day.english, font, pal.ink)
                name.draw(at: CGPoint(x: pad, y: mid - name.size().height / 2))
                p.weatherGlyph(ctx, day.condition, day: true, in: CGRect(x: pad + 52, y: mid - 8, width: 16, height: 16), seed: seed + index * 23)
                if let chance = day.precipitationChance, chance >= 20 {
                    let text = NSAttributedString.styled("\(chance)%", tiny, p.stroke(.a))
                    text.draw(at: CGPoint(x: pad + 74, y: mid - text.size().height / 2))
                }
                let lowText = NSAttributedString.styled(Format.temperature(day.low), p.fonts.number(12.5), pal.sub)
                lowText.draw(at: CGPoint(x: barLeft - 6 - lowText.size().width, y: mid - lowText.size().height / 2))
                let highText = NSAttributedString.styled(Format.temperature(day.high), p.fonts.number(12.5), pal.ink)
                highText.draw(at: CGPoint(x: barRight + 6, y: mid - highText.size().height / 2))

                ctx.saveGState()
                ctx.setStrokeColor(pal.ink.copy(alpha: 0.1)!)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: barLeft, y: mid))
                ctx.addLine(to: CGPoint(x: barRight, y: mid))
                ctx.strokePath()
                ctx.restoreGState()
                let x0 = barLeft + CGFloat((day.low - low) / span) * (barRight - barLeft)
                let x1 = max(x0 + 4, barLeft + CGFloat((day.high - low) / span) * (barRight - barLeft))
                p.line(ctx, [CGPoint(x: x0, y: mid), CGPoint(x: (x0 + x1) / 2, y: mid - 0.3), CGPoint(x: x1, y: mid)],
                       hue: .c, width: ink ? 5 : 3, seed: seed + index * 23 + 9, small: true)
            }
            return total

        case let .month(date, phase):
            let calendar = Calendar.current
            let chinese = labels == .chinese
            let titleHeight: CGFloat = 24, headerHeight: CGFloat = 18, cellHeight: CGFloat = chinese ? 32 : 24
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
            let dayCount = calendar.range(of: .day, in: .month, for: date)!.count
            let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
            let rows = (lead + dayCount + 6) / 7
            let total = top + titleHeight + headerHeight + CGFloat(rows) * cellHeight
            guard let ctx else { return total }

            let monthFormat = DateFormatter()
            monthFormat.locale = chinese ? Locale(identifier: "zh_CN") : .current
            monthFormat.setLocalizedDateFormatFromTemplate("yMMMM")
            let title = chinese
                ? NSAttributedString.styled(monthFormat.string(from: date), p.fonts.chinese(ink ? 15 : 13), pal.sub)
                : NSAttributedString.styled(monthFormat.string(from: date), p.fonts.text(11), pal.sub)
            title.draw(at: CGPoint(x: pad, y: top + 2))
            let moonRect = CGRect(x: pad + width - 16, y: top + 1, width: 16, height: 16)
            p.moonGlyph(ctx, phase: phase, in: moonRect, seed: seed + 70)
            let moonName = Sky.moonName(phase)
            let moonText = NSAttributedString.styled(chinese ? moonName.chinese : moonName.english, tiny, pal.sub)
            let moonTextX = moonRect.minX - 6 - moonText.size().width
            moonText.draw(at: CGPoint(x: moonTextX, y: top + 9 - moonText.size().height / 2))
            p.rule(ctx, from: CGPoint(x: pad + title.size().width + 8, y: top + 11), to: CGPoint(x: moonTextX - 8, y: top + 11), seed: seed + 50)

            let cellWidth = width / 7
            let symbols = chinese ? ["日", "一", "二", "三", "四", "五", "六"] : calendar.veryShortStandaloneWeekdaySymbols
            for column in 0..<7 {
                let symbol = NSAttributedString.styled(symbols[(column + calendar.firstWeekday - 1) % 7], tiny, pal.sub)
                symbol.draw(at: CGPoint(x: pad + (CGFloat(column) + 0.5) * cellWidth - symbol.size().width / 2, y: top + titleHeight))
            }
            let gridTop = top + titleHeight + headerHeight
            let today = calendar.component(.day, from: date)
            for day in 1...dayCount {
                let index = lead + day - 1
                let center = CGPoint(x: pad + (CGFloat(index % 7) + 0.5) * cellWidth, y: gridTop + (CGFloat(index / 7) + 0.5) * cellHeight)
                let numberY = chinese ? center.y - 7 : center.y
                let number = NSAttributedString.styled("\(day)", p.fonts.number(12), pal.ink)
                number.draw(at: CGPoint(x: center.x - number.size().width / 2, y: numberY - number.size().height / 2))
                if day == today {
                    let ring = (0...16).map { i -> CGPoint in
                        let a = CGFloat(i) / 16 * 2 * .pi - 0.4
                        return CGPoint(x: center.x + cos(a) * 12, y: center.y + sin(a) * (chinese ? 15 : 10.5))
                    }
                    p.line(ctx, ring, hue: .red, width: 1.4, seed: seed + 90, small: true)
                }
                if chinese, let dayDate = calendar.date(byAdding: .day, value: day - 1, to: first) {
                    let lunarDay = Lunar.day(dayDate)
                    let text = lunarDay == 1 ? Lunar.month(dayDate) : Lunar.dayName(lunarDay)
                    let lunar = NSAttributedString.styled(text, p.fonts.chinese(9), lunarDay == 1 ? pal.red : pal.sub)
                    lunar.draw(at: CGPoint(x: center.x - lunar.size().width / 2, y: center.y + 1))
                }
            }
            return total
        }
    }

    private func drawTitle(_ ctx: CGContext, chinese: String, english: String, top: CGFloat, width: CGFloat, seed: Int) {
        let p = painter, pal = p.palette
        let title = labels == .chinese
            ? NSAttributedString.styled(chinese, p.fonts.chinese(p.theme == .ink ? 15 : 13), pal.sub)
            : NSAttributedString.styled(english, p.fonts.text(11), pal.sub)
        title.draw(at: CGPoint(x: pad, y: top + 2))
        p.rule(ctx, from: CGPoint(x: pad + title.size().width + 8, y: top + 11), to: CGPoint(x: pad + width, y: top + 11), seed: seed + 50)
    }
}
