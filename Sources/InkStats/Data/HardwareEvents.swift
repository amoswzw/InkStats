import InkKit
import AppKit
import DiskArbitration
import IOKit.ps
import SystemConfiguration

enum HardwareEvent {
    case disks, power, network, wake
}

/// Listens for hardware and network changes so readings refresh at once instead of on the next tick.
final class HardwareEvents {
    var onEvent: ((HardwareEvent) -> Void)?

    private var diskSession: DASession?
    private var powerSource: CFRunLoopSource?
    private var networkStore: SCDynamicStore?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        if let session = DASessionCreate(kCFAllocatorDefault) {
            let callback: DADiskAppearedCallback = { _, context in
                guard let context else { return }
                Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().onEvent?(.disks)
            }
            DARegisterDiskAppearedCallback(session, nil, callback, context)
            DARegisterDiskDisappearedCallback(session, nil, callback, context)
            DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            diskSession = session
        }

        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<HardwareEvents>.fromOpaque(context).takeUnretainedValue().onEvent?(.power)
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSource = source
        }

        var storeContext = SCDynamicStoreContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
        if let store = SCDynamicStoreCreate(nil, "InkStats.events" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<HardwareEvents>.fromOpaque(info).takeUnretainedValue().onEvent?(.network)
        }, &storeContext) {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
            let patterns = ["State:/Network/Interface/.*/Link"] as CFArray
            SCDynamicStoreSetNotificationKeys(store, keys, patterns)
            if let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            networkStore = store
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.onEvent?(.wake) }
    }
}
