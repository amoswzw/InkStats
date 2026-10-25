import Foundation

/// Streams Apple's `powermetrics` (root only) for per-component power. It starts on the
/// first request and stops after a quiet minute, so it costs nothing when unused.
final class PowerMetrics {
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var values: [String: Double] = [:]
    private var lastRequest = Date.distantPast
    private var idleTimer: DispatchSourceTimer?
    private var loggedLayout = false

    func latest() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        lastRequest = Date()
        if process == nil { start() }
        return values
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
        idleTimer?.cancel()
        idleTimer = nil
        values = [:]
    }

    /// Caller holds `lock`.
    private func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = ["--samplers", "cpu_power,gpu_power,ane_power", "-i", "1000", "-f", "plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.process === process { self.process = nil }
            self.lock.unlock()
        }
        do {
            try process.run()
            self.process = process
        } catch {
            log.error("Couldn't start powermetrics: \(error.localizedDescription, privacy: .public)")
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idle = Date().timeIntervalSince(self.lastRequest) > 60
            self.lock.unlock()
            if idle { self.stop() }
        }
        timer.resume()
        idleTimer = timer
    }

    /// Samples arrive as plist documents separated by NUL bytes.
    private func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0) {
            let document = buffer[buffer.startIndex..<end]
            buffer = Data(buffer[buffer.index(after: end)...])
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(document), format: nil) as? [String: Any] else { continue }
            if !loggedLayout {
                loggedLayout = true
                // Logged once per start so format changes in new macOS releases can be diagnosed.
                let fields = Self.powerFields(plist).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
                log.info("powermetrics fields: \(fields, privacy: .public)")
            }
            var sample: [String: Double] = [:]
            // Values are milliwatts. Key names have moved between macOS releases, so search the tree.
            for (key, name) in [("cpu_power", "cpu"), ("gpu_power", "gpu"), ("ane_power", "ane"), ("combined_power", "package")] {
                if let mw = Self.find(key, in: plist) { sample[name] = mw / 1000 }
            }
            if !sample.isEmpty { values = sample }
        }
    }

    private static func powerFields(_ value: Any, path: String = "") -> [(String, Double)] {
        if let dict = value as? [String: Any] {
            return dict.flatMap { key, child -> [(String, Double)] in
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let n = child as? NSNumber, key.contains("power") || key.contains("energy") { return [(childPath, n.doubleValue)] }
                return powerFields(child, path: childPath)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { powerFields($1, path: "\(path)[\($0)]") }
        }
        return []
    }

    private static func find(_ key: String, in value: Any) -> Double? {
        if let dict = value as? [String: Any] {
            if let number = dict[key] as? NSNumber { return number.doubleValue }
            for child in dict.values { if let found = find(key, in: child) { return found } }
        } else if let array = value as? [Any] {
            for child in array { if let found = find(key, in: child) { return found } }
        }
        return nil
    }
}
