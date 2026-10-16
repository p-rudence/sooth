import AppKit

/// `Sooth --demo <image> <outdir>`: opens an image, adds meme text, a speech bubble and a cut-out
/// the way a person would, and renders the window (light and dark) for review and screenshots.
enum Demo {
    /// An original picture for screenshots: sunset sky, sun, stars and layered hills.
    static func scene() -> Document {
        let W = 2400, H = 1350
        let doc = Document(width: W, height: H, background: .white)
        let c = doc.layers[0].ctx   // y up
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 255, g: 186, b: 108).cg, RGBA(r: 236, g: 92, b: 120).cg,
                                                              RGBA(r: 92, g: 44, b: 120).cg, RGBA(r: 30, g: 22, b: 70).cg] as CFArray,
                             locations: [0, 0.35, 0.7, 1])!
        c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 380), end: CGPoint(x: 0, y: CGFloat(H)), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        var rng = RNG(3)
        for _ in 0..<160 {
            let x = rng.unit() * Double(W), y = 760 + rng.unit() * 590, r = 1 + rng.unit() * 2.4
            c.setFillColor(CGColor(gray: 1, alpha: 0.35 + rng.unit() * 0.6)); c.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        let sun = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 255, g: 246, b: 210).cg, RGBA(r: 255, g: 196, b: 120, a: 0).cg] as CFArray, locations: [0.45, 1])!
        c.drawRadialGradient(sun, startCenter: CGPoint(x: 1600, y: 520), startRadius: 0, endCenter: CGPoint(x: 1600, y: 520), endRadius: 260, options: [])
        let hills: [(RGBA, CGFloat, CGFloat, Double)] = [(RGBA(r: 120, g: 60, b: 120), 520, 120, 1.3), (RGBA(r: 78, g: 38, b: 96), 400, 140, 2.1),
                                                         (RGBA(r: 44, g: 24, b: 66), 260, 120, 3.4)]
        for (col, base, amp, f) in hills {
            let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: 0))
            for x in stride(from: 0, through: W, by: 12) {
                let t = Double(x) / Double(W)
                p.addLine(to: CGPoint(x: CGFloat(x), y: base + amp * CGFloat(sin(t * .pi * f + f) * 0.6 + sin(t * .pi * f * 2.7) * 0.4)))
            }
            p.addLine(to: CGPoint(x: W, y: 0)); p.closeSubpath()
            c.addPath(p); c.setFillColor(col.cg); c.fillPath()
        }
        doc.layers[0].touch()
        doc.history = [HistoryItem(name: "New Image", symbol: "doc", state: doc.snapshot())]
        return doc
    }

    static func run(image: String, out: String) {
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let doc = image == "scene" ? scene() : try? Document.load(url: URL(fileURLWithPath: image)) else { print("can't open \(image)"); exit(1) }
        let st = AppState.shared
        let ctl = EditorWindowController(doc: doc)
        guard let win = ctl.window, let view = win.contentView else { exit(1) }
        win.setContentSize(NSSize(width: 1440, height: 900))
        view.layoutSubtreeIfNeeded()
        ctl.zoomFit(nil)
        let eng = ctl.canvas.engine
        let W = CGFloat(doc.width), H = CGFloat(doc.height)
        func type(_ s: String, at p: CGPoint) {
            st.tool = .text
            eng.down(p, right: false, flags: []); eng.up(p, flags: [])
            for ch in s { eng.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            eng.finishText()
        }
        TextPreset.meme.apply(st, imageWidth: doc.width)
        type(image == "scene" ? "MAKE IT REAL" : "WHEN THE EDITOR", at: CGPoint(x: W / 2, y: H * 0.04))
        type(image == "scene" ? "RIGHT ON YOUR MAC" : "IS ACTUALLY NATIVE", at: CGPoint(x: W / 2, y: H * 0.80))
        // a speech bubble with comic text in it
        st.tool = .shapes; st.shape = .bubble; st.fillStyle = .both; st.brushWidth = max(3, W / 300)
        st.primary = .black; st.secondary = .white
        let b = CGRect(x: W * 0.06, y: H * 0.30, width: W * 0.3, height: H * 0.22)
        eng.down(b.origin, right: false, flags: []); eng.drag(CGPoint(x: b.maxX, y: b.maxY), flags: []); eng.up(CGPoint(x: b.maxX, y: b.maxY), flags: [])
        st.tool = .text
        TextPreset.comic.apply(st, imageWidth: doc.width)
        st.fontSize = (W / 30).rounded(); st.textEffects.rotation = 0; st.textShadow = false; st.outlineWidth = 0
        st.primary = .black
        type(image == "scene" ? "free & native!" : "hi :3", at: CGPoint(x: b.midX, y: b.minY + b.height * 0.22))
        if image == "scene" {
            // a neon title too
            TextPreset.neon.apply(st, imageWidth: doc.width)
            st.fontSize = (W / 22).rounded()
            type("sooth", at: CGPoint(x: W * 0.74, y: H * 0.36))
        }
        st.tool = .moveSelected
        doc.active = doc.layers.count - 2
        ctl.structureChanged()
        // Show it (off-screen) so every control really draws.
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        // `--looks` renders the window once in each look (look-tianmu.png …); otherwise just the house look.
        let looks: [Look] = CommandLine.arguments.contains("--looks") ? Look.allCases : [.tianmu]
        TitleBarView.alwaysActive = true
        for l in looks {
            if l != Look.current {
                Look.current = l
                NotificationCenter.default.post(name: .lookChanged, object: nil)
            }
            guard let view = win.contentView else { continue }
            let name = looks.count == 1 ? "demo-dark.png" : "look-\(l.rawValue).png"
            view.needsDisplay = true
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let img = NSImage(size: view.bounds.size)
            img.lockFocus()
            view.effectiveAppearance.performAsCurrentDrawingAppearance { Ink.window.setFill(); view.bounds.fill() }
            rep.draw(in: view.bounds)
            img.unlockFocus()
            if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
        if CommandLine.arguments.contains("--picker"), let pv = LookPicker().window?.contentView {
            // The first-launch picker, as a stranger first sees it.
            pv.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000)); pv.window?.orderFrontRegardless()
            pv.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.3)); pv.displayIfNeeded()
            if let rep = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) {
                pv.cacheDisplay(in: pv.bounds, to: rep)
                let img = NSImage(size: pv.bounds.size)
                img.lockFocus()
                (pv.window?.backgroundColor ?? .black).setFill(); pv.bounds.fill()
                rep.draw(in: pv.bounds)
                img.unlockFocus()
                if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                    try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("picker.png"))
                }
            }
        }
        try? Document.encode(doc.composite(), as: .png).write(to: dir.appendingPathComponent("demo-image.png"))
        print("wrote \(dir.path)")
        exit(0)
    }
}
