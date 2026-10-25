import CoreGraphics
import Foundation

// A Swift port of the sketchy-line generator from rough.js 4.6.6
// (https://github.com/rough-stuff/rough, MIT License, Copyright (c) 2019 Preet Shihn).
// Only the parts this app draws are ported: lines, polylines, curves and hachure fills.

struct RoughOptions {
    var roughness: CGFloat = 1
    var bowing: CGFloat = 1
    var maxRandomnessOffset: CGFloat = 2
    var curveTightness: CGFloat = 0
    var strokeWidth: CGFloat = 1
    var hachureAngle: CGFloat = -41
    var hachureGap: CGFloat = -1
    var fillWeight: CGFloat = -1
    var disableMultiStroke = false
    var preserveVertices = false
    var seed: Int32 = 1
}

/// Park–Miller style generator matching rough.js so a seed always yields the same wobble.
struct RoughRandom {
    private var seed: Int32

    init(seed: Int32) { self.seed = seed == 0 ? 1 : seed }

    mutating func next() -> CGFloat {
        seed = seed &* 48271
        return CGFloat(Int32.max & seed) / CGFloat(1 << 31)
    }
}

enum RoughOp {
    case move(CGPoint)
    case curve(CGPoint, CGPoint, CGPoint)
    case line(CGPoint)
}

struct RoughGenerator {
    var o: RoughOptions
    private var random: RoughRandom

    init(_ options: RoughOptions) {
        o = options
        random = RoughRandom(seed: options.seed)
    }

    private mutating func offset(_ min: CGFloat, _ max: CGFloat, gain: CGFloat = 1) -> CGFloat {
        o.roughness * gain * (random.next() * (max - min) + min)
    }

    private mutating func offsetOpt(_ x: CGFloat, gain: CGFloat = 1) -> CGFloat {
        offset(-x, x, gain: gain)
    }

    private mutating func line(_ a: CGPoint, _ b: CGPoint, move: Bool, overlay: Bool) -> [RoughOp] {
        let lengthSq = pow(a.x - b.x, 2) + pow(a.y - b.y, 2)
        let length = sqrt(lengthSq)
        let gain: CGFloat = length < 200 ? 1 : length > 500 ? 0.4 : -0.0016668 * length + 1.233334
        var off = o.maxRandomnessOffset
        if off * off * 100 > lengthSq { off = length / 10 }
        let half = off / 2
        let diverge = 0.2 + random.next() * 0.2
        var midX = o.bowing * o.maxRandomnessOffset * (b.y - a.y) / 200
        var midY = o.bowing * o.maxRandomnessOffset * (a.x - b.x) / 200
        midX = offsetOpt(midX, gain: gain)
        midY = offsetOpt(midY, gain: gain)
        let jitter = overlay ? half : off
        let keep = o.preserveVertices

        var ops: [RoughOp] = []
        if move {
            ops.append(.move(CGPoint(x: a.x + (keep ? 0 : offsetOpt(jitter, gain: gain)),
                                     y: a.y + (keep ? 0 : offsetOpt(jitter, gain: gain)))))
        }
        let c1 = CGPoint(x: midX + a.x + (b.x - a.x) * diverge + offsetOpt(jitter, gain: gain),
                         y: midY + a.y + (b.y - a.y) * diverge + offsetOpt(jitter, gain: gain))
        let c2 = CGPoint(x: midX + a.x + 2 * (b.x - a.x) * diverge + offsetOpt(jitter, gain: gain),
                         y: midY + a.y + 2 * (b.y - a.y) * diverge + offsetOpt(jitter, gain: gain))
        let end = CGPoint(x: b.x + (keep ? 0 : offsetOpt(jitter, gain: gain)),
                          y: b.y + (keep ? 0 : offsetOpt(jitter, gain: gain)))
        ops.append(.curve(c1, c2, end))
        return ops
    }

    mutating func doubleLine(_ a: CGPoint, _ b: CGPoint) -> [RoughOp] {
        let first = line(a, b, move: true, overlay: false)
        return o.disableMultiStroke ? first : first + line(a, b, move: true, overlay: true)
    }

    mutating func polyline(_ points: [CGPoint], closed: Bool) -> [RoughOp] {
        guard points.count >= 2 else { return [] }
        var ops: [RoughOp] = []
        for i in 0..<(points.count - 1) { ops += doubleLine(points[i], points[i + 1]) }
        if closed, points.count > 2 { ops += doubleLine(points[points.count - 1], points[0]) }
        return ops
    }

    private mutating func curveThrough(_ points: [CGPoint]) -> [RoughOp] {
        let s = 1 - o.curveTightness
        guard points.count > 3 else {
            return points.count == 2 ? line(points[0], points[1], move: true, overlay: true) : []
        }
        var ops: [RoughOp] = [.move(points[1])]
        var i = 1
        while i + 2 < points.count {
            let p = points[i], prev = points[i - 1], next = points[i + 1], after = points[i + 2]
            let c1 = CGPoint(x: p.x + (s * next.x - s * prev.x) / 6, y: p.y + (s * next.y - s * prev.y) / 6)
            let c2 = CGPoint(x: next.x + (s * p.x - s * after.x) / 6, y: next.y + (s * p.y - s * after.y) / 6)
            ops.append(.curve(c1, c2, next))
            i += 1
        }
        return ops
    }

    private mutating func curveWithOffset(_ points: [CGPoint], _ amount: CGFloat) -> [RoughOp] {
        guard let first = points.first else { return [] }
        var ps: [CGPoint] = []
        func jittered(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offsetOpt(amount), y: p.y + offsetOpt(amount)) }
        ps.append(jittered(first))
        ps.append(jittered(first))
        for i in 1..<points.count {
            ps.append(jittered(points[i]))
            if i == points.count - 1 { ps.append(jittered(points[i])) }
        }
        return curveThrough(ps)
    }

    mutating func curve(_ points: [CGPoint]) -> [RoughOp] {
        guard points.count >= 2 else { return [] }
        let under = curveWithOffset(points, 1 + o.roughness * 0.2)
        if o.disableMultiStroke { return under }
        var overlay = RoughGenerator(o)
        overlay.o.seed = o.seed &+ 1
        overlay.random = RoughRandom(seed: overlay.o.seed)
        return under + overlay.curveWithOffset(points, 1.5 * (1 + o.roughness * 0.22))
    }

    /// Parallel scan lines clipped to the polygon, each drawn as a sketchy double line.
    mutating func hachure(_ polygon: [CGPoint]) -> [RoughOp] {
        var gap = o.hachureGap < 0 ? o.strokeWidth * 4 : o.hachureGap
        gap = max(gap.rounded(), 0.1)
        let angle = o.hachureAngle * .pi / 180
        let segments = Self.scanLines(polygon, gap: gap, angle: angle)
        var ops: [RoughOp] = []
        for (a, b) in segments { ops += doubleLine(a, b) }
        return ops
    }

    private static func scanLines(_ polygon: [CGPoint], gap: CGFloat, angle: CGFloat) -> [(CGPoint, CGPoint)] {
        guard polygon.count >= 3 else { return [] }
        let cosA = cos(-angle), sinA = sin(-angle)
        let rotated = polygon.map { CGPoint(x: $0.x * cosA - $0.y * sinA, y: $0.x * sinA + $0.y * cosA) }
        guard let minY = rotated.map(\.y).min(), let maxY = rotated.map(\.y).max() else { return [] }
        let back = { (p: CGPoint) in CGPoint(x: p.x * cosA + p.y * sinA, y: -p.x * sinA + p.y * cosA) }

        var result: [(CGPoint, CGPoint)] = []
        var y = minY + gap / 2
        while y < maxY {
            var xs: [CGFloat] = []
            for i in 0..<rotated.count {
                let p = rotated[i], q = rotated[(i + 1) % rotated.count]
                if (p.y <= y && q.y > y) || (q.y <= y && p.y > y) {
                    xs.append(p.x + (y - p.y) / (q.y - p.y) * (q.x - p.x))
                }
            }
            xs.sort()
            var j = 0
            while j + 1 < xs.count {
                result.append((back(CGPoint(x: xs[j], y: y)), back(CGPoint(x: xs[j + 1], y: y))))
                j += 2
            }
            y += gap
        }
        return result
    }
}

extension CGContext {
    func strokeRough(_ ops: [RoughOp], color: CGColor, width: CGFloat) {
        guard !ops.isEmpty else { return }
        let path = CGMutablePath()
        for op in ops {
            switch op {
            case .move(let p): path.move(to: p)
            case .curve(let c1, let c2, let p): path.addCurve(to: p, control1: c1, control2: c2)
            case .line(let p): path.addLine(to: p)
            }
        }
        saveGState()
        setStrokeColor(color)
        setLineWidth(width)
        setLineCap(.round)
        setLineJoin(.round)
        addPath(path)
        strokePath()
        restoreGState()
    }
}
