#if arch(arm64)
import Foundation
import IOKit

/// DDC/CI over the private IOAVService I2C API used on Apple Silicon.
final class AppleSiliconDDC: DDCDisplay {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create: CreateFn? = symbol("IOAVServiceCreateWithService")
    private static let writeI2C: WriteI2CFn? = symbol("IOAVServiceWriteI2C")

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(iokit, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let service: CFTypeRef

    private init(service: CFTypeRef) {
        self.service = service
    }

    static func discover() -> [DDCDisplay] {
        guard let create else { return [] }
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var displays: [DDCDisplay] = []
        while case let proxy = IOIteratorNext(iterator), proxy != 0 {
            defer { IOObjectRelease(proxy) }
            let location = IORegistryEntryCreateCFProperty(proxy, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External", let service = create(kCFAllocatorDefault, proxy)?.takeRetainedValue() else { continue }
            displays.append(AppleSiliconDDC(service: service))
        }
        return displays
    }

    func write(vcp: UInt8, value: UInt16) -> Bool {
        guard let writeI2C = Self.writeI2C else { return false }
        // Length byte, "set VCP" opcode, feature, value (big endian), checksum.
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0 ..< 5].reduce(UInt8(0x6E ^ 0x51), ^)

        for _ in 0 ..< 3 {
            let result = packet.withUnsafeMutableBytes {
                writeI2C(service, Self.chipAddress, Self.dataAddress, $0.baseAddress!, UInt32($0.count))
            }
            if result == kIOReturnSuccess { return true }
            usleep(10000)
        }
        return false
    }
}
#endif
