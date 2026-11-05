// Renders moments of an explainer video into one PNG sheet with macOS's own web engine (WebKit, the
// same one Poinky plays videos with), so checking frames needs no Chrome or Node.
// Build: swiftc -O -parse-as-library -o render render.swift
// Usage: render <video dir> <out.png> <t1,t2,...> [scenes=s2] [file_s2=scenes/s2.v2.js] [cols=3] [w=520]
// Prints {"errors":[...], "lint":[...]} like render.mjs: scene exceptions / unknown cues, and layout problems.
import AppKit
import WebKit

@main
struct Render {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: render <video dir> <out.png> <times> [key=value…]\n".data(using: .utf8)!)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let r = Renderer(args: args)
        MainActor.assumeIsolated { r.start() }
        app.run()
    }
}

final class Renderer: NSObject, WKNavigationDelegate, @unchecked Sendable {
    let videoDir: URL, outPng: String, times: String
    var extra: [(String, String)] = []
    var web: WKWebView?
    var window: NSWindow?
    var tries = 0

    init(args: [String]) {
        videoDir = URL(fileURLWithPath: args[0]).standardizedFileURL
        outPng = args[1]
        times = args[2]
        for a in args.dropFirst(3) {
            let kv = a.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { extra.append((kv[0], kv[1])) }
        }
    }

    @MainActor func start() {
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        // The tool is built next to the videos; the page lives with the pipeline (EXPLAINER_HOME).
        let home = ProcessInfo.processInfo.environment["EXPLAINER_HOME"].map { URL(fileURLWithPath: $0) } ?? here
        let page = home.appendingPathComponent("player.html")
        guard FileManager.default.fileExists(atPath: page.path) else { finish(2, errors: ["player.html not found in \(home.path)"]); return }
        let cols = Int(value("cols") ?? "3") ?? 3, w = Int(value("w") ?? "520") ?? 520

        var q = URLComponents()
        q.queryItems = [URLQueryItem(name: "grid", value: "1"), URLQueryItem(name: "dir", value: "file://" + videoDir.path),
                        URLQueryItem(name: "times", value: times), URLQueryItem(name: "cols", value: String(cols)), URLQueryItem(name: "w", value: String(w))]
            + extra.filter { $0.0 != "cols" && $0.0 != "w" }.map { URLQueryItem(name: $0.0, value: $0.1) }
        let qs = q.percentEncodedQuery ?? ""

        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")   // the page reads the manifest with XHR
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        // The query, in case a file URL's query doesn't reach the page.
        cfg.userContentController.addUserScript(WKUserScript(source: "window.__GRID_QS = \(Self.js(qs));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let frame = NSRect(x: -20000, y: -20000, width: cols * w, height: 1200)
        let wv = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: cfg)
        wv.navigationDelegate = self
        let win = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        win.orderFrontRegardless()   // off screen, but "in a window" so WebKit doesn't throttle it
        web = wv
        window = win
        wv.loadFileURL(URL(string: page.absoluteString + "?" + qs) ?? page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.finish(1, errors: ["the page did not finish rendering"]) }
    }

    func value(_ k: String) -> String? { extra.first { $0.0 == k }?.1 }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { poll() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(1, errors: ["load failed: \(error.localizedDescription)"]) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(1, errors: ["load failed: \(error.localizedDescription)"]) }

    func poll() {
        web?.evaluateJavaScript("window.renderDone ? JSON.stringify({d: window.renderDone, png: document.getElementById('sheet').toDataURL('image/png')}) : null") { [weak self] r, _ in
            guard let self else { return }
            guard let s = r as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let done = o["d"] as? [String: Any], let png = o["png"] as? String else {
                self.tries += 1
                if self.tries > 400 { self.finish(1, errors: ["the page did not finish rendering"]); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.poll() }
                return
            }
            if let comma = png.firstIndex(of: ","), let bytes = Data(base64Encoded: String(png[png.index(after: comma)...])) {
                try? bytes.write(to: URL(fileURLWithPath: self.outPng))
            }
            self.finish(0, errors: done["errors"] as? [String] ?? [], lint: done["lint"] as? [String] ?? [])
        }
    }

    func finish(_ code: Int32, errors: [String], lint: [String] = []) {
        let out = (try? JSONSerialization.data(withJSONObject: ["errors": errors, "lint": lint])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        print(out)
        fflush(stdout)
        exit(code)
    }

    static func js(_ s: String) -> String {
        let d = try? JSONSerialization.data(withJSONObject: [s])
        return d.flatMap { String(data: $0, encoding: .utf8) }.map { "\($0)[0]" } ?? "\"\""
    }
}
