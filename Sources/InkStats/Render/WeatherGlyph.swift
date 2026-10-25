import CoreGraphics

extension Painter {
    /// A weather symbol drawn with the theme's own strokes, laid out on a 16-unit grid inside `rect`.
    func weatherGlyph(_ ctx: CGContext, _ condition: WeatherCondition, day: Bool, in rect: CGRect, seed: Int) {
        let s = rect.width / 16
        let width = max(1, (theme == .ink ? 1.5 : 1.3) * s)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ from: CGFloat, _ to: CGFloat) -> [CGPoint] {
            let steps = max(3, Int(abs(to - from) / 20))
            return (0...steps).map { i in
                let a = (from + (to - from) * CGFloat(i) / CGFloat(steps)) * .pi / 180
                return p(cx + r * cos(a), cy + r * sin(a))
            }
        }
        func stroke(_ points: [CGPoint], _ hue: Hue = .ink, _ n: Int = 0) {
            line(ctx, points, hue: hue, width: width, seed: seed + n * 7, small: true)
        }
        func sun(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, rays: ClosedRange<CGFloat> = 0...315) {
            stroke(arc(cx, cy, r, 0, 360), .c, 1)
            for (i, angle) in stride(from: rays.lowerBound, through: rays.upperBound, by: 45).enumerated() {
                let a = angle * .pi / 180
                stroke([p(cx + (r + 1.3) * cos(a), cy + (r + 1.3) * sin(a)), p(cx + (r + 2.6) * cos(a), cy + (r + 2.6) * sin(a))], .c, 2 + i)
            }
        }
        // A crescent: the outer edge bulges left, the inner edge cuts it from the right.
        func moon(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            stroke(arc(cx, cy, r, 300, 60) + arc(cx + 0.7 * r, cy, 0.89 * r, 103, 257), .ink, 1)
        }
        func cloud(dx: CGFloat = 0, dy: CGFloat = 0) {
            let outline = arc(5 + dx, 10 + dy, 2, 100, 260) + arc(8.5 + dx, 8.5 + dy, 3.2, 195, 345)
                + arc(11.5 + dx, 10 + dy, 2, 280, 440) + [p(4.65 + dx, 11.97 + dy)]
            stroke(outline, .ink, 3)
        }

        switch condition {
        case .clear:
            if day { sun(8, 8, 3.2) } else { moon(8, 8, 5) }
        case .partlyCloudy:
            if day { sun(5.5, 5.5, 2.2, rays: 135...315) } else { moon(5.5, 5.5, 3) }
            cloud(dx: 1, dy: 1.5)
        case .cloudy:
            cloud(dy: 0.5)
        case .fog:
            stroke([p(2, 5), p(14, 5)], .ink, 1)
            stroke([p(3, 8.5), p(13, 8.5)], .ink, 2)
            stroke([p(2, 12), p(12, 12)], .ink, 3)
        case .drizzle, .rain:
            cloud(dy: -2)
            let length: CGFloat = condition == .rain ? 2.6 : 0.9
            for (i, x) in [5.0, 8.0, 11.0].enumerated() {
                stroke([p(x, 12), p(x - length * 0.35, 12 + length)], .a, 4 + i)
            }
        case .snow:
            cloud(dy: -2)
            for (i, (x, y)) in [(5.0, 12.8), (8.0, 14.4), (11.0, 12.8)].enumerated() {
                stroke([p(x - 0.7, y), p(x + 0.7, y)], .a, 4 + i)
                stroke([p(x, y - 0.7), p(x, y + 0.7)], .a, 7 + i)
            }
        case .thunder:
            cloud(dy: -2)
            stroke([p(8.8, 10.5), p(7, 13), p(9, 13), p(7.4, 15.6)], .b, 4)
        }
    }
}

extension Painter {
    /// The moon as seen from the northern hemisphere: lit from the right while waxing.
    func moonGlyph(_ ctx: CGContext, phase: Double, in rect: CGRect, seed: Int) {
        let r = rect.width / 2 - 1, center = CGPoint(x: rect.midX, y: rect.midY)
        let side: CGFloat = phase < 0.5 ? 1 : -1
        let terminator = CGFloat(cos(2 * .pi * phase))
        let limb = (0...12).map { i -> CGPoint in
            let a = (-90 + CGFloat(i) * 15) * .pi / 180
            return CGPoint(x: center.x + side * r * cos(a), y: center.y + r * sin(a))
        }
        let edge = (0...12).map { i -> CGPoint in
            let u = 1 - CGFloat(i) / 6
            return CGPoint(x: center.x + side * terminator * r * sqrt(max(0, 1 - u * u)), y: center.y + u * r)
        }
        let lit = limb + edge
        switch theme {
        case .ink:
            ctx.saveGState()
            ctx.setFillColor(stroke(.c).copy(alpha: 0.75)!)
            ctx.addLines(between: lit)
            ctx.closePath()
            ctx.fillPath()
            ctx.restoreGState()
        case .sketch:
            var g = RoughGenerator(RoughOptions(roughness: 0.3, hachureGap: 1.6, seed: Int32(truncatingIfNeeded: seed)))
            ctx.strokeRough(g.hachure(lit), color: fill(.c), width: 0.8)
        }
        let circle = (0...16).map { i -> CGPoint in
            let a = CGFloat(i) / 16 * 2 * .pi
            return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
        }
        line(ctx, circle, hue: .ink, width: 1, seed: seed + 1, small: true)
    }
}
