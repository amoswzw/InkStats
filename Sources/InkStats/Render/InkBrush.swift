import AppKit

/// Small deterministic generator for brush texture, so a stroke looks the same on every redraw.
struct InkRandom {
    private var state: UInt32

    init(seed: Int) { state = UInt32(truncatingIfNeeded: seed &* 2_654_435_761) | 1 }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return CGFloat(state) / CGFloat(UInt32.max)
    }
}

enum InkBrush {
    /// Catmull-Rom resampling so short polylines become smooth brush paths.
    static func smooth(_ points: [CGPoint], step: CGFloat) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var out: [CGPoint] = []
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
            let n = max(1, Int((hypot(p2.x - p1.x, p2.y - p1.y) / step).rounded(.up)))
            for k in 0..<n {
                let t = CGFloat(k) / CGFloat(n), t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    private static func normal(_ d: [CGPoint], _ i: Int) -> CGPoint {
        let a = d[max(0, i - 1)], b = d[min(d.count - 1, i + 1)]
        let dx = b.x - a.x, dy = b.y - a.y, m = max(hypot(dx, dy), 0.0001)
        return CGPoint(x: -dy / m, y: dx / m)
    }

    private static func ribbon(_ d: [CGPoint], _ widths: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        var right: [CGPoint] = []
        for i in d.indices {
            let n = normal(d, i), h = widths[i] / 2
            let left = CGPoint(x: d[i].x + n.x * h, y: d[i].y + n.y * h)
            right.append(CGPoint(x: d[i].x - n.x * h, y: d[i].y - n.y * h))
            i == 0 ? path.move(to: left) : path.addLine(to: left)
        }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// A brush stroke: pressed-in start, tapered lift, width wobble, a soft bleed halo,
    /// and dry-brush streaks of paper showing through near the tail.
    static func stroke(_ ctx: CGContext, _ points: [CGPoint], width: CGFloat, color: CGColor,
                       paper: CGColor?, seed: Int, texture: CGFloat) {
        guard points.count >= 2 else { return }
        var rng = InkRandom(seed: seed)
        let d = smooth(points, step: 1.5)
        var cumulative: [CGFloat] = [0]
        for i in 1..<d.count { cumulative.append(cumulative[i - 1] + hypot(d[i].x - d[i - 1].x, d[i].y - d[i - 1].y)) }
        let length = max(cumulative.last ?? 1, 1)

        let knotSpacing: CGFloat = 14
        let knots = (0...(Int(length / knotSpacing) + 2)).map { _ in rng.next() }
        func noise(_ s: CGFloat) -> CGFloat {
            let x = s / knotSpacing, i = Int(x), f = x - CGFloat(i), u = f * f * (3 - 2 * f)
            return knots[i] * (1 - u) + knots[min(i + 1, knots.count - 1)] * u
        }
        let tipIn = min(0.18, 16 / length), tipOut = min(0.3, 34 / length)
        let widths: [CGFloat] = d.indices.map { i in
            let t = cumulative[i] / length
            var k: CGFloat = 1
            if t < tipIn { k *= 0.6 + 0.4 * sin(t / tipIn * .pi / 2) }
            if t > 1 - tipOut { k *= max(0.14, pow(1 - (t - (1 - tipOut)) / tipOut, 0.75)) }
            return width * k * (1 - 0.2 * texture + 0.4 * texture * noise(cumulative[i]))
        }

        ctx.saveGState()
        if texture > 0 {
            ctx.setShadow(offset: .zero, blur: max(0.8, width * 1.1 * texture), color: color.copy(alpha: 0.32 * min(1, texture)))
        }
        ctx.setFillColor(color)
        ctx.addPath(ribbon(d, widths))
        ctx.fillPath()
        ctx.restoreGState()

        guard let paper, texture > 0.15, length > 30, width >= 1.8 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(paper)
        ctx.setLineCap(.round)
        let start = Int(CGFloat(d.count) * (0.7 + rng.next() * 0.08))
        for _ in 0..<3 {
            let across = (rng.next() - 0.5) * 0.7
            ctx.setAlpha((0.3 + 0.3 * rng.next()) * min(1, texture))
            ctx.setLineWidth(max(0.35, width * 0.12))
            let path = CGMutablePath()
            var penDown = false
            for i in start..<d.count {
                if rng.next() < 0.1 * texture { penDown = false; continue }
                let n = normal(d, i)
                let p = CGPoint(x: d[i].x + n.x * widths[i] * across, y: d[i].y + n.y * widths[i] * across)
                penDown ? path.addLine(to: p) : path.move(to: p)
                penDown = true
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Graded wash beneath a curve: dense near the line, fading into the paper.
    static func wash(_ ctx: CGContext, _ points: [CGPoint], base: CGFloat, color: CGColor, alpha: CGFloat) {
        guard points.count >= 2, let top = points.map(\.y).min() else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x, y: base))
        points.forEach { path.addLine(to: $0) }
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: base))
        path.closeSubpath()

        let colors = [color.copy(alpha: alpha)!, color.copy(alpha: alpha * 0.3)!, color.copy(alpha: 0)!] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1]) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: base), options: [])
        ctx.restoreGState()
    }

    static func dot(_ ctx: CGContext, _ center: CGPoint, radius: CGFloat, color: CGColor, texture: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 1.5 + texture * 2, color: color.copy(alpha: 0.5))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    /// A vermilion seal with its character carved out, as on a painting's signature.
    static func seal(_ ctx: CGContext, rect: CGRect, character: String, color: CGColor, font: NSFont, seed: Int, texture: CGFloat) {
        var rng = InkRandom(seed: seed)
        let path = CGMutablePath()
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        for side in 0..<4 {
            let a = corners[side], b = corners[(side + 1) % 4]
            for k in 0..<8 {
                let t = CGFloat(k) / 8
                let p = CGPoint(x: a.x + (b.x - a.x) * t + (rng.next() - 0.5) * 1.2, y: a.y + (b.y - a.y) * t + (rng.next() - 0.5) * 1.2)
                side == 0 && k == 0 ? path.move(to: p) : path.addLine(to: p)
            }
        }
        path.closeSubpath()

        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setBlendMode(.destinationOut)
        let text = NSAttributedString(string: character, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        for _ in 0..<Int(26 * max(0.3, texture)) {
            ctx.setAlpha(0.35 + rng.next() * 0.5)
            let r = rng.next() * 0.9 + 0.2
            ctx.fillEllipse(in: CGRect(x: rect.minX + rng.next() * rect.width - r, y: rect.minY + rng.next() * rect.height - r, width: r * 2, height: r * 2))
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// A tileable rice-paper texture: fine grain plus a scatter of fibres.
    static func paperTile(_ palette: Palette) -> CGImage? {
        let size = 220
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.setFillColor(palette.paper)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        var rng = InkRandom(seed: 9)
        let pixels = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * size)
        let amplitude: CGFloat = palette.isDark ? 7 : 9
        for y in 0..<size {
            for x in 0..<size {
                let i = y * ctx.bytesPerRow + x * 4
                let n = Int((rng.next() - 0.5) * amplitude)
                for c in 0..<3 { pixels[i + c] = UInt8(clamping: Int(pixels[i + c]) + n) }
            }
        }
        ctx.setStrokeColor(palette.isDark ? CGColor(srgbRed: 0.93, green: 0.9, blue: 0.84, alpha: 0.05)
                                          : CGColor(srgbRed: 0.24, green: 0.19, blue: 0.12, alpha: 0.06))
        ctx.setLineWidth(0.6)
        for _ in 0..<90 {
            let x = rng.next() * CGFloat(size), y = rng.next() * CGFloat(size)
            let angle = rng.next() * .pi, length = 6 + rng.next() * 18
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addQuadCurve(to: CGPoint(x: x + cos(angle) * length, y: y + sin(angle) * length),
                             control: CGPoint(x: x + cos(angle) * length / 2 + (rng.next() - 0.5) * 4,
                                              y: y + sin(angle) * length / 2 + (rng.next() - 0.5) * 4))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
