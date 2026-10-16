import Foundation

protocol DDCDisplay: AnyObject {
    /// Sets a VCP feature (e.g. brightness 0x10). Returns false if the monitor didn't accept the write.
    func write(vcp: UInt8, value: UInt16) -> Bool
}

enum DDC {
    static let brightnessVCP: UInt8 = 0x10

    /// External monitors reachable over DDC/CI.
    static func discover() -> [DDCDisplay] {
        #if arch(arm64)
        return AppleSiliconDDC.discover()
        #else
        return IntelDDC.discover()
        #endif
    }
}

/// Serializes DDC writes on a background queue, dropping intermediate values when the
/// monitor is slower than the fade (only the latest requested brightness is sent), and
/// never writing more often than `minInterval`.
final class DDCWriter {
    private static let minInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "millume.ddc", qos: .userInitiated)
    private var lastWrite = Date.distantPast // only touched on `queue`
    private let lock = NSLock()
    private var pending: Int?
    private var draining = false
    private var displays: [DDCDisplay] = [] // only touched on `queue`

    func rediscover(completion: @escaping (Int) -> Void) {
        queue.async {
            self.displays = DDC.discover()
            let count = self.displays.count
            DispatchQueue.main.async { completion(count) }
        }
    }

    func write(_ value: Int) {
        lock.lock()
        pending = value
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            // Wait out the gap first so values arriving meanwhile coalesce into one write.
            let wait = Self.minInterval - Date().timeIntervalSince(lastWrite)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }

            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            for display in displays {
                _ = display.write(vcp: DDC.brightnessVCP, value: UInt16(clamping: value))
            }
            lastWrite = Date()
        }
    }
}
