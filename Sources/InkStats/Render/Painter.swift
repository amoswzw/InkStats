import AppKit

enum Hue {
    case ink, a, b, c, green, violet, red
}

/// Draws chart primitives in the active theme. All coordinates are top-left origin.
struct Painter {
    let theme: ThemeID
    let palette: Palette
    let texture: CGFloat

    var fonts: ThemeFonts { ThemeFonts(theme: theme) }

    func stroke(_ hue: Hue) -> CGColor {
        switch hue {
        case .ink: return palette.ink
        case .a: return palette.a
        case .b: return palette.b
        case .c: return palette.c
        case .green: return palette.green
        case .violet: return palette.violet
        case .red: return palette.red
        }
    }

    func fill(_ hue: Hue) -> CGColor {
        switch hue {
        case .ink: return theme == .ink ? palette.ink : palette.aFill
        case .a: return palette.aFill
        case .b: return palette.bFill
        case .c: return palette.cFill
        case .green: return palette.greenFill
        case .violet: return palette.violetFill
        case .red: return palette.bFill
        }
    }

    private func rough(seed: Int, small: Bool, roughness: CGFloat? = nil, width: CGFloat = 1, gap: CGFloat = -1) -> RoughGenerator {
        var o = RoughOptions()
        o.roughness = roughness ?? texture * (small ? 0.5 : 1)
        o.strokeWidth = width
        o.hachureGap = gap
        o.seed = Int32(truncatingIfNeeded: seed)
        return RoughGenerator(o)
    }

    func line(_ ctx: CGContext, _ points: [CGPoint], hue: Hue, width: CGFloat, seed: Int, small: Bool = false) {
        switch theme {
        case .ink:
            InkBrush.stroke(ctx, points, width: width, color: stroke(hue), paper: small ? nil : palette.paper, seed: seed, texture: texture)
        case .sketch:
            var g = rough(seed: seed, small: small, roughness: texture * (small ? 0.35 : 0.7))
            g.o.bowing = 0.5
            ctx.strokeRough(g.curve(points), color: stroke(hue), width: width * 0.75)
        }
    }

    func area(_ ctx: CGContext, _ points: [CGPoint], base: CGFloat, hue: Hue, strength: CGFloat = 1, seed: Int, small: Bool = false) {
        guard let first = points.first, let last = points.last else { return }
        switch theme {
        case .ink:
            // Light ink on dark paper reads much stronger than dark ink on light paper.
            InkBrush.wash(ctx, points, base: base, color: fill(hue), alpha: (palette.isDark ? 0.18 : 0.34) * strength)
        case .sketch:
            var g = rough(seed: seed, small: small, roughness: texture * 0.6, gap: small ? 2.6 : 4)
            let polygon = points + [CGPoint(x: last.x, y: base), CGPoint(x: first.x, y: base)]
            ctx.strokeRough(g.hachure(polygon), color: fill(hue), width: small ? 0.7 : 1)
        }
    }

    /// A gauge bar. Ink draws it as one brush stroke; sketch as a hachured rectangle.
    func bar(_ ctx: CGContext, _ rect: CGRect, fraction: Double, hue: Hue, seed: Int, vertical: Bool = false) {
        let f = CGFloat(min(max(fraction, 0), 1))
        switch theme {
        case .ink:
            ctx.saveGState()
            ctx.setFillColor(palette.ink.copy(alpha: 0.07)!)
            ctx.fill(rect)
            ctx.restoreGState()
            guard f > 0.005 else { return }
            var rng = InkRandom(seed: seed)
            if vertical {
                let w = min(rect.width * 0.6, 7), length = max(3, rect.height * f), x = rect.midX
                let pts = [CGPoint(x: x + (rng.next() - 0.5) * w * 0.2, y: rect.maxY - 1),
                           CGPoint(x: x + (rng.next() - 0.5) * w * 0.15, y: rect.maxY - length / 2),
                           CGPoint(x: x + (rng.next() - 0.5) * w * 0.2, y: rect.maxY - length + 1)]
                InkBrush.stroke(ctx, pts, width: w, color: stroke(hue), paper: palette.paper, seed: seed, texture: texture)
            } else {
                let length = max(rect.height, rect.width * f), y = rect.midY
                let pts = [CGPoint(x: rect.minX + 1, y: y + (rng.next() - 0.5) * rect.height * 0.15),
                           CGPoint(x: rect.minX + length / 2, y: y + (rng.next() - 0.5) * rect.height * 0.1),
                           CGPoint(x: rect.minX + length - 1, y: y + (rng.next() - 0.5) * rect.height * 0.15)]
                InkBrush.stroke(ctx, pts, width: rect.height * 0.85, color: stroke(hue), paper: palette.paper, seed: seed, texture: texture)
            }
        case .sketch:
            outline(ctx, rect, color: palette.ink.copy(alpha: 0.35)!, seed: seed + 1, small: true)
            guard f > 0.005 else { return }
            let filled = vertical
                ? CGRect(x: rect.minX, y: rect.maxY - max(2, rect.height * f), width: rect.width, height: max(2, rect.height * f))
                : CGRect(x: rect.minX, y: rect.minY, width: max(2, rect.width * f), height: rect.height)
            var g = rough(seed: seed, small: true, gap: 2.5)
            ctx.strokeRough(g.hachure(corners(filled)), color: fill(hue), width: 0.9)
            outline(ctx, filled, color: stroke(hue), seed: seed + 2, small: true)
        }
    }

    func outline(_ ctx: CGContext, _ rect: CGRect, color: CGColor, width: CGFloat = 1, seed: Int, small: Bool = false, roughness: CGFloat? = nil) {
        var g = rough(seed: seed, small: small, roughness: roughness)
        ctx.strokeRough(g.polyline(corners(rect), closed: true), color: color, width: width)
    }

    func dot(_ ctx: CGContext, _ center: CGPoint, radius: CGFloat, seed: Int) {
        switch theme {
        case .ink:
            InkBrush.dot(ctx, center, radius: radius, color: palette.red, texture: texture)
        case .sketch:
            ctx.saveGState()
            ctx.setFillColor(palette.red)
            ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            ctx.restoreGState()
            let ring = (0...10).map { i -> CGPoint in
                let a = CGFloat(i) / 10 * 2 * .pi
                return CGPoint(x: center.x + cos(a) * radius * 1.25, y: center.y + sin(a) * radius * 1.25)
            }
            var g = rough(seed: seed, small: true, roughness: 0.6)
            g.o.disableMultiStroke = true
            ctx.strokeRough(g.curve(ring), color: palette.red, width: 1)
        }
    }

    func rule(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, seed: Int) {
        switch theme {
        case .ink:
            InkBrush.stroke(ctx, [a, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 0.5), b], width: 0.9,
                            color: palette.ink.copy(alpha: 0.45)!, paper: nil, seed: seed, texture: texture)
        case .sketch:
            var g = rough(seed: seed, small: false, roughness: 0.8)
            ctx.strokeRough(g.doubleLine(a, b), color: palette.ink.copy(alpha: 0.45)!, width: 1)
        }
    }

    func battery(_ ctx: CGContext, _ rect: CGRect, fraction: Double, seed: Int) {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - 3, height: rect.height)
        let inner = body.insetBy(dx: 2, dy: 2)
        let hue: Hue = fraction < 0.2 ? .red : (theme == .ink ? .ink : .green)
        switch theme {
        case .ink:
            let box = [CGPoint(x: body.minX, y: body.minY), CGPoint(x: body.maxX, y: body.minY), CGPoint(x: body.maxX, y: body.maxY),
                       CGPoint(x: body.minX, y: body.maxY), CGPoint(x: body.minX, y: body.minY + 0.5)]
            InkBrush.stroke(ctx, box, width: 1.1, color: palette.ink, paper: nil, seed: seed, texture: texture * 0.5)
            InkBrush.stroke(ctx, [CGPoint(x: rect.maxX - 1.5, y: rect.minY + 3.5), CGPoint(x: rect.maxX - 1.5, y: rect.maxY - 3.5)],
                            width: 1.6, color: palette.ink, paper: nil, seed: seed + 1, texture: 0)
            ctx.saveGState()
            ctx.setFillColor(stroke(hue))
            ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width * CGFloat(min(max(fraction, 0), 1)), height: inner.height))
            ctx.restoreGState()
        case .sketch:
            outline(ctx, body, color: palette.ink, seed: seed, small: true)
            ctx.saveGState()
            ctx.setFillColor(palette.ink)
            ctx.fill(CGRect(x: rect.maxX - 2.5, y: rect.minY + 3.5, width: 2, height: rect.height - 7))
            let level = CGRect(x: inner.minX, y: inner.minY, width: max(1, inner.width * CGFloat(min(max(fraction, 0), 1))), height: inner.height)
            ctx.setFillColor(stroke(hue))
            ctx.fill(level)
            ctx.restoreGState()
        }
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
}

extension NSAttributedString {
    static func styled(_ string: String, _ font: NSFont, _ color: CGColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .labelColor])
    }
}
