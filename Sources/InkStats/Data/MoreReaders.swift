import InkKit
import AppKit
import CSystem
import CoreWLAN
import HelperShared
import SQLite3
import Darwin
import Foundation
import IOKit
import SystemConfiguration

// MARK: - Processes

/// Processes for the CPU and Memory panels. On its own the app can read only your
/// processes; when the privileged helper is running, its complete list is used instead.
final class ProcessReader {
    private let sampler = ProcessSampler()
    private var appNames: [pid_t: String] = [:]

    func read(helperRecords: [ProcessRecord]? = nil) -> [ProcessUsage] {
        let records = helperRecords ?? sampler.sample()
        var seen = Set<pid_t>()
        let result = records.map { record -> ProcessUsage in
            seen.insert(record.pid)
            return ProcessUsage(pid: record.pid, name: displayName(record), cpu: record.cpu, memory: record.memory)
        }
        appNames = appNames.filter { seen.contains($0.key) }
        return result
    }

    /// Prefer the name an app shows in the Dock over its executable name.
    private func displayName(_ record: ProcessRecord) -> String {
        if let cached = appNames[record.pid] { return cached }
        let name = NSRunningApplication(processIdentifier: record.pid)?.localizedName ?? record.name
        appNames[record.pid] = name
        return name
    }
}

// MARK: - Volumes

final class VolumeReader {
    private var cached: [Volume] = []
    private var checkedAt: TimeInterval = -.infinity

    func invalidate() { checkedAt = -.infinity }

    func read() -> [Volume] {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - checkedAt > 15 else { return cached }
        checkedAt = now
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        cached = urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? Double(v.volumeAvailableCapacity ?? 0)
            return Volume(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent, capacity: Double(total), available: available,
                          ejectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false), isRoot: v.volumeIsRootFileSystem ?? false)
        }
        .sorted { ($0.isRoot ? 0 : 1, $0.name) < ($1.isRoot ? 0 : 1, $1.name) }
        return cached
    }
}

// MARK: - Network details

final class NetworkDetailsReader {
    private let store = SCDynamicStoreCreate(nil, "InkStats.details" as CFString, nil, nil)
    private var cached = NetworkDetails()
    private var checkedAt: TimeInterval = -.infinity

    func invalidate() { checkedAt = -.infinity; wifiCheckedAt = -.infinity }

    func read(primary: String) -> NetworkDetails {
        let now = ProcessInfo.processInfo.systemUptime
        if now - checkedAt > 10, let store {
            checkedAt = now
            var details = NetworkDetails()
            let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            details.router = global?["Router"] as? String
            if let service = global?["PrimaryService"] as? String {
                let v4 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv4" as CFString) as? [String: Any]
                let v6 = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(service)/IPv6" as CFString) as? [String: Any]
                details.ipv4 = v4?["Addresses"] as? [String] ?? []
                details.ipv6 = (v6?["Addresses"] as? [String] ?? []).filter { !$0.hasPrefix("fe80") }
            }
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any]
            details.dns = dns?["ServerAddresses"] as? [String] ?? []

            let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
            if let match = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == primary }) {
                details.kind = SCNetworkInterfaceGetLocalizedDisplayName(match) as String? ?? primary
            }
            let tunnels = SCDynamicStoreCopyKeyList(store, "State:/Network/Interface/(utun|ipsec|ppp)[0-9]+/IPv4" as CFString) as? [String] ?? []
            details.vpn = tunnels.compactMap { $0.split(separator: "/").dropFirst(3).first.map(String.init) }.sorted()
            cached = details
        }
        // Each CoreWLAN query is a round trip to the Wi-Fi daemon.
        if now - wifiCheckedAt > 4.9 {
            wifiCheckedAt = now
            cached.wifi = wifi(primary: primary)
            cached.wifiPowered = CWWiFiClient.shared().interface()?.powerOn()
        }
        return cached
    }

    private var wifiCheckedAt: TimeInterval = -.infinity

    /// The network name needs Location permission, which this app doesn't ask for.
    private func wifi(primary: String) -> WiFiDetails? {
        guard let i = CWWiFiClient.shared().interface(), i.interfaceName == primary, i.rssiValue() != 0 else { return nil }
        let band: String
        switch i.wlanChannel()?.channelBand {
        case .band2GHz: band = "2.4 GHz"
        case .band5GHz: band = "5 GHz"
        case .band6GHz: band = "6 GHz"
        default: band = "—"
        }
        let standards: [CWPHYMode: String] = [.mode11a: "802.11a", .mode11b: "802.11b", .mode11g: "802.11g", .mode11n: "Wi-Fi 4",
                                              .mode11ac: "Wi-Fi 5", .mode11ax: "Wi-Fi 6"]
        return WiFiDetails(rssi: i.rssiValue(), noise: i.noiseMeasurement(), rate: i.transmitRate(),
                           channel: i.wlanChannel()?.channelNumber ?? 0, band: band, standard: standards[i.activePHYMode()] ?? "Wi-Fi")
    }
}

// MARK: - Bluetooth batteries

/// Keyboards, mice and trackpads publish `BatteryPercent` in the I/O Registry. AirPods and
/// Beats only report through system_profiler, which is slow, so it runs on its own queue.
final class BluetoothReader {
    private let queue = DispatchQueue(label: "inkstats.bluetooth", qos: .background)
    private var profiled: [BluetoothBattery] = []
    private var profiledAt: TimeInterval = -.infinity
    private var running = false
    private let lock = NSLock()

    func read() -> [BluetoothBattery] {
        var devices: [BluetoothBattery] = []
        for className in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            IORegistry.forEachService(className) { service in
                guard let percent = IORegistry.int(service, "BatteryPercent"),
                      let name = IORegistry.string(service, "Product"),
                      !devices.contains(where: { $0.name == name }) else { return }
                devices.append(BluetoothBattery(name: name, levels: [("", percent)]))
            }
        }
        refreshProfilerIfNeeded()
        lock.lock()
        let extra = profiled.filter { p in !devices.contains { $0.name == p.name } }
        lock.unlock()
        return devices + extra
    }

    private func refreshProfilerIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        guard !running, now - profiledAt > 120 else { return }
        running = true
        profiledAt = now
        queue.async { [self] in
            let result = Self.profile()
            lock.lock()
            profiled = result
            running = false
            lock.unlock()
        }
    }

    private static func profile() -> [BluetoothBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let parts = [("device_batteryLevelMain", ""), ("device_batteryLevelLeft", "L"), ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "Case")]
        var result: [BluetoothBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let levels = parts.compactMap { key, label -> (String, Int)? in
                        guard let text = info[key] as? String, let n = Int(text.filter(\.isNumber)) else { return nil }
                        return (label, n)
                    }
                    if !levels.isEmpty { result.append(BluetoothBattery(name: name, levels: levels)) }
                }
            }
        }
        return result
    }
}

// MARK: - Sensor names

/// Friendly names for the raw HID sensor names Apple silicon reports.
enum SensorNames {
    static func friendly(_ raw: String) -> String {
        let lower = raw.lowercased()
        let number = raw.split(whereSeparator: { !$0.isNumber }).last.map(String.init)
        func numbered(_ base: String) -> String { number.map { "\(base) \($0)" } ?? base }

        if lower.hasPrefix("pmu tdie") { return numbered("CPU die") }
        if lower.hasPrefix("pmu tdev") { return numbered("PMU device") }
        if lower.hasPrefix("pmu tcal") { return "PMU calibration" }
        if lower.contains("pacc") { return numbered("CPU performance cluster") }
        if lower.contains("eacc") { return numbered("CPU efficiency cluster") }
        if lower.contains("gpu") { return numbered("GPU") }
        if lower.contains("ane") { return "Neural Engine" }
        if lower.contains("isp") { return "Image processor" }
        if lower.contains("soc") { return numbered("SoC") }
        if lower.contains("nand") { return "SSD" }
        if lower.contains("battery") { return "Battery" }
        return raw
    }
}

// MARK: - SSD health

final class SmartReader {
    private var cached: [ISSmart] = []
    private var readAt: TimeInterval = -.infinity

    /// SMART counters change slowly; one read a minute is plenty.
    func read() -> [ISSmart] {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - readAt > 60 else { return cached }
        readAt = now
        var buffer = [ISSmart](repeating: ISSmart(), count: 8)
        let count = Int(is_nvme_smart(&buffer, Int32(buffer.count)))
        cached = Array(buffer.prefix(count))
        return cached
    }
}

// MARK: - Traffic per app

/// `nettop` reports cumulative bytes for every process with a socket, without root.
final class AppTrafficReader {
    private var previous: [String: (rx: Double, tx: Double)] = [:]
    private var previousTime: TimeInterval?

    func read() -> [AppTraffic] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let now = ProcessInfo.processInfo.systemUptime
        var current: [String: (rx: Double, tx: Double)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let rx = Double(fields[1]), let tx = Double(fields[2]) else { continue }
            current[String(fields[0])] = (rx, tx)
        }
        defer { previous = current; previousTime = now }
        guard let previousTime, now > previousTime else { return [] }
        let elapsed = now - previousTime

        var byName: [String: (down: Double, up: Double)] = [:]
        for (key, value) in current {
            guard let before = previous[key] else { continue }
            // Keys look like "Safari.512"; merge processes of the same app.
            let name = key.split(separator: ".").dropLast().joined(separator: ".")
            let entry = byName[name] ?? (0, 0)
            byName[name] = (entry.down + max(0, value.rx - before.rx) / elapsed, entry.up + max(0, value.tx - before.tx) / elapsed)
        }
        return byName.map { AppTraffic(name: $0.key, download: $0.value.down, upload: $0.value.up) }
            .filter { $0.download + $0.upload > 0 }
            .sorted { $0.download + $0.upload > $1.download + $1.upload }
    }
}

// MARK: - Battery history from the system power log

/// macOS keeps a world-readable power log with battery level samples going back days,
/// which covers the time before InkStats was installed. Opened read-only and immutable
/// so InkStats never locks or modifies it.
enum PowerLog {
    private static let path = "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"

    static func batteryAverages(minutes: Int64, buckets: Int) -> [Double?]? {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        let start = Date().timeIntervalSince1970 - Double(minutes) * 60
        let width = Double(minutes) * 60 / Double(buckets)
        let sql = "SELECT CAST((timestamp - ?) / ? AS INTEGER) AS bucket, AVG(Level) FROM PLBatteryAgent_EventBackward_Battery WHERE timestamp >= ? GROUP BY bucket"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, width)
        sqlite3_bind_double(statement, 3, start)
        var result = [Double?](repeating: nil, count: buckets)
        while sqlite3_step(statement) == SQLITE_ROW {
            let bucket = Int(sqlite3_column_int64(statement, 0))
            if bucket >= 0, bucket < buckets { result[bucket] = sqlite3_column_double(statement, 1) }
        }
        return result
    }
}
