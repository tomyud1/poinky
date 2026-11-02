import AppKit

// Writing to a pipe whose process already exited would otherwise kill the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
