import AppKit

/// The app icon: a brushed sparkline ending in the vermilion dot the panels use, with a seal,
/// on xuan paper in the macOS rounded-square shape.
enum AppIcon {
    static func draw(_ ctx: CGContext, size: CGFloat) {
        let palette = Palette.make(.ink, dark: false)
        // Apple's grid leaves a margin around the rounded square.
        let tile = CGRect(x: size * 0.1, y: size * 0.1, width: size * 0.8, height: size * 0.8)
        let shape = CGPath(roundedRect: tile, cornerWidth: size * 0.18, cornerHeight: size * 0.18, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(palette.paper)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        if let paper = InkBrush.paperTile(palette) {
            ctx.draw(paper, in: CGRect(x: 0, y: 0, width: size, height: size), byTiling: true)
        }
        // The brush is tuned for small strokes, so paint on a 128-unit canvas and scale it up.
        let unit = size / 128
        ctx.translateBy(x: 0, y: size)
        ctx.scaleBy(x: unit, y: -unit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let line = [CGPoint(x: 26, y: 78), CGPoint(x: 38, y: 70), CGPoint(x: 48, y: 76), CGPoint(x: 60, y: 54),
                    CGPoint(x: 72, y: 62), CGPoint(x: 84, y: 40), CGPoint(x: 96, y: 46)]
        InkBrush.wash(ctx, line, base: 96, color: palette.a, alpha: 0.3)
        InkBrush.stroke(ctx, line, width: 5.2, color: palette.ink, paper: palette.paper, seed: 5, texture: 1)
        InkBrush.dot(ctx, CGPoint(x: 97, y: 45.5), radius: 4.2, color: palette.red, texture: 1)
        InkBrush.seal(ctx, rect: CGRect(x: 24, y: 25, width: 15, height: 15), character: "计", color: palette.red,
                      font: Fonts.brush(11), seed: 9, texture: 0.6)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}
