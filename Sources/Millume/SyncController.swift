import AppKit
import Combine

/// Mirrors the built-in display's brightness (+ offset) onto external monitors: react to
/// change notifications (or poll fast while brightness is changing), fade smoothly,
/// and hold the last good value while the lid is closed.
final class SyncController: ObservableObject {
    static let minExternal = 5
    static let offsetRange = -50 ... 50

    private static let slowPoll: TimeInterval = 1.0
    private static let fastPoll: TimeInterval = 0.1
    private static let fastPollDuration: TimeInterval = 3
    /// How far back to look for a trustworthy brightness when the lid closes, to skip the
    /// dip the panel reports while it powers off.
    private static let lidLookback: TimeInterval = 2
    /// A sudden drop to ~0 is held this long before being applied, in case the lid is closing.
    private static let dropHold: TimeInterval = 1.5
    private static let fadeInterval: TimeInterval = 0.05

    private enum Keys {
        static let enabled = "enabled"
        static let offset = "offset"
        static let lastExternal = "lastExternal"
    }

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            lastMac = nil // re-apply on the next poll
        }
    }

    @Published var offset: Int {
        didSet {
            UserDefaults.standard.set(offset, forKey: Keys.offset)
            if enabled, !lidClosed, let lastMac { apply(mac: lastMac) }
        }
    }

    @Published private(set) var macBrightness: Int?
    @Published private(set) var externalBrightness: Int?
    @Published private(set) var lidClosed = Lid.isClosed
    @Published private(set) var displayCount = 0

    private let writer = DDCWriter()
    private var pollTimer: Timer?
    private var lastMac: Double?
    private var lastChange = Date.distantPast
    private var history: [(time: Date, value: Double)] = []
    private var pendingDrop: Date?
    private var notificationsArrived = false

    private var fadeTimer: Timer?
    private var fadeCurrent: Double?
    private var fadeTarget: Double = 0
    private var lastSent: Int?
    private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.enabled: true, Keys.offset: 0])
        enabled = defaults.bool(forKey: Keys.enabled)
        offset = defaults.integer(forKey: Keys.offset)
        // Our last write is the best guess of the monitor's current brightness, so fades start from it.
        if let last = defaults.object(forKey: Keys.lastExternal) as? Int {
            fadeCurrent = Double(last)
            externalBrightness = last
        }

        rediscover()
        observeSystem()
        subscribe()
        tick()
    }

    /// Sets the external brightness directly (used while the lid is closed or sync is off).
    func setManual(_ value: Int) {
        fade(to: min(max(value, 0), 100))
    }

    // MARK: - Polling

    private func tick() {
        let closed = Lid.isClosed
        if closed != lidClosed {
            closed ? lidDidClose() : lidDidOpen()
        }
        if !closed { readBuiltin() }
        scheduleNextTick()
    }

    private func subscribe() {
        BuiltinDisplay.observeChanges { [weak self] _ in
            guard let self else { return }
            notificationsArrived = true
            if !lidClosed { readBuiltin() }
        }
    }

    private func scheduleNextTick() {
        // Once notifications are proven to arrive, they replace fast polling; the slow poll
        // remains as a fallback and for lid detection.
        let changing = Date().timeIntervalSince(lastChange) < Self.fastPollDuration && !notificationsArrived
        let fast = changing || pendingDrop != nil
        let timer = Timer(timeInterval: fast ? Self.fastPoll : Self.slowPoll, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func readBuiltin() {
        guard let mac = BuiltinDisplay.brightness() else { return }
        let now = Date()
        macBrightness = Int((mac * 100).rounded())
        history.append((now, mac))
        history.removeAll { now.timeIntervalSince($0.time) > 10 }
        guard enabled else { return }

        if let last = lastMac, abs(mac - last) < 0.002 {
            if let since = pendingDrop, now.timeIntervalSince(since) >= Self.dropHold {
                pendingDrop = nil
                apply(mac: mac)
            }
            return
        }

        lastChange = now
        // The panel can report a plunge to ~0 just before the lid closed state is visible.
        if mac < 0.02, let last = lastMac, last - mac > 0.15 {
            pendingDrop = now
            lastMac = mac
            return
        }
        pendingDrop = nil
        lastMac = mac
        apply(mac: mac)
    }

    private func lidDidClose() {
        lidClosed = true
        pendingDrop = nil
        let cutoff = Date().addingTimeInterval(-Self.lidLookback)
        if enabled, let before = history.last(where: { $0.time <= cutoff }) {
            apply(mac: before.value)
        }
        history.removeAll()
        lastMac = nil
    }

    private func lidDidOpen() {
        lidClosed = false
        lastMac = nil
        lastChange = Date()
        // The built-in display was offline, so its old subscription may be dead.
        BuiltinDisplay.stopObserving()
        subscribe()
    }

    private func apply(mac: Double) {
        let target = Int((mac * 100).rounded()) + offset
        fade(to: min(max(target, Self.minExternal), 100))
    }

    // MARK: - Fading

    private func fade(to target: Int) {
        fadeTarget = Double(target)
        UserDefaults.standard.set(target, forKey: Keys.lastExternal)
        guard fadeCurrent != nil else {
            fadeCurrent = fadeTarget
            send()
            return
        }
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: Self.fadeInterval, repeats: true) { [weak self] _ in self?.fadeStep() }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func fadeStep() {
        guard var current = fadeCurrent else { return }
        let diff = fadeTarget - current
        if abs(diff) <= 0.5 {
            current = fadeTarget
            fadeTimer?.invalidate()
            fadeTimer = nil
        } else {
            // Ease out, with a minimum step so the tail doesn't crawl.
            current += (diff < 0 ? -1 : 1) * max(abs(diff) * 0.18, 0.4)
        }
        fadeCurrent = current
        send()
    }

    private func send(force: Bool = false) {
        guard let current = fadeCurrent else { return }
        let value = Int(current.rounded())
        externalBrightness = value
        guard force || value != lastSent else { return }
        lastSent = value
        writer.write(value)
    }

    // MARK: - System events

    private func rediscover() {
        writer.rediscover { [weak self] count in
            self?.displayCount = count
            self?.send(force: true) // monitors may have reset after reconnecting or waking
            self?.subscribe()
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.rediscoverSoon()
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rediscoverSoon()
        })
    }

    private func rediscoverSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.rediscover() }
    }
}
