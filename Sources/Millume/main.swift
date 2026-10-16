import Foundation

// `Millume --probe` prints what the app can see without changing any brightness.
if CommandLine.arguments.contains("--probe") {
    let brightness = BuiltinDisplay.brightness().map { "\(Int(($0 * 100).rounded()))%" } ?? "unavailable"
    print("Built-in display: \(BuiltinDisplay.id.map(String.init) ?? "inactive"), brightness \(brightness)")
    print("Lid closed: \(Lid.isClosed)")
    print("DDC displays: \(DDC.discover().count)")
    exit(0)
}

// `Millume --listen` prints built-in brightness change notifications until interrupted.
if CommandLine.arguments.contains("--listen") {
    setvbuf(stdout, nil, _IOLBF, 0)
    let registered = BuiltinDisplay.observeChanges { value in
        let reported = value.map { String(format: "%.3f", $0) } ?? "none"
        let read = BuiltinDisplay.brightness().map { String(format: "%.3f", $0) } ?? "unavailable"
        print("\(Date()) notification value=\(reported) read=\(read)")
    }
    print(registered ? "Subscribed; change the MacBook brightness (Ctrl-C to stop)" : "Subscription failed")
    guard registered else { exit(1) }
    RunLoop.main.run()
}

MillumeApp.main()
