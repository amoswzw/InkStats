import AppKit

/// 2880×1800 promotional slides in the family style: xuan paper, the app icon beside a serif
/// headline, a subtitle, a vermilion brush stroke, then the app's own renderings below.
/// All coordinates are top-down pixels.
enum Promo {
    static let size = CGSize(width: 2880, height: 1800)
    /// Where a slide's content goes, below the headline.
    static let content = CGRect(x: 200, y: 500, width: 2480, height: 1220)

    static func slide(title: String, subtitle: String, icon: NSImage?, to url: URL, draw: (CGContext) -> Void) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return }
        let ctx = base.cgContext
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let palette = Palette.make(.ink, dark: false)
        ctx.setFillColor(palette.paper)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let tile = InkBrush.paperTile(palette) {
            ctx.saveGState()
            ctx.scaleBy(x: 2, y: 2)
            ctx.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height), byTiling: true)
            ctx.restoreGState()
        }

        let titleText = NSAttributedString.styled(title, Fonts.serif(132, weight: .bold), palette.ink)
        let iconSize: CGFloat = icon == nil ? 0 : 168, gap: CGFloat = icon == nil ? 0 : 36
        let rowWidth = iconSize + gap + titleText.size().width
        var x = (size.width - rowWidth) / 2
        if let icon {
            image(icon, in: CGRect(x: x, y: 96, width: iconSize, height: iconSize))
            x += iconSize + gap
        }
        titleText.draw(at: CGPoint(x: x, y: 180 - titleText.size().height / 2))

        let sub = NSAttributedString.styled(subtitle, Fonts.serif(58), palette.sub)
        sub.draw(at: CGPoint(x: (size.width - sub.size().width) / 2, y: 300))
        let mid = size.width / 2
        InkBrush.stroke(ctx, [CGPoint(x: mid - 250, y: 418), CGPoint(x: mid, y: 414), CGPoint(x: mid + 250, y: 417)],
                        width: 6, color: palette.red, paper: nil, seed: 4, texture: 0.8)

        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func image(_ image: NSImage, in rect: CGRect) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    /// A rounded card with a soft shadow, like a window or a screen, filled by `fill`.
    static func card(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat = 28, fill: (CGRect) -> Void) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        fill(rect)
        ctx.restoreGState()
    }

    /// A desktop with a quiet dusk wallpaper and a dark menu bar of the given height.
    static func desktop(_ ctx: CGContext, _ rect: CGRect, menuBar: CGFloat) {
        card(ctx, rect) { r in
            let colors = [CGColor(srgbRed: 0.16, green: 0.22, blue: 0.30, alpha: 1), CGColor(srgbRed: 0.42, green: 0.36, blue: 0.40, alpha: 1),
                          CGColor(srgbRed: 0.78, green: 0.62, blue: 0.52, alpha: 1)] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.6, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: r.minX, y: r.minY), end: CGPoint(x: r.maxX, y: r.maxY), options: [])
            }
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 0.92))
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: menuBar))
        }
    }

    /// Menu bar text such as the app name or the clock, in the system font at 2× scale.
    static func menuText(_ text: String, at point: CGPoint, bold: Bool = false, size: CGFloat = 27) {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.95, alpha: 1)]).draw(at: point)
    }
}
