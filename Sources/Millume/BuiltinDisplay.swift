import CoreGraphics
import Foundation
import IOKit

/// The MacBook's built-in panel, whose brightness macOS drives from the ambient light sensor.
enum BuiltinDisplay {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID, CFNotificationCallback) -> Int32
    private typealias UnregisterFn = @convention(c) (CGDirectDisplayID, CGDirectDisplayID) -> Int32

    // DisplayServices is a private framework, so resolve it at runtime instead of linking it.
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetBrightnessFn? = symbol("DisplayServicesGetBrightness")
    private static let register: RegisterFn? = symbol("DisplayServicesRegisterForBrightnessChangeNotifications")
    private static let unregister: UnregisterFn? = symbol("DisplayServicesUnregisterForBrightnessChangeNotifications")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static var observedID: CGDirectDisplayID?
    private static var changeHandler: ((Double?) -> Void)?

    /// The built-in display, if it is currently active (it is not while the lid is closed).
    static var id: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Brightness in 0...1 as shown by the system slider, or nil when it can't be trusted
    /// (display inactive or asleep, or the API is unavailable).
    static func brightness() -> Double? {
        guard let getBrightness, let id, CGDisplayIsAsleep(id) == 0 else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1))
    }

    /// Subscribes to brightness change notifications for the built-in display, re-subscribing if
    /// its ID changed. The handler runs on the main queue with the reported value (if any).
    /// Returns false when subscribing isn't possible right now.
    @discardableResult
    static func observeChanges(_ handler: @escaping (Double?) -> Void) -> Bool {
        changeHandler = handler
        guard let register, let id else { return false }
        if observedID == id { return true }
        stopObserving()

        let result = register(id, id) { _, _, _, _, userInfo in
            let value = ((userInfo as NSDictionary?)?["value"] as? NSNumber)?.doubleValue
            DispatchQueue.main.async { BuiltinDisplay.changeHandler?(value) }
        }
        guard result == 0 else { return false }
        observedID = id
        return true
    }

    static func stopObserving() {
        if let observedID, let unregister { _ = unregister(observedID, observedID) }
        observedID = nil
    }
}

enum Lid {
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    static var isClosed: Bool {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
              .takeRetainedValue()
        else { return false }
        return (value as? Bool) ?? false
    }
}
