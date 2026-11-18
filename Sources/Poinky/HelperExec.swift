import Darwin
import Foundation

/// `Poinky --helper-exec <program> <args…>`: how a helper's Claude Code is started. The program runs in a
/// process group of its own, so what it starts (a long `npm test`, a dev server) can be ended with it: on Stop
/// or quit (SIGTERM to this wrapper), when the program exits, and when Poinky itself is gone (crashed or
/// force-quit: checked twice a second), the whole group gets SIGTERM, then SIGKILL 3 s later. Stdin, stdout
/// and the exit status pass straight through. (The video pipeline does the same from Python.)
enum HelperExec {
    nonisolated(unsafe) private static var stopRequested: sig_atomic_t = 0

    static func run(_ args: [String]) -> Never {
        guard let exe = args.first else { exit(64) }
        let parent = getppid()
        for s in [SIGTERM, SIGINT, SIGHUP] { signal(s) { _ in HelperExec.stopRequested = 1 } }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setpgroup(&attr, 0)   // a new group, led by the program
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe, nil, &attr, argv, environ)
        posix_spawnattr_destroy(&attr)
        guard rc == 0 else {
            fputs("Poinky: couldn't start \(exe): \(String(cString: strerror(rc)))\n", stderr)
            exit(127)
        }

        var status: Int32 = 0
        var endingSince: Date?
        func endGroup() {
            guard endingSince == nil else { return }
            endingSince = Date()
            killpg(pid, SIGTERM)
        }
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { break }
            if stopRequested != 0 || getppid() != parent { endGroup() }
            if let t = endingSince, Date().timeIntervalSince(t) > 3 { killpg(pid, SIGKILL) }
            usleep(200_000)
        }
        // The program is done: anything it left running in its group goes too.
        if killpg(pid, 0) == 0 {
            killpg(pid, SIGTERM)
            for _ in 0..<15 where killpg(pid, 0) == 0 { usleep(200_000) }
            killpg(pid, SIGKILL)
        }
        let sig = status & 0x7f
        exit(sig == 0 ? (status >> 8) & 0xff : 128 + sig)
    }
}
