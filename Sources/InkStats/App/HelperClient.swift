import Foundation
import HelperShared
import ServiceManagement

/// Installs, approves and talks to the privileged helper.
final class HelperClient {
    static let shared = HelperClient()

    enum State: Equatable {
        case notInstalled, needsApproval, running
        case unavailable(String)
    }

    private let service = SMAppService.daemon(plistName: HelperIdentity.plistName)
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var power: [String: Double] = [:]
    private var processRecords: [ProcessRecord]?

    var state: State {
        guard HelperIdentity.signingTeam() != nil else {
            return .unavailable("This build isn't signed with a Developer ID, so the helper can't verify it. Build with scripts/build-app.sh and a Developer ID certificate.")
        }
        switch service.status {
        case .enabled: return .running
        case .requiresApproval: return .needsApproval
        case .notRegistered, .notFound: return .notInstalled
        @unknown default: return .notInstalled
        }
    }

    /// Registering succeeds but throws "Operation not permitted" when macOS still needs the
    /// user's approval, so that case opens the approval page instead of reporting a failure.
    func install() throws {
        do {
            try service.register()
        } catch {
            guard service.status == .requiresApproval else { throw error }
            openApprovalSettings()
        }
    }

    func uninstall() throws {
        lock.lock()
        connection?.invalidate()
        connection = nil
        lock.unlock()
        try service.unregister()
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Cached readings, merged into each snapshot

    func cachedPower() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        return power
    }

    func cachedProcesses() -> [ProcessRecord]? {
        lock.lock(); defer { lock.unlock() }
        return processRecords
    }

    /// Asks the helper for fresh readings; results land in the caches for the next tick.
    func refresh(wantPower: Bool, wantProcesses: Bool) {
        guard let helper = proxy() else {
            lock.lock()
            power = [:]
            processRecords = nil
            lock.unlock()
            return
        }
        if wantPower {
            helper.power { values in
                self.lock.lock(); self.power = values; self.lock.unlock()
            }
        }
        if wantProcesses {
            helper.processes { data in
                let records = try? JSONDecoder().decode([ProcessRecord].self, from: data)
                self.lock.lock(); self.processRecords = records; self.lock.unlock()
            }
        } else {
            lock.lock(); processRecords = nil; lock.unlock()
        }
    }

    // MARK: Commands

    func setLowPowerMode(_ on: Bool, done: @escaping (String?) -> Void) {
        call(done) { $0.setLowPowerMode(on, reply: $1) }
    }

    func setWiFiPower(_ on: Bool, done: @escaping (String?) -> Void) {
        call(done) { $0.setWiFiPower(on, reply: $1) }
    }

    func setFan(_ index: Int, rpm: Double, done: @escaping (String?) -> Void) {
        call(done) { $0.setFan(index, rpm: rpm, reply: $1) }
    }

    private func call(_ done: @escaping (String?) -> Void, _ body: (InkStatsHelperProtocol, @escaping (String?) -> Void) -> Void) {
        guard let helper = proxy(onError: { error in DispatchQueue.main.async { done(error) } }) else {
            done("The helper isn't running. Install it in Settings → Helper.")
            return
        }
        body(helper) { error in DispatchQueue.main.async { done(error) } }
    }

    private func proxy(onError: ((String) -> Void)? = nil) -> InkStatsHelperProtocol? {
        guard state == .running, let team = HelperIdentity.signingTeam() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: InkStatsHelperProtocol.self)
            // Verify the other side too: only a helper from the same team is trusted.
            c.setCodeSigningRequirement(HelperIdentity.requirement(identifier: HelperIdentity.helperIdentifier, team: team))
            c.invalidationHandler = { [weak self] in
                self?.lock.lock(); self?.connection = nil; self?.lock.unlock()
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in onError?(error.localizedDescription) } as? InkStatsHelperProtocol
    }
}
