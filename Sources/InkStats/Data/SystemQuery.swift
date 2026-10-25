import InkKit
import Foundation
import IOKit

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case 4: return Int(Int32(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum IORegistry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Device-tree properties are often raw bytes; this accepts either form.
    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        switch property(entry, key) {
        case let s as String: return s
        case let d as Data: return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
        default: return nil
        }
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        switch property(entry, key) {
        case let n as NSNumber: return n.intValue
        case let d as Data where d.count >= 4: return Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        default: return nil
        }
    }

    static func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            body(service)
            IOObjectRelease(service)
        }
    }

    static func firstService(_ className: String) -> io_object_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(className))
        return service == 0 ? nil : service
    }
}
