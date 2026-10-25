import AppKit

// MARK: - Formatting

enum Format {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    static func bytes(_ value: Double, decimals: Int = 1) -> String {
        var v = max(0, value), i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) B" : String(format: "%.\(decimals)f %@", v, units[i])
    }

    static func rate(_ value: Double) -> String {
        var v = max(0, value) / 1024, i = 1
        while v >= 1000, i < units.count - 1 { v /= 1024; i += 1 }
        return String(format: v < 10 ? "%.1f %@/s" : "%.0f %@/s", v, units[i])
    }

    /// Compact rate for the menu bar, e.g. "820K" or "1.2M".
    static func shortRate(_ value: Double) -> String {
        var v = max(0, value) / 1024, i = 1
        while v >= 1000, i < units.count - 1 { v /= 1024; i += 1 }
        let suffix = String(units[i].prefix(1))
        return String(format: v < 10 ? "%.1f%@" : "%.0f%@", v, suffix)
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String { String(format: "%.\(decimals)f%%", value) }
    static func celsius(_ value: Double) -> String { String(format: "%.1f°C", value) }
    static func watts(_ value: Double) -> String { String(format: value < 10 ? "%.2f W" : "%.1f W", value) }

    static func temperature(_ celsius: Double) -> String {
        let value = Settings.shared.fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    static func wind(_ kmh: Double) -> String {
        Settings.shared.fahrenheit ? "\(Int((kmh / 1.609).rounded())) mph" : "\(Int(kmh.rounded())) km/h"
    }

    private static var clockFormatters: [String: DateFormatter] = [:]

    /// Keeps the user's 12- or 24-hour preference even when labels switch the language.
    static func clock(_ date: Date, _ format: ClockFormat, chinese: Bool, timeZone: TimeZone = .current) -> String {
        let hour = [.oneToTwelve, .zeroToEleven].contains(Locale.current.hourCycle) ? "h" : "H"
        let template: String
        switch format {
        case .time: template = hour + "mm"
        case .weekday: template = "EEE" + hour + "mm"
        case .date: template = "MMMd" + hour + "mm"
        }
        let key = "\(template) \(chinese) \(timeZone.identifier)"
        let formatter = clockFormatters[key] ?? {
            let f = DateFormatter()
            f.locale = chinese ? Locale(identifier: "zh_CN") : .current
            f.timeZone = timeZone
            f.setLocalizedDateFormatFromTemplate(template)
            clockFormatters[key] = f
            return f
        }()
        return formatter.string(from: date)
    }

    static func duration(minutes: Int) -> String { "\(minutes / 60):" + String(format: "%02d", minutes % 60) }
}

// MARK: - Menu bar content

enum BarPart {
    case spark([Double], min: Double, max: Double)
    case text(String)
    case meter(Double)
    case twoLines(String, String)
    case battery(Double)
    case weather(WeatherCondition, day: Bool)
}

func barParts(_ module: ModuleID, _ s: Snapshot, _ h: History) -> [BarPart] {
    switch module {
    case .cpu:
        return [.spark(h.values(.cpu, last: 30), min: 0, max: 100), .text(Format.percent(s.cpu.total))]
    case .gpu:
        return [.spark(h.values(.gpu, last: 30), min: 0, max: 100), .text(Format.percent(s.gpu.utilization ?? 0))]
    case .memory:
        return [.meter(s.memory.usedFraction), .text(Format.percent(s.memory.usedFraction * 100))]
    case .network:
        return [.twoLines("↑ " + Format.shortRate(s.network.upload), "↓ " + Format.shortRate(s.network.download))]
    case .disk:
        return [.twoLines("R " + Format.shortRate(s.disk.read), "W " + Format.shortRate(s.disk.write))]
    case .sensors:
        guard let t = Settings.shared.menuSensorValue(s) else { return [.text("—")] }
        return [.spark(h.values(.menuSensor, last: 30), min: 30, max: 100), .text(String(format: "%.0f°", t))]
    case .power:
        return [.text(s.power.system.map { String(format: "%.1fW", $0) } ?? "—")]
    case .battery:
        return [.battery(s.battery.percent / 100), .text(Format.percent(s.battery.percent))]
    case .weather:
        guard let w = s.weather else { return [.text("—")] }
        return [.weather(w.condition, day: w.isDay), .text(Format.temperature(w.celsius))]
    case .time:
        return [.text(Format.clock(Date(), Settings.shared.clockFormat, chinese: Settings.shared.labelStyle == .chinese))]
    }
}

// MARK: - Panel content

private func peak(_ values: [Double?]) -> Double { values.compactMap { $0 }.max() ?? 0 }

struct GraphSeries {
    let values: [Double?]
    let hue: Hue
    let area: Bool
}

struct GraphSpec {
    var minValue = 0.0
    var maxValue: Double
    var series: [GraphSeries]
    var legend: [(Hue, String)] = []
    var maxLabel: String?
    /// Replaces the history range chips, for graphs that aren't history.
    var caption: String?
    /// Where along the x axis to mark "now", from 0 to 1, for graphs that span past and future.
    var marker: Double?
    var emptyText = "No history yet for this range"
}

struct PanelAction {
    let symbol: String
    let run: () -> Void
}

/// One labelled line in a section. A nil fraction means the line has no bar.
struct GaugeLine {
    let chinese: String
    let english: String
    let value: String
    var fraction: Double?
    var hue: Hue = .ink
    var action: PanelAction?
}

struct GaugeSection {
    var chinese: String?
    var english: String?
    var lines: [GaugeLine]
    var wideLabels = false
}

enum PanelExtra {
    case cores([Double], [CPUCluster])
    case stack([(Double, Hue)], total: Double)
    case gauges(GaugeSection)
    case forecast([ForecastDay])
    case month(Date, moonPhase: Double)
}

struct ForecastDay {
    let chinese: String
    let english: String
    let condition: WeatherCondition
    let low: Double
    let high: Double
    let precipitationChance: Int?
}

struct PanelRow {
    let chinese: String
    let english: String
    let value: String
}

struct PanelSpec {
    let module: ModuleID
    let big: String
    let sub: String
    var graph: GraphSpec?
    var extras: [PanelExtra] = []
    var rows: [PanelRow] = []
    var after: [PanelExtra] = []
}

private func row(_ cn: String, _ en: String, _ value: String) -> PanelRow { PanelRow(chinese: cn, english: en, value: value) }

/// Process names aren't translated, so both label languages show the same text.
private func processSection(_ cn: String, _ en: String, _ processes: [ProcessUsage], by key: (ProcessUsage) -> Double,
                            value: (ProcessUsage) -> String, scale: Double) -> PanelExtra? {
    let top = processes.sorted { key($0) > key($1) }.prefix(5)
    guard !top.isEmpty else { return nil }
    return .gauges(GaugeSection(chinese: cn, english: en, lines: top.map {
        GaugeLine(chinese: $0.name, english: $0.name, value: value($0), fraction: key($0) / scale, hue: .a)
    }, wideLabels: true))
}

func panelSpec(_ module: ModuleID, _ s: Snapshot, _ h: SeriesSource) -> PanelSpec {
    switch module {
    case .cpu:
        let c = s.cpu
        let clusters = c.clusters.map { "\($0.name) ×\($0.cpus.count)" }.joined(separator: " · ")
        var spec = PanelSpec(
            module: module, big: Format.percent(c.total),
            sub: "User \(Format.percent(c.user)) · System \(Format.percent(c.system))",
            graph: GraphSpec(maxValue: 100, series: [GraphSeries(values: h.series(.cpu), hue: .ink, area: true),
                                                      GraphSeries(values: h.series(.cpuSystem), hue: .a, area: false)],
                             legend: [(.ink, "Total"), (.a, "System")], maxLabel: "100%"),
            extras: [.cores(c.cores, c.clusters)],
            rows: [row("用户", "User", Format.percent(c.user, decimals: 1)),
                   row("系统", "System", Format.percent(c.system, decimals: 1)),
                   row("空闲", "Idle", Format.percent(max(0, 100 - c.total), decimals: 1)),
                   row("负载", "Load average", c.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")),
                   row("核心", "Cores", clusters.isEmpty ? "\(c.cores.count)" : clusters)])
        let coreCount = Double(max(1, c.cores.count))
        if let top = processSection("占用最高", "Top processes", s.processes, by: \.cpu,
                                    value: { Format.percent($0.cpu, decimals: 1) }, scale: 100 * coreCount / 4) {
            spec.after = [top]
        }
        return spec

    case .gpu:
        var rows = [row("利用率", "Utilization", Format.percent(s.gpu.utilization ?? 0, decimals: 1))]
        if let m = s.gpu.memoryInUse { rows.append(row("显存", "Memory in use", Format.bytes(m))) }
        if let t = s.sensors.gpu { rows.append(row("温度", "Temperature", Format.celsius(t))) }
        if let w = s.power.gpu { rows.append(row("功耗", "Power", Format.watts(w))) }
        return PanelSpec(module: module, big: Format.percent(s.gpu.utilization ?? 0), sub: s.gpu.name,
                         graph: GraphSpec(maxValue: 100, series: [GraphSeries(values: h.series(.gpu), hue: .ink, area: true)], maxLabel: "100%"),
                         rows: rows)

    case .memory:
        let m = s.memory
        let pressure = m.pressureLevel >= 4 ? "Critical" : m.pressureLevel >= 2 ? "Warning" : "Normal"
        var spec = PanelSpec(
            module: module, big: Format.percent(m.usedFraction * 100),
            sub: "\(Format.bytes(m.used)) of \(Format.bytes(m.total, decimals: 0)) used",
            graph: GraphSpec(maxValue: 100, series: [GraphSeries(values: h.series(.memory), hue: .ink, area: true)], maxLabel: "100%"),
            extras: [.stack([(m.app, .ink), (m.wired, .b), (m.compressed, .a)], total: m.total)],
            rows: [row("应用", "App memory", Format.bytes(m.app)),
                   row("联动", "Wired", Format.bytes(m.wired)),
                   row("压缩", "Compressed", Format.bytes(m.compressed)),
                   row("缓存", "Cached files", Format.bytes(m.cached)),
                   row("交换", "Swap used", Format.bytes(m.swapUsed)),
                   row("压力", "Pressure", pressure)])
        if let top = processSection("占用最高", "Top processes", s.processes, by: \.memory,
                                    value: { Format.bytes($0.memory) }, scale: max(1, m.total / 8)) {
            spec.after = [top]
        }
        return spec

    case .network:
        let n = s.network, d = s.networkDetails
        let down = h.series(.download), up = h.series(.upload)
        var rows = [row("下载", "Download", Format.rate(n.download)),
                    row("上传", "Upload", Format.rate(n.upload)),
                    row("连接", "Connection", "\(d.kind) (\(n.interface))")]
        if let ip = d.ipv4.first { rows.append(row("地址", "IPv4 address", ip)) }
        if let ip = d.ipv6.first { rows.append(row("地址 v6", "IPv6 address", ip)) }
        if let router = d.router { rows.append(row("路由器", "Router", router)) }
        if !d.dns.isEmpty { rows.append(row("域名服务", "DNS", d.dns.prefix(2).joined(separator: ", "))) }
        if !d.vpn.isEmpty { rows.append(row("隧道", "Tunnels", d.vpn.joined(separator: ", "))) }
        rows.append(row("累计", "Since launch", "↓ \(Format.bytes(n.totalDownload))  ↑ \(Format.bytes(n.totalUpload))"))
        var spec = PanelSpec(
            module: module, big: "↓ " + Format.rate(n.download), sub: "↑ \(Format.rate(n.upload)) · \(d.kind)",
            graph: GraphSpec(maxValue: max(64 * 1024, peak(down + up)) * 1.1,
                             series: [GraphSeries(values: down, hue: .a, area: true), GraphSeries(values: up, hue: .b, area: false)],
                             legend: [(.a, "Download"), (.b, "Upload")]),
            rows: rows)
        let apps = s.appTraffic.prefix(5).map { app in
            GaugeLine(chinese: app.name, english: app.name, value: "↓\(Format.shortRate(app.download)) ↑\(Format.shortRate(app.upload))")
        }
        if !apps.isEmpty { spec.after.append(.gauges(GaugeSection(chinese: "流量最多", english: "Top apps", lines: Array(apps), wideLabels: true))) }
        if s.helperRunning, let powered = d.wifiPowered {
            spec.after.append(.gauges(GaugeSection(chinese: "控制", english: "Controls", lines: [
                GaugeLine(chinese: "无线局域网", english: "Wi-Fi", value: powered ? "On" : "Off",
                          action: PanelAction(symbol: powered ? "Turn Off" : "Turn On") { HelperClient.shared.setWiFiPower(!powered) { _ in } }),
            ])))
        }
        if let w = d.wifi {
            // -30 dBm is excellent, -90 dBm is unusable.
            let quality = min(max(Double(w.rssi + 90) / 60, 0), 1)
            spec.after.append(.gauges(GaugeSection(chinese: "无线局域网", english: "Wi-Fi", lines: [
                GaugeLine(chinese: "信号", english: "Signal", value: "\(w.rssi) dBm", fraction: quality, hue: quality < 0.3 ? .red : .a),
                GaugeLine(chinese: "信噪比", english: "Signal to noise", value: "\(w.rssi - w.noise) dB"),
                GaugeLine(chinese: "速率", english: "Link rate", value: "\(Int(w.rate)) Mbps"),
                GaugeLine(chinese: "频段", english: "Band", value: "\(w.standard) · \(w.band) · ch \(w.channel)"),
            ])))
        }
        return spec

    case .disk:
        let d = s.disk
        let read = h.series(.read), write = h.series(.write)
        let volumes = s.volumes.map { v in
            GaugeLine(chinese: v.name, english: v.name, value: "\(Format.bytes(v.available, decimals: 0)) free",
                      fraction: v.capacity > 0 ? (v.capacity - v.available) / v.capacity : 0, hue: .violet,
                      action: v.ejectable ? PanelAction(symbol: "⏏") { try? NSWorkspace.shared.unmountAndEjectDevice(at: v.url) } : nil)
        }
        var health: [PanelExtra] = []
        for (index, drive) in s.drives.enumerated() {
            let title = s.drives.count > 1 ? "SSD \(index + 1) health" : "SSD health"
            health.append(.gauges(GaugeSection(chinese: s.drives.count > 1 ? "固态硬盘 \(index + 1)" : "固态硬盘健康", english: title, lines: [
                GaugeLine(chinese: "寿命已用", english: "Wear", value: "\(drive.percentageUsed)%", fraction: Double(drive.percentageUsed) / 100,
                          hue: drive.percentageUsed > 80 ? .red : .green),
                GaugeLine(chinese: "备用空间", english: "Available spare", value: "\(drive.availableSpare)%"),
                GaugeLine(chinese: "温度", english: "Temperature", value: Format.celsius(drive.celsius)),
                GaugeLine(chinese: "累计写入", english: "Data written", value: Format.bytes(drive.bytesWritten)),
                GaugeLine(chinese: "通电时间", english: "Power-on hours", value: "\(Int(drive.powerOnHours)) h"),
                GaugeLine(chinese: "异常断电", english: "Unsafe shutdowns", value: "\(Int(drive.unsafeShutdowns))"),
                GaugeLine(chinese: "介质错误", english: "Media errors", value: "\(Int(drive.mediaErrors))", hue: drive.mediaErrors > 0 ? .red : .ink),
            ])))
        }
        return PanelSpec(
            module: module, big: "R " + Format.rate(d.read), sub: "W \(Format.rate(d.write)) · \(d.volumeName)",
            graph: GraphSpec(maxValue: max(1024 * 1024, peak(read + write)) * 1.1,
                             series: [GraphSeries(values: read, hue: .a, area: true), GraphSeries(values: write, hue: .b, area: false)],
                             legend: [(.a, "Read"), (.b, "Write")]),
            extras: volumes.isEmpty ? [] : [.gauges(GaugeSection(chinese: "宗卷", english: "Volumes", lines: volumes))],
            rows: [row("读取", "Read", Format.rate(d.read)),
                   row("写入", "Write", Format.rate(d.write))],
            after: health)

    case .sensors:
        let t = s.sensors
        var temps: [GaugeLine] = []
        func add(_ cn: String, _ en: String, _ value: Double?) {
            guard let value else { return }
            temps.append(GaugeLine(chinese: cn, english: en, value: String(format: "%.1f°", value), fraction: value / 110, hue: value > 85 ? .red : .c))
        }
        add("处理器", "CPU average", t.cpuAverage)
        add("最热", "CPU hottest", t.cpuHottest)
        add("图形", "GPU", t.gpu)
        add("固态硬盘", "SSD", t.ssd)
        add("电池", "Battery", t.battery)
        let fans = t.fans.map { fan in
            GaugeLine(chinese: "风扇 \(fan.index + 1)", english: "Fan \(fan.index + 1)",
                      value: fan.rpm < 1 ? "off" : "\(Int(fan.rpm)) rpm", fraction: fan.rpm / (fan.maxRPM ?? 6000), hue: .a)
        }
        var extras: [PanelExtra] = [.gauges(GaugeSection(lines: temps))]
        if !fans.isEmpty { extras.append(.gauges(GaugeSection(chinese: "风扇", english: "Fans", lines: fans))) }
        return PanelSpec(
            module: module, big: t.cpuAverage.map { String(format: "%.1f°C", $0) } ?? "—", sub: "CPU die average · \(t.all.count) sensors",
            graph: GraphSpec(minValue: 20, maxValue: 110, series: [GraphSeries(values: h.series(.temperature), hue: .b, area: true)], maxLabel: "110°"),
            extras: extras)

    case .power:
        let p = s.power
        var rows: [PanelRow] = []
        func add(_ cn: String, _ en: String, _ value: Double?) {
            if let value { rows.append(row(cn, en, Format.watts(value))) }
        }
        add("整机", "System", p.system)
        add("适配器", "Adapter input", p.adapter)
        add("电池", "Battery", p.battery)
        add("处理器", "CPU", p.cpu)
        add("图形", "GPU", p.gpu)
        add("神经引擎", "Neural Engine", p.neuralEngine)
        add("内存", "Memory", p.memory)
        let total = h.series(.power)
        return PanelSpec(
            module: module, big: p.system.map(Format.watts) ?? "—", sub: "Whole system draw",
            graph: GraphSpec(maxValue: max(30, peak(total)) * 1.1,
                             series: [GraphSeries(values: total, hue: .ink, area: true), GraphSeries(values: h.series(.gpuPower), hue: .a, area: false)],
                             legend: [(.ink, "System"), (.a, "GPU")]),
            rows: rows)

    case .battery:
        let b = s.battery
        let status = b.charging ? "Charging" : b.onAdapter ? "On power adapter" : "On battery"
        var rows = [row("电量", "Charge", Format.percent(b.percent)), row("状态", "Status", status)]
        if let m = b.minutesRemaining, !b.onAdapter { rows.append(row("剩余", "Time remaining", Format.duration(minutes: m))) }
        if let health = b.health { rows.append(row("健康", "Health", Format.percent(health))) }
        if let cycles = b.cycles { rows.append(row("循环", "Cycle count", "\(cycles)")) }
        if let t = s.sensors.battery { rows.append(row("温度", "Temperature", Format.celsius(t))) }
        if let w = b.watts, abs(w) > 0.05 { rows.append(row("功率", w < 0 ? "Discharge rate" : "Charge rate", Format.watts(abs(w)))) }
        var spec = PanelSpec(module: module, big: Format.percent(b.percent), sub: status,
                             graph: GraphSpec(maxValue: 100, series: [GraphSeries(values: h.series(.battery), hue: .green, area: true)], maxLabel: "100%"),
                             rows: rows)
        let devices = s.bluetooth.flatMap { device in
            device.levels.map { level in
                let name = level.part.isEmpty ? device.name : "\(device.name) \(level.part)"
                return GaugeLine(chinese: name, english: name, value: "\(level.percent)%", fraction: Double(level.percent) / 100,
                                 hue: level.percent < 20 ? .red : .green)
            }
        }
        if !devices.isEmpty { spec.after.append(.gauges(GaugeSection(chinese: "蓝牙设备", english: "Bluetooth devices", lines: devices, wideLabels: true))) }
        if s.helperRunning {
            let on = s.lowPowerMode
            spec.after.append(.gauges(GaugeSection(chinese: "控制", english: "Controls", lines: [
                GaugeLine(chinese: "低电量模式", english: "Low Power Mode", value: on ? "On" : "Off",
                          action: PanelAction(symbol: on ? "Turn Off" : "Turn On") { HelperClient.shared.setLowPowerMode(!on) { _ in } }),
            ])))
        }
        return spec

    case .weather:
        return weatherSpec(s)

    case .time:
        return timeSpec(Date())
    }
}

private func timeSpec(_ now: Date) -> PanelSpec {
    let settings = Settings.shared, chinese = settings.labelStyle == .chinese
    let calendar = Calendar.current
    let fullDate = DateFormatter()
    fullDate.locale = chinese ? Locale(identifier: "zh_CN") : .current
    fullDate.dateStyle = .full
    let phase = Sky.moonPhase(at: now)
    var spec = PanelSpec(module: .time, big: Format.clock(now, .time, chinese: chinese), sub: fullDate.string(from: now),
                         extras: [.month(now, moonPhase: phase)])

    let time = DateFormatter()
    time.timeStyle = .short
    if let place = settings.weatherPlace {
        let start = calendar.startOfDay(for: now)
        let elevations = (0...96).map { Sky.sunElevation(at: start.addingTimeInterval(Double($0) * 900), latitude: place.latitude, longitude: place.longitude) }
        // Symmetric limits put the horizon on the graph's middle line.
        let limit = max(10, elevations.map(abs).max() ?? 90)
        spec.graph = GraphSpec(minValue: -limit, maxValue: limit, series: [GraphSeries(values: elevations, hue: .c, area: true)],
                               caption: "Sun today · \(place.name)", marker: now.timeIntervalSince(start) / 86400)
        let sun = Sky.sunTimes(on: now, latitude: place.latitude, longitude: place.longitude)
        spec.rows.append(row("日出", "Sunrise", sun.rise.map(time.string) ?? "—"))
        spec.rows.append(row("日落", "Sunset", sun.set.map(time.string) ?? "—"))
        if let rise = sun.rise, let set = sun.set, set > rise {
            let minutes = Int(set.timeIntervalSince(rise) / 60)
            spec.rows.append(row("昼长", "Daylight", chinese ? "\(minutes / 60)小时\(minutes % 60)分" : "\(minutes / 60)h \(minutes % 60)m"))
        }
    }
    let moon = Sky.moonName(phase)
    spec.rows.append(row("月相", "Moon", "\(chinese ? moon.chinese : moon.english) · \(Format.percent(Sky.moonIllumination(phase) * 100))"))
    spec.rows.append(row("农历", "Chinese calendar", Lunar.date(now)))

    let clocks: [GaugeLine] = settings.worldClocks.compactMap { identifier in
        guard let zone = TimeZone(identifier: identifier) else { return nil }
        let name = WorldClock.city(identifier)
        let hours = Double(zone.secondsFromGMT(for: now) - TimeZone.current.secondsFromGMT(for: now)) / 3600
        let offset = hours == 0 ? "" : " · " + (hours > 0 ? "+" : "−") + String(format: hours.truncatingRemainder(dividingBy: 1) == 0 ? "%.0fh" : "%.1fh", abs(hours))
        let sameDay = calendar.isDate(now, inSameDayAs: now.addingTimeInterval(hours * 3600))
        return GaugeLine(chinese: name, english: name, value: Format.clock(now, sameDay ? .time : .weekday, chinese: chinese, timeZone: zone) + offset)
    }
    if !clocks.isEmpty { spec.after.append(.gauges(GaugeSection(chinese: "世界时钟", english: "World clocks", lines: clocks))) }

    let events = CalendarEvents.shared.upcoming(now: now).map { event in
        let tomorrow = !calendar.isDate(event.start, inSameDayAs: now) && event.start > now
        let when = event.allDay ? (chinese ? "全天" : "All day") : time.string(from: event.start)
        return GaugeLine(chinese: event.title, english: event.title, value: tomorrow ? (chinese ? "明天 " : "Tomorrow ") + when : when)
    }
    if !events.isEmpty { spec.after.append(.gauges(GaugeSection(chinese: "日程", english: "Upcoming", lines: events))) }
    return spec
}

enum WorldClock {
    /// "America/Los_Angeles" → "Los Angeles".
    static func city(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier).replacingOccurrences(of: "_", with: " ")
    }
}

private func weatherSpec(_ s: Snapshot) -> PanelSpec {
    let caption = "Next 24 hours"
    guard let w = s.weather else {
        let place = Settings.shared.weatherPlace
        let sub = place == nil ? "Choose a place in Settings → Weather"
            : WeatherService.shared.error != nil ? "Couldn't load the forecast; retrying soon" : "Loading the forecast for \(place!.name)…"
        return PanelSpec(module: .weather, big: "—", sub: sub,
                         graph: GraphSpec(maxValue: 1, series: [], caption: caption, emptyText: place == nil ? "No place chosen" : "No forecast yet"))
    }

    let time = DateFormatter()
    time.timeZone = w.timeZone
    time.timeStyle = .short
    var rows = [row("体感", "Feels like", Format.temperature(w.feelsLike)),
                row("湿度", "Humidity", Format.percent(w.humidity)),
                row("风速", "Wind", Format.wind(w.windKmh))]
    if let chance = w.days.first?.precipitationChance { rows.append(row("降水概率", "Chance of rain today", "\(chance)%")) }
    if let sunrise = w.sunrise, let sunset = w.sunset {
        rows.append(row("日出日落", "Sunrise · sunset", "\(time.string(from: sunrise)) · \(time.string(from: sunset))"))
    }
    // Open-Meteo's terms ask for this attribution.
    rows.append(row("数据", "Data", "Open-Meteo.com · \(time.string(from: w.fetched))"))

    let weekday = { (identifier: String) -> DateFormatter in
        let f = DateFormatter()
        f.locale = Locale(identifier: identifier)
        f.timeZone = w.timeZone
        f.dateFormat = "EEE"
        return f
    }
    let english = weekday("en_US"), chinese = weekday("zh_CN")
    let days = w.days.enumerated().map { index, day in
        ForecastDay(chinese: index == 0 ? "今天" : chinese.string(from: day.date), english: index == 0 ? "Today" : english.string(from: day.date),
                    condition: day.condition, low: day.low, high: day.high, precipitationChance: day.precipitationChance)
    }

    let temps = w.hourly.compactMap { $0 }
    let low = (temps.min() ?? w.celsius) - 2, high = (temps.max() ?? w.celsius) + 2
    return PanelSpec(
        module: .weather, big: Format.temperature(w.celsius), sub: "\(w.condition.names.english) · \(w.place.name)",
        graph: GraphSpec(minValue: low, maxValue: high, series: [GraphSeries(values: w.hourly, hue: .c, area: true)],
                         maxLabel: Format.temperature(high - 2), caption: caption),
        rows: rows,
        after: days.isEmpty ? [] : [.forecast(days)])
}
