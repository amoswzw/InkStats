import AppKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-icon"), flag + 1 < arguments.count {
    Fonts.registerBundled()
    let size = 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    AppIcon.draw(ctx, size: CGFloat(size))
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[flag + 1]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    exit(0)
}
if let flag = arguments.firstIndex(of: "--render-screenshots"), flag + 1 < arguments.count {
    _ = NSApplication.shared
    Screenshots.run(output: URL(fileURLWithPath: arguments[flag + 1]))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--render-preview"), flag + 1 < arguments.count {
    _ = NSApplication.shared
    PreviewRenderer.run(output: URL(fileURLWithPath: arguments[flag + 1]))
    exit(0)
}

if arguments.contains("--benchmark") {
    _ = NSApplication.shared
    Fonts.registerBundled()
    Diagnostics.benchmark()
    exit(0)
}

if let flag = arguments.firstIndex(of: "--helper") {
    let action = flag + 1 < arguments.count ? arguments[flag + 1] : "status"
    let helper = HelperClient.shared
    do {
        switch action {
        case "install": try helper.install()
        case "uninstall": try helper.uninstall()
        default: break
        }
        print("Helper: \(helper.state)")
    } catch {
        print("Helper \(action) failed: \(error.localizedDescription)")
    }
    exit(0)
}

if let flag = arguments.firstIndex(of: "--fan"), flag + 2 < arguments.count,
   let index = Int(arguments[flag + 1]), let rpm = Double(arguments[flag + 2]) {
    Diagnostics.fanTest(index: index, rpm: rpm)
    exit(0)
}

if arguments.contains("--dump") {
    Diagnostics.dump()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
