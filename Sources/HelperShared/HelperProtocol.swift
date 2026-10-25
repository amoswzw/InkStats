import Foundation
import Security

public enum HelperIdentity {
    /// launchd Mach service the helper listens on, and the plist that registers it.
    public static let machService = "dev.inkstats.helper"
    public static let plistName = "dev.inkstats.helper.plist"
    public static let appIdentifier = "dev.inkstats.InkStats"
    public static let helperIdentifier = "dev.inkstats.helper"
    /// Bumped whenever the protocol changes, so the app can tell an outdated helper apart.
    public static let version = "1"

    /// The team ID this process was signed with, or nil for unsigned and ad-hoc builds.
    public static func signingTeam() -> String? { ownTeam }

    // A process's signature can't change while it runs, and the app asks on every sample;
    // reading it each time is a Security call macOS flags on the main thread.
    private static let ownTeam: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Accept only code that Apple's chain says was signed by `team` with `identifier`.
    public static func requirement(identifier: String, team: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// Everything the root helper can do. Each method does one fixed thing; nothing takes a
/// command, path or program name from the caller.
@objc public protocol InkStatsHelperProtocol {
    func version(reply: @escaping (String) -> Void)

    /// Latest powermetrics sample in watts: "cpu", "gpu", "ane", "package". Empty until the first sample.
    func power(reply: @escaping ([String: Double]) -> Void)

    /// Every process, including other users' and root's, as JSON-encoded `[ProcessRecord]`.
    func processes(reply: @escaping (Data) -> Void)

    /// Replies with nil on success, or an error message.
    func setLowPowerMode(_ enabled: Bool, reply: @escaping (String?) -> Void)
    func setWiFiPower(_ on: Bool, reply: @escaping (String?) -> Void)

    /// Pins a fan to `rpm` (clamped to the fan's own limits); `rpm <= 0` returns it to automatic.
    func setFan(_ index: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func resetFans(reply: @escaping (String?) -> Void)
}

public struct ProcessRecord: Codable {
    public let pid: Int32
    public let name: String
    public let cpu: Double
    public let memory: Double

    public init(pid: Int32, name: String, cpu: Double, memory: Double) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

/// CPU and memory per process from `proc_pid_rusage`. As a normal user only your own
/// processes are readable; as root, all of them.
public final class ProcessSampler {
    private var previous: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var names: [pid_t: String] = [:]
    private let nanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    public func sample() -> [ProcessRecord] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let now = mach_absolute_time()
        let elapsed = previousTime == 0 ? 0 : Double(now - previousTime) * nanosPerTick

        var current: [pid_t: UInt64] = [:]
        var result: [ProcessRecord] = []
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let cpuTime = usage.ri_user_time + usage.ri_system_time
            current[pid] = cpuTime
            var cpu = 0.0
            if elapsed > 0, let before = previous[pid], cpuTime >= before {
                cpu = Double(cpuTime - before) * nanosPerTick / elapsed * 100
            }
            result.append(ProcessRecord(pid: pid, name: name(of: pid), cpu: cpu, memory: Double(usage.ri_phys_footprint)))
        }
        previous = current
        previousTime = now
        names = names.filter { current[$0.key] != nil }
        return result
    }

    private func name(of pid: pid_t) -> String {
        if let cached = names[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var resolved = "pid \(pid)"
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            resolved = URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
        } else if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            resolved = String(cString: buffer)
        }
        names[pid] = resolved
        return resolved
    }
}
