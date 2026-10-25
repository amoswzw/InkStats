import CoreWLAN
import Foundation
import HelperShared

final class HelperService: NSObject, NSXPCListenerDelegate, InkStatsHelperProtocol {
    private let queue = DispatchQueue(label: "dev.inkstats.helper.service")
    private var connections = 0
    private var retained: [AnyObject] = []
    private let powerMetrics = PowerMetrics()
    private let processSampler = ProcessSampler()

    func retain(_ object: AnyObject) { retained.append(object) }

    // The code-signing requirement set on the listener has already been enforced by the
    // time this is called; connections from other code never reach here.
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: InkStatsHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        queue.sync { connections += 1 }
        connection.resume()
        return true
    }

    /// When the last app disconnects (quit or crash), nothing is watching the fans anymore.
    private func connectionEnded() {
        queue.sync {
            connections -= 1
            if connections <= 0 {
                connections = 0
                FanControl.shared.resetAll()
                powerMetrics.stop()
                scheduleIdleExit()
            }
        }
    }

    /// Exit when no app has been connected for a while. launchd starts the helper again on
    /// the next connection, which also picks up a newer helper binary after an update.
    private func scheduleIdleExit() {
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.connections == 0 else { return }
            log.info("No clients for 30 s; exiting")
            exit(0)
        }
    }

    func version(reply: @escaping (String) -> Void) {
        reply(HelperIdentity.version)
    }

    func power(reply: @escaping ([String: Double]) -> Void) {
        reply(powerMetrics.latest())
    }

    func processes(reply: @escaping (Data) -> Void) {
        let records = queue.sync { processSampler.sample() }
        reply((try? JSONEncoder().encode(records)) ?? Data())
    }

    func setLowPowerMode(_ enabled: Bool, reply: @escaping (String?) -> Void) {
        reply(run("/usr/bin/pmset", ["-a", "lowpowermode", enabled ? "1" : "0"]))
    }

    func setWiFiPower(_ on: Bool, reply: @escaping (String?) -> Void) {
        guard let interface = CWWiFiClient.shared().interface() else { reply("No Wi-Fi interface found."); return }
        do {
            try interface.setPower(on)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func setFan(_ index: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        reply(rpm <= 0 ? FanControl.shared.setAutomatic(index) : FanControl.shared.setManual(index, rpm: rpm))
    }

    func resetFans(reply: @escaping (String?) -> Void) {
        FanControl.shared.resetAll()
        reply(nil)
    }

    /// Runs one of the fixed system tools above with fixed arguments; never caller input.
    private func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return message.isEmpty ? "\(tool) exited with status \(process.terminationStatus)" : message
        }
        return nil
    }
}
