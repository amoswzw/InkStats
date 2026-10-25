import Foundation

/// Raw values are stored in the history database, so never rename them.
enum Series: String, CaseIterable {
    case cpu, cpuSystem, gpu, memory, download, upload, read, write, temperature, power, gpuPower, battery, menuSensor
}

/// Recent samples in memory, for the menu bar sparklines and the live panel graph.
final class History: SeriesSource {
    static let capacity = 120
    private var values: [Series: [Double]] = [:]
    private let aggregator: MinuteAggregator?

    init(persist: Bool = true) {
        aggregator = persist ? MinuteAggregator() : nil
    }

    func push(_ series: Series, _ value: Double) {
        var list = values[series, default: []]
        list.append(value)
        if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
        values[series] = list
    }

    func values(_ series: Series, last count: Int = History.capacity) -> [Double] {
        Array(values[series, default: []].suffix(count))
    }

    func series(_ series: Series) -> [Double?] { values(series) }

    func record(_ s: Snapshot) {
        var row: [Series: Double] = [
            .cpu: s.cpu.total, .cpuSystem: s.cpu.system, .gpu: s.gpu.utilization ?? 0,
            .memory: s.memory.usedFraction * 100, .download: s.network.download, .upload: s.network.upload,
            .read: s.disk.read, .write: s.disk.write,
        ]
        row[.temperature] = s.sensors.cpuAverage
        row[.menuSensor] = Settings.shared.menuSensorValue(s)
        row[.power] = s.power.system
        row[.gpuPower] = s.power.gpu
        if s.battery.present { row[.battery] = s.battery.percent }
        for (series, value) in row { push(series, value) }
        aggregator?.add(row)
    }

    func flush() { aggregator?.flush() }
}

/// Collects one snapshot per tick on a background queue and hands it to the main thread.
final class Sampler {
    private let queue = DispatchQueue(label: "inkstats.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    private let cpu = CPUReader()
    private let gpu = GPUReader()
    private let memory = MemoryReader()
    private let network = NetworkReader()
    private let disk = DiskReader()
    private let sensors = SensorReader()
    private let power = PowerReader()
    private let battery = BatteryReader()
    private let processes = ProcessReader()
    private let volumes = VolumeReader()
    private let details = NetworkDetailsReader()
    private let bluetooth = BluetoothReader()
    private let smart = SmartReader()
    private let traffic = AppTrafficReader()

    private var wantsProcesses = false
    private var wantsTraffic = false

    /// Per-process readings are the most expensive, so they only run while a panel shows them.
    func setWantsProcesses(_ wanted: Bool) {
        queue.async { self.wantsProcesses = wanted }
    }

    func setWantsTraffic(_ wanted: Bool) {
        queue.async { self.wantsTraffic = wanted }
    }

    /// The flag is true for regular ticks; event-driven refreshes pass false so they
    /// don't add irregular points to the history.
    var onSample: ((Snapshot, Bool) -> Void)?

    func start(interval: TimeInterval) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.deliver(regular: true) }
        timer.resume()
        self.timer = timer
    }

    func refresh(after event: HardwareEvent) {
        queue.async { [self] in
            switch event {
            case .disks: disk.invalidate(); volumes.invalidate()
            case .network: network.invalidate(); details.invalidate()
            case .power: break
            case .wake: disk.invalidate(); volumes.invalidate(); network.invalidate(); details.invalidate()
            }
            deliver(regular: false)
        }
    }

    private func deliver(regular: Bool) {
        let snapshot = sample()
        DispatchQueue.main.async { self.onSample?(snapshot, regular) }
    }

    func sample() -> Snapshot {
        let net = network.read()
        let helper = HelperClient.shared
        var power = self.power.read()
        let measured = helper.cachedPower()
        // On some chips the IOReport CPU and ANE counters only advance while powermetrics runs,
        // and jump by the paused interval when it starts, so the helper is the only source then.
        if helper.state == .running {
            power.cpu = measured["cpu"]
            power.neuralEngine = measured["ane"]
        }
        if power.gpu == nil { power.gpu = measured["gpu"] }
        var snapshot = Snapshot(
            cpu: cpu.read(),
            gpu: gpu.read(),
            memory: memory.read(),
            network: net,
            disk: disk.read(),
            sensors: sensors.read(),
            power: power,
            battery: battery.read(),
            processes: wantsProcesses ? processes.read(helperRecords: helper.cachedProcesses()) : [],
            volumes: volumes.read(),
            networkDetails: details.read(primary: net.interface),
            bluetooth: bluetooth.read(),
            drives: smart.read(),
            appTraffic: wantsTraffic ? traffic.read() : []
        )
        snapshot.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        snapshot.helperRunning = helper.state == .running
        snapshot.weather = WeatherService.shared.cached(for: Settings.shared.weatherPlace)
        return snapshot
    }
}
