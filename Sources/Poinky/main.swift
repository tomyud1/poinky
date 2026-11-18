import AppKit

// A helper's Claude Code, in a process group of its own (HelperExec.swift): no app at all.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--helper-exec" {
    HelperExec.run(Array(CommandLine.arguments.dropFirst(2)))
}

// Writing to a pipe whose process already exited would otherwise kill the app.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    withExtendedLifetime(delegate) { app.run() }
}
