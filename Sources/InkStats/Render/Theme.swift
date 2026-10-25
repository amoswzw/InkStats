import AppKit
import CoreText

enum ThemeID: String, CaseIterable {
    case ink, sketch

    var title: String {
        switch self {
        case .ink: return "水墨 Ink-wash"
        case .sketch: return "手绘 Excalidraw"
        }
    }

    /// Labels a theme uses when the label setting is left on "Theme".
    var defaultLabels: LabelStyle { self == .ink ? .chinese : .english }
}

enum LabelStyle: String {
    case english, chinese
}

/// Named colors. `a`, `b`, `c` are the accent series colors; their `*Fill` partners are the
/// lighter tints the sketch theme uses for hachure.
struct Palette {
    let paper, ink, sub, a, b, c, green, violet, red: CGColor
    let aFill, bFill, cFill, greenFill, violetFill: CGColor
    let isDark: Bool

    static func make(_ theme: ThemeID, dark: Bool) -> Palette {
        func c(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        switch (theme, dark) {
        case (.ink, false):
            return Palette(paper: c(0xF1EBDF), ink: c(0x1D1B18), sub: c(0x6F695F), a: c(0x2F5568), b: c(0x9A5A33), c: c(0x8A8479),
                           green: c(0x4F6B4A), violet: c(0x5A4A6B), red: c(0xB8322A),
                           aFill: c(0x2F5568), bFill: c(0x9A5A33), cFill: c(0x8A8479), greenFill: c(0x4F6B4A), violetFill: c(0x1D1B18), isDark: false)
        case (.ink, true):
            return Palette(paper: c(0x1C1B18), ink: c(0xECE5D6), sub: c(0xA39C8F), a: c(0x86AABB), b: c(0xD39062), c: c(0x9D968A),
                           green: c(0x9BB894), violet: c(0xB3A3C6), red: c(0xE0574B),
                           aFill: c(0x86AABB), bFill: c(0xD39062), cFill: c(0x9D968A), greenFill: c(0x9BB894), violetFill: c(0xECE5D6), isDark: true)
        case (.sketch, false):
            return Palette(paper: c(0xFFFFFF), ink: c(0x1E1E1E), sub: c(0x6C757D), a: c(0x1971C2), b: c(0xE03131), c: c(0xF08C00),
                           green: c(0x2F9E44), violet: c(0x6741D9), red: c(0xE03131),
                           aFill: c(0xA5D8FF), bFill: c(0xFFC9C9), cFill: c(0xFFEC99), greenFill: c(0xB2F2BB), violetFill: c(0xD0BFFF), isDark: false)
        case (.sketch, true):
            return Palette(paper: c(0x121212), ink: c(0xE3E3E8), sub: c(0x9A9AA2), a: c(0x4DABF7), b: c(0xFF8787), c: c(0xFFA94D),
                           green: c(0x69DB7C), violet: c(0xB197FC), red: c(0xFF6B6B),
                           aFill: c(0x1C7ED6), bFill: c(0xC92A2A), cFill: c(0xD9480F), greenFill: c(0x2B8A3E), violetFill: c(0x7048E8), isDark: true)
        }
    }
}

enum Fonts {
    /// Registers bundled fonts. Looks inside the app bundle first, then next to the
    /// sources so `swift run` works during development.
    static func registerBundled() {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "Excalifont-Regular", withExtension: "ttf", subdirectory: "Fonts") {
            candidates.append(url)
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Resources/Fonts/Excalifont-Regular.ttf"))
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func first(_ names: [String], size: CGFloat) -> NSFont? {
        for name in names {
            if let font = NSFont(name: name, size: size) { return font }
            if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return font }
        }
        return nil
    }

    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// Brush lettering for Chinese labels and titles in the ink theme.
    static func brush(_ size: CGFloat) -> NSFont {
        first(["Xingkai SC", "Kaiti SC", "STKaiti", "Songti SC"], size: size) ?? serif(size)
    }

    static func hand(_ size: CGFloat) -> NSFont {
        first(["Excalifont", "Excalifont-Regular", "Chalkboard SE", "Marker Felt"], size: size) ?? .systemFont(ofSize: size)
    }

    static func handChinese(_ size: CGFloat) -> NSFont {
        first(["HanziPen SC", "Hannotate SC", "Yuanti SC"], size: size) ?? .systemFont(ofSize: size)
    }
}

/// Everything a theme decides about type.
struct ThemeFonts {
    let theme: ThemeID

    func number(_ size: CGFloat) -> NSFont {
        theme == .ink ? Fonts.serif(size, weight: .semibold) : Fonts.hand(size + 1)
    }

    func text(_ size: CGFloat) -> NSFont {
        theme == .ink ? Fonts.serif(size) : Fonts.hand(size + 1)
    }

    func chinese(_ size: CGFloat) -> NSFont {
        theme == .ink ? Fonts.brush(size) : Fonts.handChinese(size)
    }
}
