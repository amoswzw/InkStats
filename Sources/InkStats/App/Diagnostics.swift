import InkKit
import CSystem
import Foundation

/// `InkStats --dump` prints one sample as plain text, for bug reports.
enum Diagnostics {
    static func dump() {
        let sampler = Sampler()
        sampler.setWantsProcesses(true)
        sampler.setWantsTraffic(true)
        _ = sampler.sample()
        // powermetrics needs about three seconds to deliver its first sample after a cold start.
        HelperClient.shared.refresh(wantPower: true, wantProcesses: true)
        sleep(4)
        HelperClient.shared.refresh(wantPower: true, wantProcesses: true)
        sleep(1)
        let s = sampler.sample()
        print("Helper: \(HelperClient.shared.state), power from helper: \(HelperClient.shared.cachedPower())")
        print("CPU \(Format.percent(s.cpu.total, decimals: 1)) clusters: \(s.cpu.clusters.map { "\($0.name)×\($0.cpus.count)" }.joined(separator: ", "))")
        print("GPU \(s.gpu.name) \(s.gpu.utilization.map { Format.percent($0) } ?? "—")")
        print("Memory \(Format.bytes(s.memory.used)) of \(Format.bytes(s.memory.total)) pressure \(s.memory.pressureLevel)")
        print("Network \(s.network.interface) \(s.networkDetails.kind) ↓\(Format.rate(s.network.download)) ↑\(Format.rate(s.network.upload))")
        print("  IPv4 \(s.networkDetails.ipv4) IPv6 \(s.networkDetails.ipv6) router \(s.networkDetails.router ?? "—") DNS \(s.networkDetails.dns) VPN \(s.networkDetails.vpn)")
        if let w = s.networkDetails.wifi { print("  Wi-Fi \(w.standard) \(w.band) ch \(w.channel) \(w.rssi) dBm noise \(w.noise) dBm \(Int(w.rate)) Mbps") }
        for v in s.volumes { print("Volume \(v.name) \(Format.bytes(v.available)) free of \(Format.bytes(v.capacity))\(v.ejectable ? " ejectable" : "")") }
        print("Sensors \(s.sensors.all.count): " + s.sensors.all.map { "\($0.name) \(String(format: "%.1f", $0.celsius))" }.joined(separator: ", "))
        print("Fans " + s.sensors.fans.map { "\(Int($0.rpm)) rpm" }.joined(separator: ", "))
        print("Power system \(s.power.system.map(Format.watts) ?? "—") gpu \(s.power.gpu.map(Format.watts) ?? "—") cpu \(s.power.cpu.map(Format.watts) ?? "—")")
        print("Battery \(s.battery.present ? Format.percent(s.battery.percent) : "none") health \(s.battery.health.map { Format.percent($0) } ?? "—")")
        print("Bluetooth " + (s.bluetooth.isEmpty ? "none reporting battery" : s.bluetooth.map { "\($0.name) \($0.levels.map { "\($0.part)\($0.percent)%" })" }.joined(separator: ", ")))
        print("Processes readable: \(s.processes.count). Top CPU: " + s.processes.sorted { $0.cpu > $1.cpu }.prefix(5).map { "\($0.name) \(Format.percent($0.cpu, decimals: 1))" }.joined(separator: ", "))
        print("Traffic: " + s.appTraffic.prefix(5).map { "\($0.name) ↓\(Format.rate($0.download)) ↑\(Format.rate($0.upload))" }.joined(separator: ", "))
        print("Drives: " + s.drives.map { "used \($0.percentageUsed)% written \(Format.bytes($0.bytesWritten))" }.joined(separator: ", "))
        print("Top memory: " + s.processes.sorted { $0.memory > $1.memory }.prefix(5).map { "\($0.name) \(Format.bytes($0.memory))" }.joined(separator: ", "))
    }

    /// `InkStats --fan <index> <rpm>` holds one fan at a speed for ten seconds, then returns it
    /// to automatic. The helper also resets fans when this process disconnects.
    static func fanTest(index: Int, rpm: Double) {
        func command(_ label: String, _ body: (@escaping (String?) -> Void) -> Void) {
            var finished = false
            body { error in
                print("\(label): \(error ?? "ok")")
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        }
        command("Set fan \(index) to \(Int(rpm)) rpm") { HelperClient.shared.setFan(index, rpm: rpm, done: $0) }
        for second in 1...10 {
            sleep(1)
            var actual = 0.0, mode = 0.0
            _ = is_smc_read("F\(index)Ac", &actual)
            if !is_smc_read("F\(index)md", &mode) { _ = is_smc_read("F\(index)Md", &mode) }
            print("  \(second)s: \(Int(actual)) rpm, mode \(Int(mode))")
        }
        command("Fan \(index) automatic") { HelperClient.shared.setFan(index, rpm: 0, done: $0) }
        sleep(3)
        var actual = 0.0
        _ = is_smc_read("F\(index)Ac", &actual)
        print("  after reset: \(Int(actual)) rpm")
    }

    /// `InkStats --benchmark` times each reader, to find what makes sampling expensive.
    static func benchmark() {
        func time(_ name: String, _ body: () -> Void) {
            body()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<20 { body() }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 20 / 1_000_000
            print(String(format: "%-16@ %7.2f ms", name as NSString, ms))
        }
        let cpu = CPUReader(), gpu = GPUReader(), memory = MemoryReader(), network = NetworkReader(), disk = DiskReader()
        let sensors = SensorReader(), power = PowerReader(), battery = BatteryReader(), processes = ProcessReader()
        let volumes = VolumeReader(), details = NetworkDetailsReader(), bluetooth = BluetoothReader()
        time("cpu") { _ = cpu.read() }
        time("gpu") { _ = gpu.read() }
        time("memory") { _ = memory.read() }
        time("network") { _ = network.read() }
        time("disk") { _ = disk.read() }
        time("sensors (uncached)") { _ = SensorReader().read() }
        _ = sensors
        time("power") { _ = power.read() }
        time("battery") { _ = battery.read() }
        time("processes") { _ = processes.read() }
        time("volumes") { _ = volumes.read() }
        time("networkDetails") { _ = details.read(primary: "en0") }
        time("bluetooth") { _ = bluetooth.read() }
        let history = History(persist: false)
        let snapshot = Sampler().sample()
        for _ in 0..<30 { history.record(snapshot) }
        for theme in ThemeID.allCases {
            let painter = Painter(theme: theme, palette: .make(theme, dark: false), texture: 1)
            time("bar images \(theme.rawValue)") {
                for m in ModuleID.allCases {
                    let image = StatusBarController.image(m, parts: barParts(m, snapshot, history), painter: painter, labels: theme.defaultLabels)
                    _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                }
            }
        }
    }
}
