import AppKit

/// `Sooth --bench`: times the hot paths on a phone-sized photo canvas (8064 × 6048) and reports
/// how much memory history holds. Prints one line per measurement and exits.
enum Bench {
    static func run() {
        let w = 8064, h = 6048
        func ms(_ t: CFAbsoluteTime) -> String { String(format: "%.1f ms", (CFAbsoluteTimeGetCurrent() - t) * 1000) }

        var t = CFAbsoluteTimeGetCurrent()
        let doc = Document(width: w, height: h, background: .white)
        print("new \(w)x\(h) document: \(ms(t))")
        let ctl = EditorWindowController(doc: doc)
        let eng = ctl.canvas.engine
        let st = AppState.shared
        st.tool = .brush; st.brushWidth = 40; st.primary = RGBA(r: 200, g: 30, b: 40)

        // One long stroke: time each drag event including the recomposite a redraw would need.
        var pts: [CGPoint] = []
        for i in 0..<240 { pts.append(CGPoint(x: 400 + Double(i) * 25, y: 3000 + 800 * sin(Double(i) / 20))) }
        eng.down(pts[0], right: false, flags: [])
        var worst = 0.0, total = 0.0
        for p in pts.dropFirst() {
            let t0 = CFAbsoluteTimeGetCurrent()
            eng.drag(p, flags: [])
            _ = doc.composite()
            let d = CFAbsoluteTimeGetCurrent() - t0
            worst = max(worst, d); total += d
        }
        t = CFAbsoluteTimeGetCurrent()
        eng.up(pts.last!, flags: [])
        print(String(format: "brush drag: avg %.1f ms, worst %.1f ms per event (%d events)",
                     total / Double(pts.count - 1) * 1000, worst * 1000, pts.count - 1))
        print("brush commit: \(ms(t))")

        // Twenty small edits, then measure what history retains.
        t = CFAbsoluteTimeGetCurrent()
        for i in 0..<20 {
            let p = CGPoint(x: 500 + i * 300, y: 500)
            eng.down(p, right: false, flags: []); eng.drag(p + CGPoint(x: 60, y: 60), flags: []); eng.up(p + CGPoint(x: 60, y: 60), flags: [])
        }
        print("20 small strokes: \(ms(t))")
        print(String(format: "history retains %.0f MB across %d steps", Double(doc.historyBytes()) / 1_048_576, doc.history.count))

        t = CFAbsoluteTimeGetCurrent()
        doc.undo()
        print("undo: \(ms(t))")
        doc.redo()

        // A history step with several big layers (layer panel thumbnails included).
        for _ in 0..<4 { doc.addLayer() }
        doc.commit("Add Layers", symbol: "x", touch: .none)
        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<5 { doc.commit("Step", symbol: "x", touch: .none) }
        print(String(format: "history step with %d layers: %.1f ms", doc.layers.count, (CFAbsoluteTimeGetCurrent() - t) / 5 * 1000))
        if let v = ctl.window?.contentView {
            v.layoutSubtreeIfNeeded()
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            t = CFAbsoluteTimeGetCurrent()
            for _ in 0..<3 { doc.commit("Step", symbol: "x", touch: .none); v.cacheDisplay(in: v.bounds, to: rep) }
            print(String(format: "  step + full window redraw: %.1f ms", (CFAbsoluteTimeGetCurrent() - t) / 3 * 1000))
        }

        // Canvas redraw at zoom-to-fit (what panning and scrolling cost).
        if let win = ctl.window, let view = win.contentView {
            win.setContentSize(NSSize(width: 1440, height: 900)); view.layoutSubtreeIfNeeded()
            ctl.zoomFit(nil)
            let cv = ctl.canvas!
            let rep = cv.bitmapImageRepForCachingDisplay(in: cv.visibleRect)!
            cv.cacheDisplay(in: cv.visibleRect, to: rep)   // warm
            t = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 { cv.cacheDisplay(in: cv.visibleRect, to: rep) }
            print(String(format: "canvas redraw at %.0f%%: %.1f ms per frame", cv.magnification * 100, (CFAbsoluteTimeGetCurrent() - t) / 5 * 1000))
            // Parts: an empty rep fill (cacheDisplay overhead) vs drawing.
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            t = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                checkerColor.setFill(); cv.visibleRect.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            print(String(format: "  checker fill alone: %.1f ms", (CFAbsoluteTimeGetCurrent() - t) / 5 * 1000))
            t = CFAbsoluteTimeGetCurrent()
            for _ in 0..<5 {
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
                cv.draw(cv.visibleRect)
                NSGraphicsContext.restoreGraphicsState()
            }
            print(String(format: "  draw() alone: %.1f ms", (CFAbsoluteTimeGetCurrent() - t) / 5 * 1000))
        }

        // Content-aware fill on a real photo with a big hole.
        if let photo = try? Document.load(url: URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")) {
            let L = photo.layers[0]
            var mask = [UInt8](repeating: 0, count: L.width * L.height)
            for y in 900..<1500 { for x in 1500..<2100 { mask[y * L.width + x] = 255 } }
            t = CFAbsoluteTimeGetCurrent()
            Inpaint.fill(L.bytes, width: L.width, height: L.height, mask: mask)
            print("content-aware fill, 600×600 hole in \(L.width)×\(L.height): \(ms(t))")
            try? Document.encode(L.image(), as: .jpeg).write(to: URL(fileURLWithPath: "/tmp/claude-501/inpaint-photo.jpg"))
        }

        if let blur = Filters.effects.flatMap(\.1).first(where: { $0.name == "Gaussian Blur" }) {
            let L = doc.activeLayer
            let src = L.data()
            t = CFAbsoluteTimeGetCurrent()
            src.withUnsafeBytes { raw in
                blur.run(FilterIO(src: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), dst: L.bytes,
                                  w: L.width, h: L.height, primary: st.primary, secondary: st.secondary), [8])
            }
            print("gaussian blur r=8: \(ms(t))")
        }
        exit(0)
    }
}
