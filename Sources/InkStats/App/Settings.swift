import Foundation

enum ModuleID: String, CaseIterable {
    case cpu, gpu, memory, network, disk, sensors, power, battery, weather, time

    /// Seal character, English tag, Chinese name, English name.
    var names: (character: String, tag: String, chinese: String, english: String) {
        switch self {
        case .cpu: return ("芯", "CPU", "处理器", "CPU")
        case .gpu: return ("显", "GPU", "图形", "GPU")
        case .memory: return ("存", "MEM", "内存", "Memory")
        case .network: return ("网", "NET", "网络", "Network")
        case .disk: return ("盘", "DSK", "磁盘", "Disk")
        case .sensors: return ("温", "TMP", "温度", "Sensors")
        case .power: return ("电", "PWR", "功耗", "Power")
        case .battery: return ("池", "BAT", "电池", "Battery")
        case .weather: return ("天", "WX", "天气", "Weather")
        case .time: return ("时", "TIME", "时间", "Time")
        }
    }
}

enum ClockFormat: String, CaseIterable {
    case time, weekday, date
}

enum PanelAppearance: String, CaseIterable {
    case system, light, dark
}

enum LabelSetting: String, CaseIterable {
    case theme, english, chinese
}

final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    private func store(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    var theme: ThemeID {
        get { value("theme", ThemeID.ink) }
        set { store("theme", newValue.rawValue) }
    }

    var appearance: PanelAppearance {
        get { value("appearance", PanelAppearance.system) }
        set { store("appearance", newValue.rawValue) }
    }

    var labels: LabelSetting {
        get { value("labels", LabelSetting.theme) }
        set { store("labels", newValue.rawValue) }
    }

    var labelStyle: LabelStyle {
        switch labels {
        case .theme: return theme.defaultLabels
        case .english: return .english
        case .chinese: return .chinese
        }
    }

    var texture: Double {
        get { defaults.object(forKey: "texture") as? Double ?? 1 }
        set { store("texture", newValue) }
    }

    var interval: Double {
        get { defaults.object(forKey: "interval") as? Double ?? 2 }
        set { store("interval", newValue) }
    }

    var historyDays: Int {
        get { defaults.object(forKey: "historyDays") as? Int ?? 7 }
        set { store("historyDays", newValue) }
    }

    var combineItems: Bool {
        get { defaults.bool(forKey: "combineItems") }
        set { store("combineItems", newValue) }
    }

    /// "cpuAverage", "cpuHottest", "ssd", "battery", or a raw sensor name.
    var menuSensor: String {
        get { defaults.string(forKey: "menuSensor") ?? "cpuAverage" }
        set { store("menuSensor", newValue) }
    }

    func menuSensorValue(_ s: Snapshot) -> Double? {
        switch menuSensor {
        case "cpuAverage": return s.sensors.cpuAverage
        case "cpuHottest": return s.sensors.cpuHottest
        case "ssd": return s.sensors.ssd
        case "battery": return s.sensors.battery
        default: return s.sensors.all.first { $0.key == menuSensor }?.celsius ?? s.sensors.cpuAverage
        }
    }

    var weatherPlace: WeatherPlace? {
        get { defaults.data(forKey: "weatherPlace").flatMap { try? JSONDecoder().decode(WeatherPlace.self, from: $0) } }
        set {
            if let data = newValue.flatMap({ try? JSONEncoder().encode($0) }) { store("weatherPlace", data) }
            else { defaults.removeObject(forKey: "weatherPlace") }
        }
    }

    var fahrenheit: Bool {
        get { defaults.object(forKey: "fahrenheit") as? Bool ?? (Locale.current.measurementSystem == .us) }
        set { store("fahrenheit", newValue) }
    }

    var clockFormat: ClockFormat {
        get { value("clockFormat", ClockFormat.weekday) }
        set { store("clockFormat", newValue.rawValue) }
    }

    /// Time zone identifiers, in the order the user added them.
    var worldClocks: [String] {
        get { defaults.stringArray(forKey: "worldClocks") ?? [] }
        set { store("worldClocks", newValue) }
    }

    var showEvents: Bool {
        get { defaults.bool(forKey: "showEvents") }
        set { store("showEvents", newValue) }
    }

    var enabledModules: [ModuleID] {
        get {
            // Weather is the only item that uses the network, and macOS already shows a clock.
            guard let raw = defaults.stringArray(forKey: "modules") else { return ModuleID.allCases.filter { $0 != .weather && $0 != .time } }
            let set = Set(raw)
            return ModuleID.allCases.filter { set.contains($0.rawValue) }
        }
        set { store("modules", newValue.map(\.rawValue)) }
    }

    func toggle(_ module: ModuleID) {
        var modules = enabledModules
        if let index = modules.firstIndex(of: module) { modules.remove(at: index) } else { modules.append(module) }
        enabledModules = modules
    }
}
