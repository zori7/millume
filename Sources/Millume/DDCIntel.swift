#if arch(x86_64)
import Foundation
import IOKit
import IOKit.graphics
import IOKit.i2c

/// DDC/CI through the framebuffer I2C interface used on Intel Macs.
final class IntelDDC: DDCDisplay {
    private let framebuffer: io_service_t

    private init(framebuffer: io_service_t) {
        IOObjectRetain(framebuffer)
        self.framebuffer = framebuffer
    }

    deinit {
        IOObjectRelease(framebuffer)
    }

    static func discover() -> [DDCDisplay] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var displays: [DDCDisplay] = []
        while case let framebuffer = IOIteratorNext(iterator), framebuffer != 0 {
            defer { IOObjectRelease(framebuffer) }
            var busCount: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS, busCount > 0 else { continue }
            displays.append(IntelDDC(framebuffer: framebuffer))
        }
        return displays
    }

    func write(vcp: UInt8, value: UInt16) -> Bool {
        var busCount: IOItemCount = 0
        guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == KERN_SUCCESS else { return false }

        // Source address, length byte, "set VCP" opcode, feature, value (big endian), checksum.
        var data: [UInt8] = [0x51, 0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        data[6] = data[0 ..< 6].reduce(UInt8(0x6E), ^)

        for bus in 0 ..< busCount {
            var interface = io_service_t()
            guard IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(interface) }

            var connect: IOI2CConnectRef?
            guard IOI2CInterfaceOpen(interface, 0, &connect) == KERN_SUCCESS, let connect else { continue }
            defer { IOI2CInterfaceClose(connect, 0) }

            let sent = data.withUnsafeMutableBytes { buffer -> Bool in
                var request = IOI2CRequest()
                request.sendAddress = 0x6E
                request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.sendBuffer = vm_address_t(bitPattern: buffer.baseAddress)
                request.sendBytes = UInt32(buffer.count)
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
                return IOI2CSendRequest(connect, 0, &request) == KERN_SUCCESS && request.result == KERN_SUCCESS
            }
            if sent { return true }
        }
        return false
    }
}
#endif
