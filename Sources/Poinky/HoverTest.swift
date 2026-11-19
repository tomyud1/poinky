import AppKit

/// Developer check (`Poinky --hover-shot <dir>`): every control the overlay draws, through the real overlay in the
/// real app. It puts up a paper with drawn steps, a panel, a 3D model with notes, a photo, the Clear pill, a
/// helper with its card open and the bubble with Copy / ✕; then moves the cursor the app tracks (not your mouse)
/// onto each control in turn, and saves a picture around it (`<dir>/<n>-<name>.png`, what WebKit drew) plus
/// `<dir>/log.txt`: what lit up there (`SBX.hotName()`) and whether the app lets clicks through at that spot
/// (`Overlay.takesClicks`). Quits when done (~20 s). Run it under the screen lock (it shows on screen).
@MainActor
enum HoverTest {
    private static var overlay: Overlay?

    static func run(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        if CallController.screenLocked() {
            try? "SCREEN LOCKED".write(toFile: outDir + "/log.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        var lines: [String] = []
        func log(_ s: String) {
            lines.append(s)
            try? lines.joined(separator: "\n").write(toFile: outDir + "/log.txt", atomically: true, encoding: .utf8)
        }
        let o = Overlay()
        overlay = o
        let display = NSScreen.main ?? NSScreen.screens[0]
        o.show(on: display)
        o.setBuddy(true)
        o.setPhase("ready")
        var cursor = CGPoint(x: 300, y: display.frame.height - 160)
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { o.tick(cursor: cursor, level: 0); o.trackMouse() }
        }
        _ = ticker
        // A wide picture with numbers at its edges: a crop would cut them (the "95.84" the owner saw lose a digit).
        let photo = picture(width: 900, height: 340)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            o.evaluateForTest("""
            SB.lessonBegin({x:60,y:70,w:520,h:360,h0:300,lo:70,hi:640}, 'Fractions', false);
            SB.lessonStep({ops:[{op:'text',x:40,y:60,text:'Half of a pizza',size:30}]}, 1);
            SB.lessonStep({ops:[{op:'box',x:40,y:110,w:200,h:80}]}, 1);
            SB.apply({items:[{type:'panel',id:'p1',x:640,y:70,w:300,h:200,html:'<h1>Panel</h1><p>A card from the talker.</p>'},
                             {type:'scene3d',id:'m1',x:640,y:330,w:420,h:300,code:"kit.box({size:[2,1,1], name:'engine'}); kit.sphere({r:0.5, at:[1.6,0,0], name:'wheel'})"}]}, 1);
            """)
            o.helperSpawn(id: 1, name: "Mint", task: "Fix the failing test", note: 0, detail: "Fix the failing test in parser.py", folder: "~/code/app")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            o.run3d(id: "m1", code: "", note: "Spin the wheel")
            o.run3d(id: "m1", code: "", note: "Look inside")
            o.showPhoto(forId: nil, src: photo, caption: "Properties of water")
            o.setReading(true)
            o.setPhase("speaking")
            o.setClaudeCaption("Half is the same as two quarters.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            o.setPhase("ready")
            o.captionDone(copy: "2/4", keep: true)   // (text to copy that differs: the bubble stays)
        }
        // Where each control is (screen points), asked once everything has settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            let js = """
            (function(){
              const D = document, out = [], c = el => { if (!el) return null; const r = el.getBoundingClientRect(); return r.width ? [r.left + r.width/2, r.top + r.height/2] : null; };
              const add = (name, el, at) => { const p = at || c(el); if (p) out.push({name, x: p[0], y: p[1]}); else out.push({name, missing: true}); };
              const paper = D.querySelector('.card.lpaper');
              add('paper-save', paper && paper.querySelector('.save:not(.all)'));
              add('paper-close', paper && paper.querySelector('.bar .x'));
              const bar = paper && paper.querySelector('.bar').getBoundingClientRect(); add('paper-bar', null, bar && [bar.left + 24, bar.top + 19]);
              const st = paper && paper.querySelector('.lsvg > g[data-step="1"]'), sr = st && st.getBoundingClientRect(); add('past-step', null, sr && [sr.left + 30, sr.top + sr.height/2]);
              add('panel-close', D.querySelector('.card[data-id="p1"] .x'));
              add('model-close', D.querySelector('.card[data-id="m1"] .x'));
              add('model-note', D.querySelector('.card[data-id="m1"] .notes li'));
              const f = D.querySelector('.card[data-id="m1"] iframe'), fr = f && f.getBoundingClientRect(); add('model-part', null, fr && [fr.left + fr.width * 0.42, fr.top + fr.height * 0.52]);
              add('photo-close', D.querySelector('.card.photo .x'));
              add('photo-drag', D.querySelector('.card.photo .pcap'));
              add('clear-pill', D.getElementById('clearBtn'));
              add('bubble-copy', D.querySelector('#bubble .foot button.copy') || D.querySelector('#bubble .foot button'));
              add('bubble-close', D.querySelector('#bubble .foot button.x'));
              const h = SB.helperPos('1'); add('helper', null, h && [h.x + 6, h.y + 6]);
              return JSON.stringify(out);
            })()
            """
            o.evaluateForTest(js) { r in
                guard let s = r as? String, let d = s.data(using: .utf8),
                      var list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { log("no controls"); finish(); return }
                // The helper's buttons show only once its card is open: rest on the helper first, then Stop.
                list.append(["name": "helper-stop", "after": "helper"])
                step(list, 0)
            }
        }
        func step(_ list: [[String: Any]], _ i: Int) {
            guard i < list.count else { finish(); return }
            let c = list[i], name = c["name"] as? String ?? "?"
            if c["missing"] as? Bool == true { log("\(name): MISSING"); step(list, i + 1); return }
            let go: (CGPoint) -> Void = { p in
                cursor = p
                DispatchQueue.main.asyncAfter(deadline: .now() + (name == "helper" ? 1.4 : name == "model-part" ? 0.9 : 0.45)) {
                    o.evaluateForTest("SBX.hotName() + ' | ' + ((document.querySelector('.card[data-id=\"m1\"] iframe') && '') || '')") { r in
                        let hot = ((r as? String) ?? "").components(separatedBy: " | ").first ?? ""
                        log(String(format: "%@ at %.0f,%.0f: lit %@, takes clicks %@", name, p.x, p.y, hot.isEmpty ? "(nothing)" : hot, o.takesClicks(at: p) ? "yes" : "NO"))
                        shot(o, at: p, to: outDir + String(format: "/%02d-%@.png", i + 1, name)) { step(list, i + 1) }
                    }
                }
            }
            if c["after"] != nil {
                o.evaluateForTest("(function(){ const b = document.querySelector('.hl-chip .btns:not(.ask) button.stop'); if (!b) return ''; const r = b.getBoundingClientRect(); return r.height ? (r.left + r.width/2) + ',' + (r.top + r.height/2) : ''; })()") { r in
                    let xy = ((r as? String) ?? "").split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { go(CGPoint(x: xy[0], y: xy[1])) } else { log("\(name): MISSING (the card didn't open)"); step(list, i + 1) }
                }
            } else if let x = c["x"] as? Double, let y = c["y"] as? Double {
                go(CGPoint(x: x, y: y))
            }
        }
        func finish() {
            o.snapshot(to: URL(fileURLWithPath: outDir + "/all.png")) {
                ticker.invalidate()
                o.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    /// A picture of the overlay around `p` (what WebKit drew), 2× wherever the screen is.
    private static func shot(_ o: Overlay, at p: CGPoint, to path: String, done: @escaping () -> Void) {
        let tmp = path + ".full.png"
        o.snapshot(to: URL(fileURLWithPath: tmp)) {
            defer { try? FileManager.default.removeItem(atPath: tmp); done() }
            guard let img = NSImage(contentsOfFile: tmp), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let k = CGFloat(cg.width) / max(1, img.size.width)
            let r = CGRect(x: (p.x - 170) * k, y: (p.y - 110) * k, width: 340 * k, height: 220 * k)
                .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            guard let crop = cg.cropping(to: r) else { return }
            // Mark where the tracked cursor is: a small red cross (the real mouse isn't there).
            let w = crop.width, h = crop.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            let cx = (p.x * k - r.minX), cy = CGFloat(h) - (p.y * k - r.minY)
            ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(2)
            ctx.strokeLineSegments(between: [CGPoint(x: cx - 7, y: cy), CGPoint(x: cx + 7, y: cy), CGPoint(x: cx, y: cy - 7), CGPoint(x: cx, y: cy + 7)])
            guard let out = ctx.makeImage() else { return }
            let rep = NSBitmapImageRep(cgImage: out)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    /// A wide test picture (a data URL) with numbers right at its left and right edges.
    private static func picture(width: Int, height: Int) -> String {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 64), .foregroundColor: NSColor.systemRed]
        ("104.45°" as NSString).draw(at: NSPoint(x: 8, y: CGFloat(height) / 2 - 30), withAttributes: a)
        ("95.84" as NSString).draw(at: NSPoint(x: CGFloat(width) - 190, y: CGFloat(height) - 90), withAttributes: a)
        ("H" as NSString).draw(at: NSPoint(x: CGFloat(width) - 60, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 70), .foregroundColor: NSColor.black])
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
