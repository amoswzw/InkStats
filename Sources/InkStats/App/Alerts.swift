import Foundation
import UserNotifications

/// A condition worth a notification. Thresholds and on/off state live in UserDefaults
/// under `alert.<id>.*` so the settings window can bind to them directly.
enum AlertRule: String, CaseIterable {
    case cpuHigh, memoryPressure, temperatureHigh, diskLow, batteryLow, batteryCharged, networkLost

    var title: (english: String, chinese: String) {
        switch self {
        case .cpuHigh: return ("CPU usage is high", "处理器占用过高")
        case .memoryPressure: return ("Memory pressure is high", "内存压力过高")
        case .temperatureHigh: return ("CPU is running hot", "处理器温度过高")
        case .diskLow: return ("Startup disk is almost full", "启动磁盘空间不足")
        case .batteryLow: return ("Battery is low", "电池电量低")
        case .batteryCharged: return ("Battery is charged", "电池已充好")
        case .networkLost: return ("Network connection lost", "网络连接已断开")
        }
    }

    /// The threshold's default, unit, and allowed range; nil for rules without a threshold.
    var threshold: (initial: Double, unit: String, range: ClosedRange<Double>, step: Double)? {
        switch self {
        case .cpuHigh: return (90, "%", 50...100, 5)
        case .temperatureHigh: return (95, "°C", 60...110, 1)
        case .diskLow: return (10, "GB", 1...200, 1)
        case .batteryLow: return (20, "%", 5...50, 5)
        case .batteryCharged: return (100, "%", 50...100, 5)
        case .memoryPressure, .networkLost: return nil
        }
    }

    /// How long the condition must hold before notifying, in seconds.
    var sustain: TimeInterval {
        switch self {
        case .cpuHigh: return 5 * 60
        case .temperatureHigh: return 60
        case .memoryPressure, .networkLost: return 30
        case .diskLow, .batteryLow, .batteryCharged: return 0
        }
    }

    var enabledKey: String { "alert.\(rawValue).enabled" }
    var thresholdKey: String { "alert.\(rawValue).threshold" }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    var value: Double { UserDefaults.standard.object(forKey: thresholdKey) as? Double ?? threshold?.initial ?? 0 }

    /// Returns the message body when the condition holds right now, otherwise nil.
    func check(_ s: Snapshot) -> String? {
        switch self {
        case .cpuHigh:
            return s.cpu.total >= value ? "Above \(Int(value))% for 5 minutes (now \(Format.percent(s.cpu.total)))." : nil
        case .memoryPressure:
            return s.memory.pressureLevel >= 2 ? "macOS reports \(s.memory.pressureLevel >= 4 ? "critical" : "elevated") memory pressure." : nil
        case .temperatureHigh:
            guard let t = s.sensors.cpuHottest, t >= value else { return nil }
            return "The hottest CPU sensor reads \(Format.celsius(t))."
        case .diskLow:
            guard let root = s.volumes.first(where: \.isRoot), root.capacity > 0, root.available < value * 1_073_741_824 else { return nil }
            return "\(root.name) has \(Format.bytes(root.available)) left."
        case .batteryLow:
            guard s.battery.present, !s.battery.onAdapter, s.battery.percent <= value else { return nil }
            return "\(Format.percent(s.battery.percent)) remaining."
        case .batteryCharged:
            guard s.battery.present, s.battery.onAdapter, s.battery.percent >= value else { return nil }
            return "Charged to \(Format.percent(s.battery.percent))."
        case .networkLost:
            return s.networkDetails.ipv4.isEmpty && s.networkDetails.ipv6.isEmpty ? "No network interface has an address." : nil
        }
    }
}

/// Fires each rule once per episode: the condition must hold for the rule's sustain time,
/// and the rule re-arms only after the condition clears.
final class AlertEngine {
    private var since: [AlertRule: Date] = [:]
    private var fired: Set<AlertRule> = []
    private var authorized = false

    /// Replaced in tests; by default posts a macOS notification.
    lazy var deliver: (AlertRule, String, Bool) -> Void = { [weak self] rule, body, chinese in self?.post(rule, body: body, chinese: chinese) }

    func requestAuthorizationIfNeeded() {
        guard !authorized, AlertRule.allCases.contains(where: \.isEnabled) else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { self.authorized = granted }
        }
    }

    func evaluate(_ snapshot: Snapshot, chinese: Bool, now: Date = Date()) {
        for rule in AlertRule.allCases {
            guard rule.isEnabled, let body = rule.check(snapshot) else {
                since[rule] = nil
                fired.remove(rule)
                continue
            }
            let start = since[rule] ?? now
            since[rule] = start
            guard !fired.contains(rule), now.timeIntervalSince(start) >= rule.sustain else { continue }
            fired.insert(rule)
            deliver(rule, body, chinese)
        }
    }

    private func post(_ rule: AlertRule, body: String, chinese: Bool) {
        let content = UNMutableNotificationContent()
        content.title = chinese ? "\(rule.title.chinese) · \(rule.title.english)" : rule.title.english
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "inkstats.\(rule.rawValue).\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
