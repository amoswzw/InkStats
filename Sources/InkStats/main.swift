import AppKit

let arguments = CommandLine.arguments
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
