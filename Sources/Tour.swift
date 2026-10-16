import AppKit

/// `Sooth --tour <outdir>`: uses Sooth the way a person would (painting, masks, adjustment layers,
/// text, shapes, pictures past the edge, dragging the canvas, vectorize, the Library, small windows,
/// zoomed and scrolled views) and saves the whole window after each step, for looking over by eye.
enum Tour {
    static func run(out: String) {
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Library.folder = dir.appendingPathComponent("library", isDirectory: true)
        Library.useTrash = false
        try? FileManager.default.removeItem(at: Library.folder)
        try? FileManager.default.createDirectory(at: Library.folder, withIntermediateDirectories: true)
        let st = AppState.shared
        let doc = Document(width: 800, height: 600, background: .white)
        let ctl = EditorWindowController(doc: doc)
        guard let win = ctl.window, let view = win.contentView else { exit(1) }
        win.setContentSize(NSSize(width: 1320, height: 860))
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        win.orderFrontRegardless()
        let eng = ctl.canvas.engine, cv = ctl.canvas!
        var n = 0
        func settle() { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); view.displayIfNeeded() }
        func shot(_ name: String, _ v: NSView? = nil) {
            settle()
            let v = v ?? view
            n += 1
            // Render the layer tree, as the screen shows it (cacheDisplay leaves the panels on white).
            let scale: CGFloat = 2
            let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
            guard let layer = v.layer, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.scaleBy(x: scale, y: scale)
            if !v.isFlipped { } 
            layer.render(in: c)
            if let img = c.makeImage() {
                try? Document.encode(img, as: .png).write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", n, name)))
            }
        }
        func stroke(_ pts: [CGPoint]) {
            eng.down(pts[0], right: false, flags: [])
            for p in pts.dropFirst() { eng.drag(p, flags: []) }
            eng.up(pts.last!, flags: [])
        }
        func type(_ s: String, at p: CGPoint) {
            st.tool = .text
            eng.down(p, right: false, flags: []); eng.up(p, flags: [])
            for ch in s { eng.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: cv.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        ctl.zoomFit(nil)
        st.tool = .brush
        shot("launch")

        // Paint on a new layer.
        ctl.addLayer(nil)
        st.primary = RGBA(r: 230, g: 60, b: 90); st.brushWidth = 24; st.brushHardness = 0.8; st.brushOpacity = 1
        stroke((0...40).map { i in CGPoint(x: 120 + CGFloat(i) * 14, y: 300 + 90 * sin(CGFloat(i) / 5)) })
        st.primary = RGBA(r: 40, g: 120, b: 230)
        stroke((0...40).map { i in CGPoint(x: 120 + CGFloat(i) * 14, y: 360 + 70 * cos(CGFloat(i) / 4)) })
        shot("painted")

        // A mask, painted.
        ctl.addLayerMask(nil)
        st.primary = .black; st.brushWidth = 80
        stroke([CGPoint(x: 300, y: 200), CGPoint(x: 340, y: 450)])
        shot("mask-painted")

        // An adjustment layer.
        Dialogs.testValues = [40, 30, 0]
        ctl.newAdjustmentLayer(AdjustmentSpec.filters.first { $0.name == "Hue / Saturation" }!)
        Dialogs.testValues = nil
        shot("adjustment")

        // Text, still being typed, then the text tool's options.
        TextPreset.meme.apply(st, imageWidth: doc.width)
        type("HELLO EASEL", at: CGPoint(x: 400, y: 40))
        shot("typing")
        eng.finishText()

        // A shape, selected.
        st.tool = .shapes; st.shape = .star; st.fillStyle = .both; st.primary = .black; st.secondary = RGBA(r: 250, g: 210, b: 40); st.brushWidth = 6
        eng.down(CGPoint(x: 560, y: 380), right: false, flags: []); eng.drag(CGPoint(x: 720, y: 540), flags: []); eng.up(CGPoint(x: 720, y: 540), flags: [])
        shot("shape")

        // A picture hanging off the right edge.
        let pic = Layer(width: 260, height: 180, name: "")
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 90, g: 200, b: 160).cg, RGBA(r: 30, g: 60, b: 140).cg] as CFArray, locations: [0, 1])!
        pic.ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 260, y: 180), options: [])
        ctl.addImageLayer(pic.image(), named: "Photo", at: CGPoint(x: 600, y: 150))
        st.tool = .moveSelected
        stroke([CGPoint(x: 600, y: 150), CGPoint(x: 760, y: 120)])
        shot("off-canvas")

        // Dragging the canvas bigger, mid-drag.
        let grip = CGPoint(x: CGFloat(doc.width) + 16 / cv.magnification, y: CGFloat(doc.height) / 2)
        cv.mouseDown(with: mouse(.leftMouseDown, grip))
        cv.mouseDragged(with: mouse(.leftMouseDragged, grip + CGPoint(x: 150, y: 0)))
        shot("canvas-drag")
        cv.mouseUp(with: mouse(.leftMouseUp, grip + CGPoint(x: 150, y: 0)))
        ctl.zoomFit(nil)
        shot("canvas-grown")

        // Zoomed in and scrolled: guides must stay inside the picture area.
        ctl.setZoom(2, at: CGPoint(x: 100, y: 100))
        st.tool = .brush
        shot("zoomed-scrolled")
        ctl.zoomFit(nil)

        // Click off to deselect, with a selection made first.
        st.tool = .rectSelect
        stroke([CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 300)])
        st.tool = .moveSelected
        shot("selection")
        stroke([CGPoint(x: 850, y: 550), CGPoint(x: 850, y: 550)])
        shot("deselected")

        // Vectorize the painted layer.
        doc.active = 1
        Dialogs.testValues = [6, 1, 0.5]
        ctl.vectorize(nil)
        Dialogs.testValues = nil
        let until = Date().addingTimeInterval(20)
        while doc.history.last?.name != "Vectorize" && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        shot("vectorized")

        // The Library, with a few things kept.
        ctl.addToLibrary(nil)
        doc.active = doc.layers.firstIndex { $0.text != nil } ?? 0
        ctl.addToLibrary(nil)
        doc.active = doc.layers.firstIndex { $0.shape != nil } ?? 0
        ctl.addToLibrary(nil)
        if let lv = LibraryPanel.shared.contentView {
            LibraryPanel.shared.setContentSize(NSSize(width: 420, height: 420))
            shot("library", lv)
        }

        // Each tool's options line.
        for t in [ToolKind.magicWand, .gradient, .text, .line, .rectSelect, .clone] {
            st.tool = t
            shot("tool-\(t.word)")
        }

        // Text effects and the colour picker.
        st.tool = .text
        TextEffectsPanel.show()
        if let fx = TextEffectsPanel.shared.contentView { shot("text-effects", fx) }
        let pick = ColorPickerController(primary: true)
        pick.view.frame = NSRect(origin: .zero, size: pick.view.fittingSize)
        shot("colour-picker", pick.view)

        // The smallest window.
        win.setContentSize(NSSize(width: 760, height: 800))
        ctl.zoomFit(nil)
        st.tool = .brush
        shot("small-window")
        st.tool = .text
        shot("small-window-text")

        // Long history and many layers.
        win.setContentSize(NSSize(width: 1320, height: 860))
        for i in 0..<8 { ctl.addLayer(nil); doc.activeLayer.name = "Layer with a rather long name \(i)" }
        ctl.zoomFit(nil)
        shot("many-layers")
        print("tour: wrote \(n) shots to \(dir.path)")
        exit(0)
    }
}
