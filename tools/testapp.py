"""Where test runs launch Poinky from: one fixed path for every checkout and worktree.

macOS asks "Poinky is requesting to bypass the system private window picker and directly access your screen" the
first time an app captures the screen with ScreenCaptureKit (no system picker) from an executable path it has no
approval date for: replayd keeps those dates per executable path (ScreenCaptureApprovals.plist), not per bundle id
or signature. Screen Recording permission itself (TCC) follows the bundle id and signing certificate, so a build in a
new worktree already has it, but its new path got that dialog on the owner's screen. Tests that capture the screen
therefore copy the build to ~/Library/Caches/Poinky/test-app/Poinky.app (once per build) and launch it from there:
one path, approved once, for every checkout.

`POINKY_APP` (an exact app to run, e.g. an older build to see a check fail) is used as it is.
`POINKY_TEST_APP_DIR` moves the fixed copy elsewhere.
"""
import atexit, fcntl, os, subprocess

LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def forget(app):
    """Takes the test copy out of macOS's list of apps again. It has the real app's id, and launching it
    registers it: left there, opening "Poinky" (Spotlight, a notification, a login item) could start the
    test copy instead of the user's own (it happened with a worktree build)."""
    subprocess.run([LSREGISTER, "-u", app], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)



def stable_app(built):
    if os.environ.get("POINKY_APP"):
        return os.environ["POINKY_APP"]
    if not os.path.isdir(built):
        return built
    home = os.environ.get("POINKY_TEST_APP_DIR") or os.path.expanduser("~/Library/Caches/Poinky/test-app")
    os.makedirs(home, exist_ok=True)
    dest = os.path.join(home, "Poinky.app")
    exe = lambda app: os.path.join(app, "Contents/MacOS/Poinky")

    def stamp(app):
        try:
            st = os.stat(exe(app))
            info = os.stat(os.path.join(app, "Contents/Info.plist"))
            return f"{st.st_size}:{int(st.st_mtime)}:{info.st_size}:{int(info.st_mtime)}:{os.path.realpath(app)}"
        except OSError:
            return ""

    with open(os.path.join(home, ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)   # two test runs copying at once
        mark = os.path.join(home, ".source")
        want = stamp(built)
        have = open(mark).read() if os.path.exists(mark) else ""
        if want != have or not os.path.exists(exe(dest)):
            subprocess.run(["rm", "-rf", dest], check=False)
            subprocess.run(["ditto", built, dest], check=True)
            open(mark, "w").write(want)
    atexit.register(forget, dest)
    return dest
