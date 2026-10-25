import InkKit
import CSystem
import Foundation

struct CPUCluster {
    let name: String
    let cpus: [Int]
}

struct CPUStats {
    var total = 0.0
    var user = 0.0
    var system = 0.0
    var cores: [Double] = []
    var clusters: [CPUCluster] = []
    var load: [Double] = [0, 0, 0]
}

struct GPUStats {
    var name = "GPU"
    var utilization: Double?
    var memoryInUse: Double?
}

struct MemoryStats {
    var total = 0.0
    var app = 0.0
    var wired = 0.0
    var compressed = 0.0
    var cached = 0.0
    var swapUsed = 0.0
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    var pressureLevel = 1

    var used: Double { app + wired + compressed }
    var usedFraction: Double { total > 0 ? used / total : 0 }
}

struct NetworkStats {
    var download = 0.0
    var upload = 0.0
    var totalDownload = 0.0
    var totalUpload = 0.0
    var interface = "—"
}

struct DiskStats {
    var read = 0.0
    var write = 0.0
    var volumeName = "Macintosh HD"
    var capacity = 0.0
    var available = 0.0
}

struct Fan {
    let index: Int
    let rpm: Double
    let maxRPM: Double?
    var minRPM: Double?
}

struct SensorStats {
    var cpuAverage: Double?
    var cpuHottest: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var fans: [Fan] = []
    var all: [NamedSensor] = []
}

struct PowerStats {
    var system: Double?
    var adapter: Double?
    var battery: Double?
    var cpu: Double?
    var gpu: Double?
    var neuralEngine: Double?
    var memory: Double?
}

struct BatteryStats {
    var present = false
    var percent = 0.0
    var charging = false
    var onAdapter = false
    var minutesRemaining: Int?
    var cycles: Int?
    var health: Double?
    var watts: Double?
}

struct ProcessUsage {
    let pid: pid_t
    let name: String
    let cpu: Double
    let memory: Double
}

struct Volume {
    let url: URL
    let name: String
    let capacity: Double
    let available: Double
    let ejectable: Bool
    let isRoot: Bool
}

struct WiFiDetails {
    let rssi: Int
    let noise: Int
    let rate: Double
    let channel: Int
    let band: String
    let standard: String
}

struct NetworkDetails {
    var kind = "—"
    var ipv4: [String] = []
    var ipv6: [String] = []
    var router: String?
    var dns: [String] = []
    var vpn: [String] = []
    var wifi: WiFiDetails?
    /// nil on Macs without Wi-Fi.
    var wifiPowered: Bool?
}

struct BluetoothBattery {
    let name: String
    let levels: [(part: String, percent: Int)]
}

struct AppTraffic {
    let name: String
    let download: Double
    let upload: Double
}

struct NamedSensor {
    let key: String
    let name: String
    let celsius: Double
}

struct Snapshot {
    var cpu = CPUStats()
    var gpu = GPUStats()
    var memory = MemoryStats()
    var network = NetworkStats()
    var disk = DiskStats()
    var sensors = SensorStats()
    var power = PowerStats()
    var battery = BatteryStats()
    var processes: [ProcessUsage] = []
    var volumes: [Volume] = []
    var networkDetails = NetworkDetails()
    var bluetooth: [BluetoothBattery] = []
    var drives: [ISSmart] = []
    var appTraffic: [AppTraffic] = []
    var lowPowerMode = false
    var helperRunning = false
    var weather: WeatherReport?
}
