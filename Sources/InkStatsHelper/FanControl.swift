import CSystem
import Foundation

/// Manual fan speeds through the SMC, with a watchdog that hands control back to macOS
/// whenever the CPU gets hot.
final class FanControl {
    static let shared = FanControl()

    /// Above this, every manual fan returns to automatic control.
    private let safetyLimit = 95.0
    private let lock = NSLock()
    private var manual: [Int: Double] = [:]
    private var watchdog: DispatchSourceTimer?

    func setManual(_ index: Int, rpm: Double) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var count = 0.0
        guard is_smc_read("FNum", &count), index >= 0, index < Int(count) else { return "Fan \(index + 1) doesn't exist." }
        var minimum = 0.0, maximum = 0.0
        guard is_smc_read("F\(index)Mn", &minimum), is_smc_read("F\(index)Mx", &maximum), maximum > minimum else {
            return "Couldn't read the speed range of fan \(index + 1)."
        }
        let target = min(max(rpm, minimum), maximum)

        // Some Apple silicon generations need test mode before fans accept manual control.
        unlockIfNeeded()
        guard let modeKey = modeKey(index) else { return "This Mac doesn't expose fan \(index + 1) for manual control." }
        var switched = false
        for _ in 0..<10 where !switched {
            switched = writeByte(modeKey, 1)
            if !switched { usleep(100_000) }
        }
        guard switched else { return "The SMC refused manual mode for fan \(index + 1)." }
        guard writeFloat("F\(index)Tg", Float(target)) else {
            _ = writeByte(modeKey, 0)
            return "The SMC refused the target speed for fan \(index + 1)."
        }
        manual[index] = target
        startWatchdog()
        return nil
    }

    func setAutomatic(_ index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let modeKey = modeKey(index), writeByte(modeKey, 0) else { return "Couldn't return fan \(index + 1) to automatic." }
        manual[index] = nil
        if manual.isEmpty { relockAndStop() }
        return nil
    }

    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        var count = 0.0
        if is_smc_read("FNum", &count) {
            for index in 0..<Int(count) {
                if let key = modeKey(index) { _ = writeByte(key, 0) }
            }
        }
        manual.removeAll()
        relockAndStop()
    }

    // MARK: Private (callers hold `lock`)

    private func modeKey(_ index: Int) -> String? {
        var type = [CChar](repeating: 0, count: 5)
        var size: Int32 = 0
        for key in ["F\(index)Md", "F\(index)md"] where is_smc_key_info(key, &type, &size) { return key }
        return nil
    }

    private func unlockIfNeeded() {
        var type = [CChar](repeating: 0, count: 5)
        var size: Int32 = 0
        if is_smc_key_info("Ftst", &type, &size) { _ = writeByte("Ftst", 1) }
    }

    private func relockAndStop() {
        var type = [CChar](repeating: 0, count: 5)
        var size: Int32 = 0
        if is_smc_key_info("Ftst", &type, &size) { _ = writeByte("Ftst", 0) }
        watchdog?.cancel()
        watchdog = nil
    }

    private func writeByte(_ key: String, _ value: UInt8) -> Bool {
        var bytes = [value]
        return is_smc_write(key, &bytes, 1)
    }

    private func writeFloat(_ key: String, _ value: Float) -> Bool {
        var bytes = withUnsafeBytes(of: value.bitPattern.littleEndian) { Array($0) }
        return is_smc_write(key, &bytes, 4)
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkTemperature() }
        timer.resume()
        watchdog = timer
    }

    private func checkTemperature() {
        var readings = [ISTemperature](repeating: ISTemperature(), count: 192)
        let count = Int(is_hid_temperatures(&readings, Int32(readings.count)))
        let hottest = readings.prefix(count).map(\.celsius).filter { $0 > -20 && $0 < 150 }.max() ?? 0
        if hottest >= safetyLimit {
            log.warning("CPU reached \(hottest, privacy: .public) °C; returning fans to automatic")
            resetAll()
        }
    }
}
