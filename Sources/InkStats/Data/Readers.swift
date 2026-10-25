import CSystem
import Darwin
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

// MARK: - CPU

final class CPUReader {
    let clusters: [CPUCluster]
    private var previousTicks: [UInt32] = []

    init() {
        clusters = CPUReader.readClusters()
    }

    func read() -> CPUStats {
        var stats = CPUStats(clusters: clusters)
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { stats.load = load }

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return stats }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let states = Int(CPU_STATE_MAX)
        let ticks = (0..<Int(cpuCount) * states).map { UInt32(bitPattern: info[$0]) }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else {
            stats.cores = Array(repeating: 0, count: Int(cpuCount))
            return stats
        }

        var busyUser = 0.0, busySystem = 0.0, all = 0.0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            func delta(_ state: Int32) -> Double { Double(ticks[base + Int(state)] &- previousTicks[base + Int(state)]) }
            let user = delta(CPU_STATE_USER) + delta(CPU_STATE_NICE)
            let system = delta(CPU_STATE_SYSTEM)
            let total = user + system + delta(CPU_STATE_IDLE)
            stats.cores.append(total > 0 ? (user + system) / total * 100 : 0)
            busyUser += user
            busySystem += system
            all += total
        }
        if all > 0 {
            stats.user = busyUser / all * 100
            stats.system = busySystem / all * 100
            stats.total = stats.user + stats.system
        }
        return stats
    }

    /// Groups logical CPUs by the cluster type in the device tree, then names each group
    /// with the perflevel names macOS reports. Cluster letters are ranked by speed because
    /// their meaning shifts between chip generations ("P" is the fastest tier on every chip).
    private static func readClusters() -> [CPUCluster] {
        var byType: [String: [Int]] = [:]
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS {
                while case let child = IOIteratorNext(iterator), child != 0 {
                    if let type = IORegistry.string(child, "cluster-type"), let id = IORegistry.int(child, "logical-cpu-id") {
                        byType[type, default: []].append(id)
                    }
                    IOObjectRelease(child)
                }
                IOObjectRelease(iterator)
            }
            IOObjectRelease(cpus)
        }

        let speedRank = ["P": 0, "M": 1, "E": 2]
        let types = byType.keys.sorted { (speedRank[$0] ?? 9, $0) < (speedRank[$1] ?? 9, $1) }
        let levelNames = (0..<(Sysctl.int("hw.nperflevels") ?? 0)).compactMap { Sysctl.string("hw.perflevel\($0).name") }
        let fallback = ["P": "Performance", "M": "Mid", "E": "Efficiency"]

        return types.enumerated().map { index, type in
            let name = index < levelNames.count ? levelNames[index] : (fallback[type] ?? type)
            return CPUCluster(name: name, cpus: byType[type]!.sorted())
        }
    }
}

// MARK: - GPU

final class GPUReader {
    private let name: String

    init() {
        let chip = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
        name = chip.hasPrefix("Apple") ? "\(chip) GPU" : "GPU"
    }

    func read() -> GPUStats {
        var stats = GPUStats(name: name)
        IORegistry.forEachService("IOAccelerator") { service in
            guard stats.utilization == nil,
                  let perf = IORegistry.property(service, "PerformanceStatistics") as? [String: Any] else { return }
            stats.utilization = (perf["Device Utilization %"] as? NSNumber)?.doubleValue
            stats.memoryInUse = (perf["In use system memory"] as? NSNumber)?.doubleValue
        }
        return stats
    }
}

// MARK: - Memory

final class MemoryReader {
    func read() -> MemoryStats {
        var stats = MemoryStats(total: Double(ProcessInfo.processInfo.physicalMemory))

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            stats.app = Double(vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0) * page
            stats.wired = Double(vm.wire_count) * page
            stats.compressed = Double(vm.compressor_page_count) * page
            stats.cached = Double(vm.external_page_count + vm.purgeable_count) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { stats.swapUsed = Double(swap.xsu_used) }
        stats.pressureLevel = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
        return stats
    }
}

// MARK: - Network

final class NetworkReader {
    private var previous: (rx: UInt64, tx: UInt64, time: TimeInterval)?
    private var totals = (rx: 0.0, tx: 0.0)
    private var primary = "—"
    private var primaryCheckedAt: TimeInterval = -.infinity
    private let store = SCDynamicStoreCreate(nil, "InkStats" as CFString, nil, nil)

    func invalidate() { primaryCheckedAt = -.infinity }

    func read() -> NetworkStats {
        let now = ProcessInfo.processInfo.systemUptime
        if now - primaryCheckedAt > 10 {
            primaryCheckedAt = now
            if let store,
               let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
               let name = global["PrimaryInterface"] as? String {
                primary = name
            }
        }

        let counters = Self.counters()
        var stats = NetworkStats(interface: primary)
        if let previous, now > previous.time {
            let elapsed = now - previous.time
            let rx = Double(counters.rx &- previous.rx), tx = Double(counters.tx &- previous.tx)
            stats.download = rx / elapsed
            stats.upload = tx / elapsed
            totals.rx += rx
            totals.tx += tx
        }
        previous = (counters.rx, counters.tx, now)
        stats.totalDownload = totals.rx
        stats.totalUpload = totals.tx
        return stats
    }

    /// Physical and cellular interfaces only; tunnels and loopback would double count.
    private static func counters() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                            rx += info.ifm_data.ifi_ibytes
                            tx += info.ifm_data.ifi_obytes
                        }
                    }
                }
                guard header.ifm_msglen > 0 else { break }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }
}

// MARK: - Disk

final class DiskReader {
    private var previous: (read: UInt64, write: UInt64, time: TimeInterval)?
    private var space = (name: "Macintosh HD", capacity: 0.0, available: 0.0)
    private var spaceCheckedAt: TimeInterval = -.infinity

    func invalidate() { spaceCheckedAt = -.infinity }

    func read() -> DiskStats {
        let now = ProcessInfo.processInfo.systemUptime
        if now - spaceCheckedAt > 15 {
            spaceCheckedAt = now
            let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) {
                space = (values.volumeLocalizedName ?? space.name,
                         Double(values.volumeTotalCapacity ?? 0),
                         Double(values.volumeAvailableCapacityForImportantUsage ?? 0))
            }
        }

        var read: UInt64 = 0, write: UInt64 = 0
        IORegistry.forEachService("IOBlockStorageDriver") { service in
            guard let statistics = IORegistry.property(service, "Statistics") as? [String: Any] else { return }
            read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }

        var stats = DiskStats(volumeName: space.name, capacity: space.capacity, available: space.available)
        if let previous, now > previous.time {
            let elapsed = now - previous.time
            stats.read = Double(read &- previous.read) / elapsed
            stats.write = Double(write &- previous.write) / elapsed
        }
        previous = (read, write, now)
        return stats
    }
}

// MARK: - Temperatures and fans

final class SensorReader {
    private var buffer = [ISTemperature](repeating: ISTemperature(), count: 192)
    private var cached: SensorStats?
    private var readAt: TimeInterval = -.infinity

    /// A full sensor pass costs tens of milliseconds and temperatures move slowly,
    /// so readings are reused for a few seconds.
    func read() -> SensorStats {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - readAt < 2.9 { return cached }
        let stats = readNow()
        cached = stats
        readAt = now
        return stats
    }

    private func readNow() -> SensorStats {
        var stats = SensorStats()
        let count = Int(is_hid_temperatures(&buffer, Int32(buffer.count)))

        var cpu: [Double] = [], gpu: [Double] = [], ssd: [Double] = [], battery: [Double] = []
        var byName: [String: [Double]] = [:]
        for reading in buffer.prefix(count) {
            let value = reading.celsius
            // Several sensors report placeholder values far outside any physical range.
            guard value > -20, value < 150 else { continue }
            let raw = withUnsafeBytes(of: reading.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            byName[raw, default: []].append(value)
            let name = raw.lowercased()
            if name.contains("gpu") { gpu.append(value) }
            else if name.contains("tdie") || name.contains("acc") || name.contains("cpu") { cpu.append(value) }
            else if name.contains("nand") { ssd.append(value) }
            else if name.contains("battery") { battery.append(value) }
        }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        stats.cpuAverage = average(cpu)
        stats.cpuHottest = cpu.max()
        stats.gpu = average(gpu)
        stats.ssd = average(ssd)
        stats.battery = average(battery)
        // The same sensor is often published several times; one averaged entry per name.
        stats.all = byName.map { raw, values in NamedSensor(key: raw, name: SensorNames.friendly(raw), celsius: average(values) ?? 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var fanCount = 0.0
        if is_smc_read("FNum", &fanCount) {
            for index in 0..<Int(fanCount) {
                var rpm = 0.0, maxRPM = 0.0
                guard is_smc_read("F\(index)Ac", &rpm) else { continue }
                var minRPM = 0.0
                let hasMax = is_smc_read("F\(index)Mx", &maxRPM) && maxRPM > 0
                let hasMin = is_smc_read("F\(index)Mn", &minRPM) && minRPM > 0
                stats.fans.append(Fan(index: index, rpm: max(0, rpm), maxRPM: hasMax ? maxRPM : nil, minRPM: hasMin ? minRPM : nil))
            }
        }
        return stats
    }
}

// MARK: - Power

final class PowerReader {
    private var lastSample: TimeInterval?

    func read() -> PowerStats {
        var stats = PowerStats()
        var value = 0.0
        // Widely documented SMC keys: total system draw, adapter input, battery flow.
        if is_smc_read("PSTR", &value) { stats.system = value }
        if is_smc_read("PDTR", &value) { stats.adapter = value }
        if is_smc_read("PPBR", &value) { stats.battery = value }

        let now = ProcessInfo.processInfo.systemUptime
        var energy = ISEnergy()
        if is_energy_sample(&energy), let lastSample, now > lastSample {
            let elapsed = now - lastSample
            func watts(_ joules: Double) -> Double? { joules > 0 ? joules / elapsed : nil }
            stats.cpu = watts(energy.cpu)
            stats.gpu = watts(energy.gpu) ?? (energy.gpu == 0 ? 0 : nil)
            stats.neuralEngine = watts(energy.ane)
            stats.memory = watts(energy.dram)
        }
        lastSample = now
        return stats
    }
}

// MARK: - Battery

final class BatteryReader {
    func read() -> BatteryStats {
        var stats = BatteryStats()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return stats }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = (description[kIOPSCurrentCapacityKey] as? Double) ?? 0
            let maximum = (description[kIOPSMaxCapacityKey] as? Double) ?? 100
            stats.present = true
            stats.percent = maximum > 0 ? current / maximum * 100 : 0
            stats.charging = description[kIOPSIsChargingKey] as? Bool ?? false
            stats.onAdapter = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 { stats.minutesRemaining = minutes }
        }
        guard stats.present, let battery = IORegistry.firstService("AppleSmartBattery") else { return stats }
        defer { IOObjectRelease(battery) }

        stats.cycles = IORegistry.int(battery, "CycleCount")
        let data = IORegistry.property(battery, "BatteryData") as? [String: Any]
        let design = (data?["DesignCapacity"] as? NSNumber)?.doubleValue ?? (IORegistry.property(battery, "DesignCapacity") as? NSNumber)?.doubleValue
        let full = (data?["FullChargeCapacity"] as? NSNumber)?.doubleValue ?? (IORegistry.property(battery, "AppleRawMaxCapacity") as? NSNumber)?.doubleValue
        if let design, let full, design > 0 { stats.health = min(100, full / design * 100) }

        if let millivolts = IORegistry.int(battery, "Voltage"),
           let milliamps = IORegistry.int(battery, "InstantAmperage") ?? IORegistry.int(battery, "Amperage") {
            let signed = Double(Int32(truncatingIfNeeded: milliamps))
            stats.watts = Double(millivolts) * signed / 1_000_000
        }
        return stats
    }
}
