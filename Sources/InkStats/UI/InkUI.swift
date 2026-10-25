import AppKit
import SwiftUI

/// The ink look for settings windows: paper, brush lettering, vermilion accents. It follows
/// the app's theme (ink-wash or hand-drawn) and the system's light or dark appearance.
struct InkLook {
    let theme: ThemeID
    let dark: Bool

    var palette: Palette { .make(theme, dark: dark) }
    var painter: Painter { Painter(theme: theme, palette: palette, texture: 1) }
    var ink: Color { Color(cgColor: palette.ink) }
    var sub: Color { Color(cgColor: palette.sub) }
    var red: Color { Color(cgColor: palette.red) }
    var paper: Color { Color(cgColor: palette.paper) }

    func brush(_ size: CGFloat) -> Font {
        Font(theme == .ink ? Fonts.brush(size) : Fonts.handChinese(size))
    }

    func text(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
        Font(theme == .ink ? Fonts.serif(size, weight: weight) : Fonts.hand(size + 1))
    }
}

private struct InkLookKey: EnvironmentKey {
    static let defaultValue = InkLook(theme: .ink, dark: false)
}

extension EnvironmentValues {
    var inkLook: InkLook {
        get { self[InkLookKey.self] }
        set { self[InkLookKey.self] = newValue }
    }
}

/// Rice paper, or plain paper for the hand-drawn theme.
struct PaperBackground: NSViewRepresentable {
    let look: InkLook

    func makeNSView(context: Context) -> PaperView { PaperView() }
    func updateNSView(_ view: PaperView, context: Context) {
        view.look = look
        view.needsDisplay = true
    }

    final class PaperView: NSView {
        var look = InkLook(theme: .ink, dark: false)
        private var tile: (dark: Bool, image: CGImage)?

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let palette = look.palette
            ctx.setFillColor(palette.paper)
            ctx.fill(bounds)
            guard look.theme == .ink else { return }
            if tile?.dark != palette.isDark, let image = InkBrush.paperTile(palette) { tile = (palette.isDark, image) }
            if let image = tile?.image {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), byTiling: true)
            }
        }
    }
}

/// A short brush stroke or hand-drawn line, across the width it's given.
struct InkRule: View {
    @Environment(\.inkLook) private var look
    var seed = 3
    var vertical = false

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                let from = vertical ? CGPoint(x: size.width / 2, y: 0) : CGPoint(x: 0, y: size.height / 2)
                let to = vertical ? CGPoint(x: size.width / 2, y: size.height) : CGPoint(x: size.width, y: size.height / 2)
                look.painter.rule(cg, from: from, to: to, seed: seed)
            }
        }
        .frame(width: vertical ? 6 : nil, height: vertical ? nil : 6)
    }
}

/// A vermilion seal with one character carved out.
struct InkSeal: View {
    @Environment(\.inkLook) private var look
    let character: String
    var size: CGFloat = 34

    var body: some View {
        Canvas { context, canvas in
            context.withCGContext { cg in
                // The seal letters its character through AppKit, which needs a current context.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                defer { NSGraphicsContext.restoreGraphicsState() }
                InkBrush.seal(cg, rect: CGRect(x: 1, y: 1, width: canvas.width - 2, height: canvas.height - 2), character: character,
                              color: look.palette.red, font: Fonts.brush(size * 0.72), seed: 9, texture: 0.7)
            }
        }
        .frame(width: size, height: size)
    }
}

struct InkPage: Identifiable, Hashable {
    let id: String
    let chinese: String
    let english: String
}

/// A settings window: a sidebar of brush-lettered pages on paper, and the chosen page.
struct InkSettingsShell<Content: View>: View {
    let seal: String
    let appChinese: String
    let appEnglish: String
    let pages: [InkPage]
    @Binding var selection: String
    @ViewBuilder let content: (String) -> Content

    @AppStorage("theme") private var themeRaw = ThemeID.ink.rawValue
    @Environment(\.colorScheme) private var scheme

    private var look: InkLook { InkLook(theme: ThemeID(rawValue: themeRaw) ?? .ink, dark: scheme == .dark) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    InkSeal(character: seal)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(appChinese).font(look.brush(22)).foregroundStyle(look.ink)
                        Text(appEnglish).font(look.text(11)).foregroundStyle(look.sub)
                    }
                }
                .padding(.bottom, 18)
                ForEach(pages) { page in
                    Button { selection = page.id } label: { PageLabel(page: page, selected: page.id == selection) }
                        .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 44)
            .padding(.horizontal, 20)
            .frame(width: 196, alignment: .leading)

            InkRule(seed: 21, vertical: true).padding(.vertical, 24)

            VStack(alignment: .leading, spacing: 0) {
                if let page = pages.first(where: { $0.id == selection }) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(page.chinese).font(look.brush(34)).foregroundStyle(look.ink)
                        Text(page.english).font(look.text(15)).foregroundStyle(look.sub)
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 34)
                    InkRule(seed: page.id.count).frame(width: 160).padding(.horizontal, 28).padding(.top, 4)
                }
                content(selection)
                    .inkForm(look)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .environment(\.inkLook, look)
        .background(PaperBackground(look: look).ignoresSafeArea())
        .tint(look.red)
    }

    private struct PageLabel: View {
        @Environment(\.inkLook) private var look
        let page: InkPage
        let selected: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(page.chinese).font(look.brush(17)).foregroundStyle(selected ? look.red : look.ink)
                Text(page.english).font(look.text(12)).foregroundStyle(look.sub)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottomLeading) {
                if selected { InkRule(seed: 5).frame(width: 64).offset(x: 6, y: 2) }
            }
            .contentShape(Rectangle())
        }
    }
}

extension View {
    /// Settings forms on paper: no grey panels, serif or hand lettering, vermilion controls.
    func inkForm(_ look: InkLook) -> some View {
        self
            .scrollContentBackground(.hidden)
            .font(look.text(13))
            .foregroundStyle(look.ink)
            .tint(look.red)
    }
}

struct InkSectionHeader: View {
    @Environment(\.inkLook) private var look
    let chinese: String
    let english: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(chinese).font(look.brush(16)).foregroundStyle(look.ink)
            Text(english).font(look.text(11)).foregroundStyle(look.sub)
        }
    }
}

/// Settings windows with the paper reaching under a transparent title bar.
func makeInkSettingsWindow<V: View>(title: String, size: CGSize, root: V) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: root)
    window.setContentSize(size)
    window.center()
    return window
}

/// A list on paper, in place of the system list with its own background and fonts.
struct InkList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.trailing, 8)
        }
    }
}

extension View {
    /// A list row with a faint ruled line beneath it.
    func inkRow() -> some View {
        modifier(InkRowModifier())
    }
}

private struct InkRowModifier: ViewModifier {
    @Environment(\.inkLook) private var look

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(look.ink.opacity(0.12)).frame(height: 1)
            }
    }
}

extension Font {
    static var inkCaption: Font { Font(Settings.shared.theme == .ink ? Fonts.serif(11) : Fonts.hand(12)) }
    static var inkCallout: Font { Font(Settings.shared.theme == .ink ? Fonts.serif(13) : Fonts.hand(14)) }
}
