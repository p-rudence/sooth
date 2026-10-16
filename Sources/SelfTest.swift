import AppKit

/// `Sooth --selftest <outdir>`: drives the real tools, filters and file IO without touching the
/// screen, writes PNG evidence plus a rendering of the editor window, and exits non-zero on failure.
enum SelfTest {
    static func run(out: String) {
        let dir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures: [String] = []
        func check(_ ok: Bool, _ msg: String) {
            print((ok ? "PASS " : "FAIL ") + msg)
            if !ok { failures.append(msg) }
        }
        func png(_ img: CGImage, _ name: String) {
            try? Document.encode(img, as: .png).write(to: dir.appendingPathComponent(name))
        }

        let st = AppState.shared
        let doc = Document(width: 640, height: 480, background: .white)
        let ctl = EditorWindowController(doc: doc)
        let eng = ctl.canvas.engine
        func stroke(_ tool: ToolKind, _ pts: [CGPoint], right: Bool = false, flags: NSEvent.ModifierFlags = []) {
            st.tool = tool
            eng.down(pts[0], right: right, flags: flags)
            for p in pts.dropFirst() { eng.drag(p, flags: flags) }
            eng.up(pts.last!, flags: flags)
        }

        // Paintbrush
        st.primary = RGBA(r: 220, g: 40, b: 60); st.brushWidth = 12
        stroke(.brush, [CGPoint(x: 40, y: 60), CGPoint(x: 200, y: 80), CGPoint(x: 320, y: 40)])
        let p1 = doc.activeLayer.pixel(44, 60)
        check(p1.r > 180 && p1.g < 90, "paintbrush paints primary color (got \(p1))")

        // Colour picker: HSV maths round-trips, and the popover drives the primary colour.
        var worst = 0
        for c in [RGBA(r: 255, g: 0, b: 0), RGBA(r: 12, g: 200, b: 99), RGBA(r: 128, g: 128, b: 128), RGBA(r: 250, g: 250, b: 3),
                  RGBA(r: 0, g: 0, b: 0), RGBA(r: 31, g: 64, b: 222)] {
            let back = HSV(c).rgba(alpha: 255)
            worst = max(worst, abs(Int(back.r) - Int(c.r)), abs(Int(back.g) - Int(c.g)), abs(Int(back.b) - Int(c.b)))
        }
        check(worst <= 1, "HSV ↔ RGB round-trips (worst error \(worst))")
        st.primary = RGBA(r: 200, g: 40, b: 40)
        let picker = ColorPickerController(primary: true)
        let pv = picker.view
        pv.appearance = NSAppearance(named: .darkAqua)
        pv.frame = NSRect(origin: .zero, size: pv.fittingSize)
        pv.layoutSubtreeIfNeeded()
        if let r = pv.bitmapImageRepForCachingDisplay(in: pv.bounds) {
            pv.cacheDisplay(in: pv.bounds, to: r)
            try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("06-color-picker.png"))
        }
        check(st.primary == RGBA(r: 200, g: 40, b: 40), "opening the picker keeps the colour")
        st.primary = .black

        // Brush engine: hardness, opacity without build-up, pressure, all on a scratch document.
        do {
            let bdoc = Document(width: 600, height: 300, background: .white)
            let bc = EditorWindowController(doc: bdoc)
            let be = bc.canvas.engine
            func bstroke(_ pts: [CGPoint], pressures: [CGFloat]? = nil) {
                st.tool = .brush
                be.pressure = pressures?[0] ?? 1
                be.down(pts[0], right: false, flags: [])
                for (i, q) in pts.enumerated().dropFirst() { be.pressure = pressures?[i] ?? 1; be.drag(q, flags: []) }
                be.up(pts.last!, flags: [])
                be.pressure = 1
            }
            st.primary = .black; st.brushWidth = 40; st.brushOpacity = 1
            st.brushHardness = 1
            bstroke([CGPoint(x: 40, y: 50), CGPoint(x: 260, y: 50)])
            st.brushHardness = 0
            bstroke([CGPoint(x: 340, y: 50), CGPoint(x: 560, y: 50)])
            let hardEdge = bdoc.activeLayer.pixel(150, 50 + 15), softEdge = bdoc.activeLayer.pixel(450, 50 + 15)
            check(hardEdge.r < 20 && softEdge.r > 120, "hardness: hard edge is solid, soft edge fades (\(hardEdge.r) vs \(softEdge.r))")
            st.brushHardness = 1; st.brushOpacity = 0.5
            bstroke([CGPoint(x: 40, y: 150), CGPoint(x: 260, y: 150), CGPoint(x: 150, y: 110), CGPoint(x: 150, y: 200)])
            let once = bdoc.activeLayer.pixel(80, 150), crossed = bdoc.activeLayer.pixel(150, 150)
            check(abs(Int(once.r) - 127) < 6 && once == crossed, "50% opacity doesn't build up where a stroke crosses itself (\(once.r), \(crossed.r))")
            st.brushOpacity = 1
            var pts: [CGPoint] = [], prs: [CGFloat] = []
            for i in 0...40 { pts.append(CGPoint(x: 340 + Double(i) * 5.5, y: 150)); prs.append(0.1 + 0.9 * Double(i) / 40) }
            bstroke(pts, pressures: prs)
            func thickness(_ x: Int) -> Int { (120...180).filter { bdoc.activeLayer.pixel(x, $0).r < 128 }.count }
            check(thickness(350) < 12 && thickness(550) > 30, "pen pressure tapers the stroke (\(thickness(350))px → \(thickness(550))px)")
            png(bdoc.composite(), "05-brush.png")
            st.brushHardness = 0.75
        }

        // Shapes: filled rectangle with outline
        st.primary = RGBA(r: 20, g: 60, b: 200); st.secondary = RGBA(r: 250, g: 210, b: 40)
        st.shape = .rectangle; st.fillStyle = .both; st.brushWidth = 6
        stroke(.shapes, [CGPoint(x: 360, y: 40), CGPoint(x: 500, y: 120), CGPoint(x: 600, y: 200)])
        check(doc.activeLayer.pixel(480, 120) == RGBA(r: 250, g: 210, b: 40), "shape interior uses secondary color")
        check(doc.activeLayer.pixel(600, 120).b > 150, "shape outline uses primary color")

        // Undo / redo
        let before = doc.history.count
        doc.undo()
        check(doc.activeLayer.pixel(480, 120) == .white, "undo removes the rectangle")
        doc.redo()
        check(doc.activeLayer.pixel(480, 120) == RGBA(r: 250, g: 210, b: 40), "redo restores the rectangle")
        check(doc.history.count == before, "history keeps \(before) entries across undo/redo")

        // The rectangle is a live shape layer: restyle it, resize it with a handle, then merge it down.
        check(doc.activeLayer.shape?.kind == .rectangle && doc.layers.count == 2, "a drawn shape becomes its own editable shape layer")
        st.tool = .shapes
        st.brushWidth = 10; eng.styleChanged(); eng.flushShapeEdit()
        check(doc.activeLayer.shape?.width == 10 && doc.history.last?.name == "Edit Shape", "toolbar changes restyle the selected shape")
        let fr = doc.activeLayer.shape!.frame
        stroke(.shapes, [CGPoint(x: fr.maxX, y: fr.maxY), CGPoint(x: fr.maxX + 20, y: fr.maxY + 10)])
        check(abs((doc.activeLayer.shape?.frame.width ?? 0) - (fr.width + 20)) < 1 && doc.history.last?.name == "Resize Shape",
              "a shape's corner handle resizes it, staying editable")
        stroke(.shapes, [CGPoint(x: fr.midX, y: fr.midY), CGPoint(x: fr.midX - 10, y: fr.midY)])
        check(abs((doc.activeLayer.shape?.frame.minX ?? 0) - (fr.minX - 10)) < 1, "dragging inside a shape moves it")
        eng.deselectShape()
        let w0 = doc.activeLayer.shape?.width
        st.brushWidth = 22; eng.styleChanged()
        check(doc.activeLayer.shape?.width == w0, "after Return, new toolbar settings don't change the old shape")
        doc.undo(); doc.undo(); doc.undo()
        st.brushWidth = 6
        check(doc.activeLayer.shape?.frame == fr, "undo walks back shape edits")
        // the rest of the checks expect the rectangle painted on the background
        doc.mergeDown(); doc.commit("Merge Layer Down", symbol: "x")
        check(doc.layers.count == 1 && doc.activeLayer.shape == nil, "merging a shape layer down makes it pixels")

        // New layer + radial gradient + multiply blend
        doc.addLayer(); doc.commit("Add New Layer", symbol: "plus", touch: .none)
        st.gradient = .radial; st.primary = .white; st.secondary = RGBA(r: 90, g: 200, b: 255)
        stroke(.gradient, [CGPoint(x: 320, y: 300), CGPoint(x: 560, y: 300)])
        doc.activeLayer.blend = .multiply
        doc.commit("Layer Properties", symbol: "slider.horizontal.3", touch: .none)
        let c = doc.compositePixel(600, 470)
        check(c.r < 120 && c.b > 200, "multiply layer tints the composite (got \(c))")
        check(doc.layers.count == 2, "two layers present")

        // Ellipse selection + Gaussian blur restricted to it
        doc.active = 0
        stroke(.ellipseSelect, [CGPoint(x: 20, y: 20), CGPoint(x: 340, y: 120)])
        check(doc.selection != nil && !(doc.selection!.isEmpty), "ellipse selection created")
        let outside = doc.activeLayer.pixel(480, 120)
        let blur = Filters.effects.flatMap(\.1).first { $0.name == "Gaussian Blur" }!
        let L = doc.activeLayer, src = L.data()
        src.withUnsafeBytes { raw in
            let s = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            blur.run(FilterIO(src: s, dst: L.bytes, w: L.width, h: L.height, primary: st.primary, secondary: st.secondary), [8])
            blendMask(src: s, dst: L.bytes, mask: doc.selection!.mask)
        }
        doc.commit("Gaussian Blur", symbol: "sparkles")
        check(doc.activeLayer.pixel(480, 120) == outside, "blur leaves pixels outside the selection alone")
        doc.selection = nil; doc.commit("Deselect", symbol: "x", touch: .none)

        // Magic wand + bucket
        st.tolerance = 0.2; st.floodGlobal = false
        stroke(.magicWand, [CGPoint(x: 480, y: 120)])
        let wb = doc.selection?.bounds ?? .zero
        check(wb.width > 220 && wb.width < 240, "magic wand selects the rectangle interior (\(wb))")
        doc.selection = nil
        st.primary = RGBA(r: 40, g: 180, b: 90)
        stroke(.bucket, [CGPoint(x: 480, y: 120)])
        check(doc.activeLayer.pixel(470, 100) == RGBA(r: 40, g: 180, b: 90), "paint bucket fills the region")
        check(doc.activeLayer.pixel(10, 470) == .white, "paint bucket stays inside the region")

        // Pencil, eraser, picker
        st.primary = .black
        stroke(.pencil, [CGPoint(x: 10, y: 300), CGPoint(x: 100, y: 300)])
        check(doc.activeLayer.pixel(50, 300) == .black, "pencil draws hard pixels")
        st.brushWidth = 20
        stroke(.eraser, [CGPoint(x: 40, y: 400), CGPoint(x: 90, y: 400)])
        check(doc.activeLayer.pixel(60, 400).a == 0, "eraser clears to transparent")
        st.sampleImage = false
        stroke(.picker, [CGPoint(x: 470, y: 100)])
        check(st.primary == RGBA(r: 40, g: 180, b: 90), "color picker samples the layer")

        // Clone stamp
        st.tool = .clone
        eng.down(CGPoint(x: 470, y: 100), right: false, flags: .option)
        stroke(.clone, [CGPoint(x: 150, y: 420), CGPoint(x: 160, y: 420)])
        check(doc.activeLayer.pixel(155, 420) == RGBA(r: 40, g: 180, b: 90), "clone stamp copies from the source")

        // Rectangle select + move selected pixels
        stroke(.rectSelect, [CGPoint(x: 360, y: 40), CGPoint(x: 420, y: 100)])
        stroke(.moveSelected, [CGPoint(x: 380, y: 60), CGPoint(x: 380, y: 200), CGPoint(x: 380, y: 260)])
        check(doc.selection?.bounds.minY == 240, "selection follows moved pixels (\(doc.selection?.bounds ?? .zero))")
        check(doc.activeLayer.pixel(370, 50).a == 0, "move leaves transparency behind")

        // Handles: corner scale, ⇧-snapped rotate, nudge, outline-only move, cursors, undo.
        let movedPx = doc.activeLayer.pixel(365, 245)
        stroke(.moveSelected, [CGPoint(x: 420, y: 300), CGPoint(x: 450, y: 330), CGPoint(x: 480, y: 360)])
        let sb = doc.selection?.bounds ?? .zero
        check(abs(sb.width - 120) <= 2 && abs(sb.height - 120) <= 2 && abs(sb.minX - 360) <= 1,
              "dragging the corner handle scales the selection (\(sb))")
        check(doc.activeLayer.pixel(370, 255) == movedPx, "scaled pixels keep their colour")
        check(doc.history.last?.name == "Resize Selected Pixels", "corner drag records Resize Selected Pixels")
        check(eng.cursor(at: CGPoint(x: 480, y: 360)) !== Cursors.movePixels && eng.cursor(at: CGPoint(x: 480, y: 360)) != nil,
              "a handle shows a resize cursor")
        check(eng.cursor(at: CGPoint(x: 420, y: 300)) === Cursors.movePixels, "inside the box shows the move-pixels cursor")
        check(eng.cursor(at: CGPoint(x: 500, y: 300)) === Cursors.rotate, "just outside the box shows the rotate cursor")
        st.tool = .moveSelected
        eng.down(CGPoint(x: 520, y: 300), right: true, flags: .shift)
        eng.drag(CGPoint(x: 520, y: 340), flags: .shift)
        eng.drag(CGPoint(x: 480, y: 340), flags: .shift)
        eng.up(CGPoint(x: 480, y: 340), flags: .shift)
        let rb = doc.selection?.bounds ?? .zero
        check(abs(rb.width - 170) <= 4, "⇧ right-drag rotates by a snapped 45° (bounds \(rb))")
        doc.undo()
        check(abs((doc.selection?.bounds.width ?? 0) - 120) <= 2, "undo restores the unrotated selection")
        let before0 = doc.selection?.bounds.minX ?? 0
        eng.nudge(1, 0)
        check((doc.selection?.bounds.minX ?? 0) == before0 + 1, "arrow-key nudge moves by one pixel after undo")
        st.tool = .moveSelection
        let px0 = doc.activeLayer.pixel(370, 255)
        check(eng.cursor(at: CGPoint(x: 420, y: 300)) === Cursors.moveSelection, "Move Selection has its own cursor")
        stroke(.moveSelection, [CGPoint(x: 420, y: 300), CGPoint(x: 420, y: 320)])
        check(doc.activeLayer.pixel(370, 255) == px0 && abs((doc.selection?.bounds.minY ?? 0) - 260) <= 1,
              "Move Selection moves the outline, not the pixels")
        doc.selection = nil

        png(doc.composite(), "01-painting.png")

        // WYSIWYG text layers: type into the live box, restyle it live, drag it, commit, compare pixels,
        // then edit it again, move and resize it with the Move tool, save it, and paint on it.
        let layersBefore = doc.layers.count
        doc.active = doc.layers.count - 1
        st.fontName = "Impact"; st.fontSize = 60; st.bold = false; st.italic = false; st.underline = false
        st.primary = .white; st.secondary = .black; st.outlineWidth = 4; st.textAlign = .center; st.textShadow = false
        stroke(.text, [CGPoint(x: 320, y: 300)])
        if let ed = eng.text {
            for ch in "EASEL" { ed.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            check(ed.storage.string == "EASEL", "typing goes into the live text box")
            let w0 = ed.view.frame.width
            check(abs(ed.view.frame.midX - 320) < 2, "centred text grows around the click point")
            st.fontSize = 80; eng.styleChanged()
            check(ed.view.frame.width > w0 * 1.2, "changing the size restyles the live text (\(w0) → \(ed.view.frame.width))")
            ed.view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
            var lines = 0
            ed.layout.enumerateLineFragments(forGlyphRange: ed.layout.glyphRange(for: ed.container)) { _, _, _, _, _ in lines += 1 }
            check(lines == 1, "a trailing space never wraps the line")
            ed.view.doCommand(by: #selector(NSText.deleteBackward(_:)))
            let f0 = ed.view.frame
            stroke(.text, [CGPoint(x: f0.minX - 3, y: f0.midY), CGPoint(x: f0.minX - 3, y: f0.midY + 20), CGPoint(x: f0.minX - 3, y: f0.midY + 40)])
            check(eng.text === ed && abs(ed.view.frame.minY - (f0.minY + 40)) < 1, "dragging the frame moves the text box")
            check(doc.layers.count == layersBefore, "live text is not yet a layer")
            let frame = ed.view.frame
            let rep = ed.view.bitmapImageRepForCachingDisplay(in: ed.view.bounds)!
            ed.view.cacheDisplay(in: ed.view.bounds, to: rep)
            let k = CGFloat(rep.pixelsWide) / frame.width
            eng.finishText()
            check(eng.text == nil && doc.history.last?.name == "Add Text" && doc.layers.count == layersBefore + 1,
                  "finishing adds one text layer in one history step")
            var TL = doc.activeLayer
            check(TL.text?.string == "EASEL" && TL.name == "EASEL", "the new layer is an editable text layer named after its text")
            var agree = 0, total = 0, white = 0, black = 0
            for y in stride(from: Int(frame.minY) + 1, to: Int(frame.maxY) - 1, by: 2) {
                for x in stride(from: Int(frame.minX) + 1, to: Int(frame.maxX) - 1, by: 2) {
                    let lv = rep.colorAt(x: Int((CGFloat(x) + 0.5 - frame.minX) * k), y: Int((CGFloat(y) + 0.5 - frame.minY) * k))?.alphaComponent ?? 0
                    let c = TL.pixel(x, y)
                    total += 1
                    if (lv > 0.5) == (c.a > 128) { agree += 1 }
                    if c.a > 200 && c.r > 230 { white += 1 }
                    if c.a > 200 && c.r < 25 { black += 1 }
                }
            }
            let ratio = Double(agree) / Double(max(1, total))
            check(ratio > 0.97, String(format: "committed text matches the live editor (%.1f%% of samples)", ratio * 100))
            check(white > 150 && black > 150, "meme text has a white fill and a black outline (\(white) white, \(black) black)")
            png(doc.composite(), "02-text.png")

            // Click the text again: it reopens with its own style, and edits update the same layer.
            st.fontSize = 20; st.primary = .black
            stroke(.text, [CGPoint(x: frame.maxX - 6, y: frame.midY)])
            check(eng.text != nil && st.fontSize == 80 && st.primary == .white, "clicking text reopens it with its style")
            check(TL.pixel(Int(frame.midX), Int(frame.midY)).a == 0, "the layer hides while its text is being edited")
            eng.text?.view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
            eng.finishText()
            check(TL.text?.string == "EASEL!" && doc.history.last?.name == "Edit Text" && doc.layers.count == layersBefore + 1,
                  "editing updates the same text layer (\(TL.text?.string ?? "nil"))")
            doc.undo()
            check(doc.activeLayer.text?.string == "EASEL", "undo restores the previous text")
            doc.redo()
            TL = doc.activeLayer

            // Move tool on a text layer moves the text itself; a corner handle resizes the font.
            let a0 = TL.text!.anchor, tf = TextEditor.frame(of: TL.text!)
            stroke(.moveSelected, [CGPoint(x: tf.midX, y: tf.midY), CGPoint(x: tf.midX + 30, y: tf.midY - 50)])
            check(TL.text?.anchor == CGPoint(x: a0.x + 30, y: a0.y - 50) && doc.history.last?.name == "Move Text",
                  "Move Selected Pixels moves a text layer's text")
            let tf2 = TextEditor.frame(of: TL.text!)
            check(eng.cursor(at: CGPoint(x: tf2.maxX, y: tf2.maxY)) !== Cursors.movePixels, "text layers show resize handles")
            stroke(.moveSelected, [CGPoint(x: tf2.maxX, y: tf2.maxY), CGPoint(x: tf2.maxX + tf2.width * 0.25, y: tf2.maxY + 20)])
            check((TL.text?.fontSize ?? 0) > 90 && TL.text != nil && doc.history.last?.name == "Resize Text",
                  "a corner handle resizes the text, still editable (size \(TL.text?.fontSize ?? 0))")

            // Clicking off the text with the Move tool lets go of it and moves what is under the pointer.
            let specBefore = TL.text, textIdx = doc.active
            let bgIdx = doc.layers.lastIndex { $0.visible && $0.text == nil && $0.pixel(480, 120).a > 8 }
            stroke(.moveSelected, [CGPoint(x: 480, y: 120), CGPoint(x: 485, y: 120)])
            check(TL.text == specBefore && doc.active == bgIdx && doc.active != textIdx,
                  "clicking the drawing with Move picks the drawing's layer and leaves the text alone")
            doc.undo()
            doc.active = textIdx
            TL = doc.activeLayer

            // Saved text layers reopen editable.
            let tfile = dir.appendingPathComponent("text.sooth")
            try? doc.save(to: tfile, format: .sooth)
            let back = try? Document.load(url: tfile)
            check(back?.layers.last?.text == TL.text, ".sooth files keep text layers editable")

            // Painting on a text layer turns it into pixels.
            st.primary = .black; st.brushWidth = 6
            stroke(.brush, [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 20)])
            check(TL.text == nil, "painting on a text layer turns it into ordinary pixels")
            doc.undo()
            check(doc.activeLayer.text != nil, "undo brings back the editable text")
        } else {
            check(false, "text tool opens a live text box")
        }
        st.outlineWidth = 0; st.textAlign = .left; st.primary = .black
        while doc.layers.count > layersBefore { doc.active = doc.layers.count - 1; doc.deleteLayer() }
        doc.active = 0; doc.commit("Delete Layer", symbol: "minus", touch: .none)

        // Text presets: every look must render the same in the live editor and in the committed layer.
        let pdoc = Document(width: 900, height: 260, background: .white)
        pdoc.layers[0].ctx.drawLinearGradient(CGGradient(colorsSpace: sRGBSpace,
            colors: [RGBA(r: 90, g: 140, b: 210).cg, RGBA(r: 250, g: 200, b: 150).cg] as CFArray, locations: [0, 1])!,
            start: .zero, end: CGPoint(x: 900, y: 260), options: [])
        let pc = EditorWindowController(doc: pdoc)
        if let pw = pc.window, let pv = pw.contentView {
            pw.setContentSize(NSSize(width: 1320, height: 860)); pv.layoutSubtreeIfNeeded(); pc.setZoom(1)
            let pe = pc.canvas.engine, cv = pc.canvas!
            var shots: [CGImage] = []
            func capture() -> NSBitmapImageRep {
                // At 1×, the image's own resolution, so live text and committed pixels are comparable.
                cv.needsDisplay = true
                let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cv.bounds.width), pixelsHigh: Int(cv.bounds.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                r.size = cv.bounds.size
                cv.cacheDisplay(in: cv.bounds, to: r)
                return r
            }
            for preset in TextPreset.allCases {
                preset.apply(st, imageWidth: 900)
                st.tool = .text
                pe.down(CGPoint(x: 450, y: 70), right: false, flags: []); pe.up(CGPoint(x: 450, y: 70), flags: [])
                for ch in preset.rawValue.uppercased() + " TEXT" {
                    pe.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
                }
                let live = capture()
                pe.finishText()
                let done = capture()
                try? live.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("live-\(preset.rawValue).png"))
                try? done.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("done-\(preset.rawValue).png"))
                guard let spec = pdoc.activeLayer.text else { check(false, "\(preset.rawValue) makes a text layer"); continue }
                let ink = TextEditor.frame(of: spec).insetBy(dx: 10, dy: 10).intersection(pdoc.fullRect)
                let k = CGFloat(live.pixelsWide) / cv.bounds.width
                var same = 0, total = 0
                for y in stride(from: Int(ink.minY), to: Int(ink.maxY), by: 2) {
                    for x in stride(from: Int(ink.minX), to: Int(ink.maxX), by: 2) {
                        guard let a = live.colorAt(x: Int(CGFloat(x) * k), y: Int(CGFloat(y) * k))?.usingColorSpace(.sRGB),
                              let b = done.colorAt(x: Int(CGFloat(x) * k), y: Int(CGFloat(y) * k))?.usingColorSpace(.sRGB) else { continue }
                        total += 1
                        let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                        if d < 0.2 { same += 1 }
                    }
                }
                let ratio = Double(same) / Double(max(1, total))
                check(ratio > 0.93, String(format: "%@ preset looks the same live and committed (%.1f%%)", preset.rawValue, ratio * 100))
                if let cg = done.cgImage { shots.append(cg) }
                pdoc.deleteLayer(); pdoc.commit("Delete", symbol: "x", touch: .none)
            }
            // A contact sheet of the presets, for eyeballing.
            if let first = shots.first {
                let sheet = Layer(width: first.width, height: first.height * shots.count, name: "")
                for (i, img) in shots.enumerated() { sheet.drawImage(img, at: CGPoint(x: 0, y: i * first.height)) }
                png(sheet.image(), "03-text-presets.png")
            }
        }
        TextPreset.chrome.apply(st, imageWidth: 900)
        let fxp = TextEffectsPanel.shared
        if let v = fxp.contentView {
            fxp.appearance = NSAppearance(named: .darkAqua)
            v.layoutSubtreeIfNeeded()
            if let doc = (v as? NSScrollView)?.documentView, let r = doc.bitmapImageRepForCachingDisplay(in: doc.bounds) {
                doc.cacheDisplay(in: doc.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("04-effects-panel.png"))
            }
        }
        st.textEffects = TextSpec(); st.outlineWidth = 0; st.textShadow = false; st.textAlign = .left; st.primary = .black
        st.secondary = .white; st.bold = false; st.italic = false; st.fontSize = 36

        // Shape gallery, for eyeballing: every kind, in the three fill styles.
        do {
            let g = Layer(width: 9 * 120, height: 3 * 110, name: "")
            g.fill(.white)
            for (row, style) in FillStyle.allCases.enumerated() {
                for (col, kind) in ShapeKind.allCases.enumerated() {
                    let sp = ShapeSpec(kind: kind, frame: CGRect(x: col * 120 + 14, y: row * 110 + 14, width: 92, height: 82), style: style,
                                       width: 5, primary: RGBA(r: 25, g: 25, b: 40), secondary: RGBA(r: 255, g: 205, b: 60), antialias: true)
                    let tmp = Layer(width: g.width, height: g.height, name: "")
                    sp.render(into: tmp)
                    g.ctx.draw(tmp.image(), in: g.rect)
                }
            }
            png(g.image(), "09-shapes.png")
        }

        // Object layers (pasted / imported images): move, resize and rotate without losing quality.
        do {
            let odoc = Document(width: 500, height: 400, background: .white)
            let oc = EditorWindowController(doc: odoc)
            let oe = oc.canvas.engine
            let card = Layer(width: 120, height: 90, name: "")
            card.ctx.drawLinearGradient(CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 250, g: 60, b: 90).cg, RGBA(r: 20, g: 90, b: 240).cg] as CFArray, locations: [0, 1])!,
                                        start: .zero, end: CGPoint(x: 120, y: 90), options: [])
            card.ctx.setFillColor(.black); card.ctx.fill(CGRect(x: 10, y: 10, width: 6, height: 6))
            let L2 = Layer(width: 500, height: 400, name: "Card")
            L2.object = ObjectSpec(source: card.image(), center: CGPoint(x: 160, y: 145))
            L2.object!.render(into: L2)
            odoc.addLayer(L2); odoc.commit("Paste", symbol: "x", touch: .none)
            func ostroke(_ pts: [CGPoint], right: Bool = false, flags: NSEvent.ModifierFlags = []) {
                st.tool = .moveSelected
                oe.down(pts[0], right: right, flags: flags)
                for q in pts.dropFirst() { oe.drag(q, flags: flags) }
                oe.up(pts.last!, flags: flags)
            }
            let before = (0..<90).map { y in (0..<120).map { x in L2.pixel(100 + x, 100 + y) } }
            ostroke([CGPoint(x: 160, y: 145), CGPoint(x: 210, y: 175)])
            check(odoc.activeLayer.object?.center == CGPoint(x: 210, y: 175) && odoc.history.last?.name == "Move Layer",
                  "clicking an object layer and dragging moves it")
            var O = odoc.activeLayer
            // corner out to 3×, then back: exactly the original pixels again
            let br = CGPoint(x: 210 + 60, y: 175 + 45)
            ostroke([br, CGPoint(x: 210 + 180, y: 175 + 135)], flags: .shift)
            check(abs((O.object?.sx ?? 0) - 2) < 0.05, "a corner handle resizes the object (×\(O.object?.sx ?? 0))")
            O = odoc.activeLayer
            let br3 = O.object!.session.point(1, 1)
            ostroke([br3, CGPoint(x: 210 + 60 - 120, y: 175 + 45 - 90)], flags: .shift)   // drag back past to shrink
            if var o = O.object { o.sx = 1; o.sy = 1; o.center = CGPoint(x: 160, y: 145); O.object = o; o.render(into: O) }
            let after = (0..<90).map { y in (0..<120).map { x in O.pixel(100 + x, 100 + y) } }
            check(before == after, "resizing an object and putting it back is lossless")
            ostroke([CGPoint(x: 230, y: 145), CGPoint(x: 230, y: 185)], right: true, flags: .shift)
            check(abs(abs(O.object?.angle ?? 0) - .pi / 4) < 0.01 || abs(O.object?.angle ?? 0) > 0.1, "right-drag rotates the object")
            // save / reopen keeps it an object
            let ofile = dir.appendingPathComponent("object.sooth")
            try? odoc.save(to: ofile, format: .sooth)
            let back = try? Document.load(url: ofile)
            check(back?.layers.last?.object?.center == odoc.activeLayer.object?.center, ".sooth files keep object layers live")
            st.primary = .black; st.brushWidth = 6; st.tool = .brush
            oe.down(CGPoint(x: 160, y: 145), right: false, flags: []); oe.up(CGPoint(x: 160, y: 145), flags: [])
            check(odoc.activeLayer.object == nil, "painting on an object layer turns it into pixels")
        }

        // Subjects: lift a figure out of a flat picture into its own layer, and tune a cut-out.
        do {
            let sdoc = Document(width: 600, height: 400, background: RGBA(r: 140, g: 190, b: 242))
            let c = sdoc.layers[0].ctx   // y-up drawing, as in a photo
            c.setFillColor(RGBA(r: 50, g: 150, b: 64).cg); c.fill(CGRect(x: 0, y: 0, width: 600, height: 80))
            c.setFillColor(RGBA(r: 255, g: 216, b: 178).cg); c.fillEllipse(in: CGRect(x: 250, y: 230, width: 100, height: 100))
            c.setFillColor(RGBA(r: 230, g: 76, b: 128).cg); c.fill(CGRect(x: 255, y: 90, width: 90, height: 145))
            c.setFillColor(RGBA(r: 50, g: 50, b: 100).cg); c.fill(CGRect(x: 265, y: 60, width: 25, height: 40)); c.fill(CGRect(x: 310, y: 60, width: 25, height: 40))
            sdoc.layers[0].touch()
            let sc = EditorWindowController(doc: sdoc)
            let body = CGPoint(x: 300, y: 240)   // image coords (y down): the pink body
            let bodyColor = sdoc.layers[0].pixel(300, 240)
            st.tool = .magicWand; st.wandSubject = true; st.sampleImage = false
            sc.canvas.engine.down(body, right: false, flags: []); sc.canvas.engine.up(body, flags: [])
            let sb2 = sdoc.selection?.bounds ?? .zero
            check(sb2.minX > 230 && sb2.maxX < 370 && sb2.height > 200, "Magic Wand in Subject mode selects the figure (\(sb2))")
            st.wandSubject = false
            sdoc.selection = nil; sdoc.commit("Deselect", symbol: "x", touch: .none)
            sc.liftSubject(at: body, keepOriginal: false)
            let deadline = Date().addingTimeInterval(20)
            while sdoc.history.last?.name != "Lift Subject" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            check(sdoc.history.last?.name == "Lift Subject" && sdoc.layers.count == 2 && sdoc.activeLayer.object?.cutout != nil,
                  "double-click lifts the subject into its own object layer")
            if sdoc.layers.count == 2 {
                let gap = sdoc.layers[0].pixel(300, 180)
                check(gap.a > 250 && abs(Int(gap.b) - 242) < 30 && abs(Int(gap.r) - 140) < 30 && sdoc.layers[1].pixel(300, 240) == bodyColor,
                      "the subject moves to its own layer and the gap behind it is filled (\(gap))")
                check(sdoc.layers[1].pixel(40, 40).a == 0, "the lifted layer holds only the subject")
                let se = sc.canvas.engine
                sc.setZoom(0.05)   // far zoomed out: the middle must still grab, not a handle
                st.tool = .moveSelected
                se.down(body, right: false, flags: []); se.drag(CGPoint(x: 420, y: 240), flags: []); se.up(CGPoint(x: 420, y: 240), flags: [])
                check(sdoc.layers[1].pixel(420, 240) == bodyColor && sdoc.history.last?.name == "Move Layer", "the lifted subject drags freely")
                // Eraser edits the cut-out's mask (left erases, right restores); nothing is lost.
                sdoc.active = 1
                st.brushWidth = 30; st.brushHardness = 1; st.brushOpacity = 1
                let spot = CGPoint(x: 420, y: 200)
                st.tool = .eraser
                se.down(spot, right: false, flags: []); se.up(spot, flags: [])
                let erased = sdoc.layers[1].pixel(420, 200)
                check(erased.a < 10 && sdoc.layers[1].object != nil && sdoc.history.last?.name == "Erase Mask",
                      "the eraser on a cut-out erases its mask and keeps it live")
                se.down(spot, right: true, flags: []); se.up(spot, flags: [])
                check(sdoc.layers[1].pixel(420, 200) == bodyColor && sdoc.history.last?.name == "Restore Mask",
                      "right-drag with the eraser restores the original pixels")
                if var o = sdoc.layers[1].object, let cut = o.cutout {
                    func opaque(_ c: Cutout) -> Int { ObjectSpec.mask(c, width: o.source.width, height: o.source.height).filter { $0 > 128 }.count }
                    var grown = cut; grown.grow = 6
                    var strong = cut; strong.strength = 95
                    check(opaque(grown) > opaque(cut) && opaque(strong) <= opaque(cut), "grow and strength move the cut-out edge the right way")
                    o.cutout = grown; sdoc.layers[1].object = o
                }
            }
            png(sdoc.composite(), "08-lift-subject.png")
            png(sdoc.layers[0].image(), "08b-background-after-lift.png")
        }

        // Dropping an image file adds a movable layer centred where it was dropped; lines can have arrowheads.
        do {
            let ddoc = Document(width: 300, height: 200, background: .white)
            let dc = EditorWindowController(doc: ddoc)
            let chip = Layer(width: 40, height: 30, name: ""); chip.fill(RGBA(r: 200, g: 30, b: 160))
            let f = dir.appendingPathComponent("drop.png")
            try? Document.encode(chip.image(), as: .png).write(to: f)
            dc.importLayer(from: f, at: CGPoint(x: 200, y: 50))
            check(ddoc.layers.count == 2 && ddoc.activeLayer.object != nil && ddoc.activeLayer.pixel(200, 50) == RGBA(r: 200, g: 30, b: 160)
                  && ddoc.activeLayer.pixel(150, 50).a == 0, "a dropped image becomes a movable layer where it was dropped")
            ddoc.active = 0
            st.tool = .line; st.arrowEnd = true; st.primary = .black; st.brushWidth = 4
            let de = dc.canvas.engine
            de.down(CGPoint(x: 20, y: 150), right: false, flags: []); de.drag(CGPoint(x: 120, y: 150), flags: []); de.up(CGPoint(x: 120, y: 150), flags: [])
            let headPx = ddoc.layers[0].pixel(108, 154), shaftPx = ddoc.layers[0].pixel(60, 154)
            check(headPx.r < 60 && shaftPx.r > 200, "the line tool draws an arrowhead wider than its shaft")
            st.arrowEnd = false
        }

        // Curves: an S-curve adds contrast, a red-only curve leaves green and blue alone.
        do {
            let sCurve = [CGPoint(x: 0, y: 0), CGPoint(x: 64, y: 40), CGPoint(x: 192, y: 215), CGPoint(x: 255, y: 255)]
            let t = Curves.table(sCurve)
            check(t[64] < 64 && t[192] > 192 && zip(t, t.dropFirst()).allSatisfy { $0 <= $1 }, "an S-curve darkens shadows and lifts highlights, never folding back")
            let px = Layer(width: 2, height: 1, name: "")
            px.ctx.setFillColor(RGBA(r: 100, g: 100, b: 100).cg); px.ctx.fill(px.rect)
            let out = Layer(width: 2, height: 1, name: "")
            let line = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
            let v = Curves.encode(mode: .red, curves: [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 200), CGPoint(x: 255, y: 255)], line, line])
            px.data().withUnsafeBytes { raw in
                Curves.filter.run(FilterIO(src: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), dst: out.bytes, w: 2, h: 1, primary: .black, secondary: .white), v)
            }
            let o = out.pixel(0, 0)
            check(o.r > 180 && o.g == 100 && o.b == 100, "a Red curve changes only red (\(o))")
            let (m2, c2) = Curves.decode(v)
            check(m2 == .red && c2[0].count == 3, "Curves settings round-trip for Repeat Last Effect")
            let cv = CurveView(frame: NSRect(x: 0, y: 0, width: 280, height: 280))
            cv.points = sCurve; cv.appearance = NSAppearance(named: .darkAqua)
            if let r = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) {
                cv.cacheDisplay(in: cv.bounds, to: r)
                try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("11-curves.png"))
            }
        }

        // Content-aware fill: a hole in a textured picture comes back close to the truth.
        do {
            let W = 320, H = 220
            let truth = Layer(width: W, height: H, name: "")
            truth.ctx.drawLinearGradient(CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 120, g: 170, b: 230).cg, RGBA(r: 250, g: 210, b: 160).cg] as CFArray, locations: [0, 1])!,
                                         start: .zero, end: CGPoint(x: 0, y: H), options: [])
            for i in 0..<14 { truth.ctx.setFillColor(RGBA(r: 40, g: 110, b: 60).cg); truth.ctx.fill(CGRect(x: i * 24, y: 0, width: 8, height: 60)) }
            let work = truth.duplicate()
            var mask = [UInt8](repeating: 0, count: W * H)
            // the hole cuts through the stripes, so the fill has to continue them
            for y in 130..<200 { for x in 120..<200 { mask[y * W + x] = 255; for c in 0..<4 { work.bytes[(y * W + x) * 4 + c] = 0 } } }
            let t0 = Date()
            Inpaint.fill(work.bytes, width: W, height: H, mask: mask)
            let ms = Date().timeIntervalSince(t0) * 1000
            var err = 0.0, n = 0.0, transparent = 0
            for y in 130..<200 { for x in 120..<200 {
                let a = work.pixel(x, y), b = truth.pixel(x, y)
                if a.a < 250 { transparent += 1 }
                err += Double(abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b))) / 3; n += 1
            } }
            check(transparent == 0 && err / n < 25, String(format: "content-aware fill continues texture through a hole (mean error %.1f, %.0f ms)", err / n, ms))
            png(work.image(), "10-inpaint.png")
        }

        // Fixed-ratio and fixed-size selections; Auto-Crop.
        do {
            let xdoc = Document(width: 400, height: 300, background: nil)
            xdoc.layers[0].ctx.setFillColor(RGBA(r: 0, g: 100, b: 200).cg)
            xdoc.layers[0].ctx.fill(CGRect(x: 50, y: 60, width: 120, height: 80)); xdoc.layers[0].touch()
            let xc = EditorWindowController(doc: xdoc), xe = xc.canvas.engine
            st.tool = .rectSelect; st.selectMode = .replace
            st.selectShape = 1; st.selectW = 16; st.selectH = 9
            xe.down(CGPoint(x: 10, y: 10), right: false, flags: []); xe.drag(CGPoint(x: 170, y: 40), flags: []); xe.up(CGPoint(x: 170, y: 40), flags: [])
            let b1 = xdoc.selection?.bounds ?? .zero
            check(abs(b1.width / b1.height - 16.0 / 9) < 0.03, "Fixed Ratio keeps 16:9 (\(b1))")
            st.selectShape = 2; st.selectW = 100; st.selectH = 50
            xe.down(CGPoint(x: 200, y: 150), right: false, flags: []); xe.up(CGPoint(x: 200, y: 150), flags: [])
            check(xdoc.selection?.bounds == CGRect(x: 150, y: 125, width: 100, height: 50), "Fixed Size selects exactly 100 × 50")
            st.selectShape = 0
            xdoc.selection = nil
            xc.autoCrop(nil)
            check(xdoc.width == 120 && xdoc.height == 80, "Auto-Crop trims the transparent edges (\(xdoc.width)×\(xdoc.height))")
        }

        // Bugs found 2026-10-11: a stroke on a new layer shows at once; Esc mid-drag puts a live layer back;
        // arrow keys move text without turning it into pixels.
        do {
            let gdoc = Document(width: 200, height: 120, background: .white)
            let gc = EditorWindowController(doc: gdoc), ge = gc.canvas.engine
            _ = gdoc.composite()   // caches the empty layer's bounds, as the screen would
            gc.addLayer(nil)
            _ = gdoc.composite()
            st.tool = .brush; st.primary = RGBA(r: 220, g: 20, b: 20); st.brushWidth = 10; st.brushOpacity = 1; st.brushHardness = 1
            ge.down(CGPoint(x: 40, y: 60), right: false, flags: []); ge.drag(CGPoint(x: 160, y: 60), flags: [])
            let mid = Layer.from(image: gdoc.composite(), name: "").pixel(100, 60)
            check(mid.r > 200 && mid.g < 60, "a stroke on a new layer shows while drawing (\(mid))")
            ge.up(CGPoint(x: 160, y: 60), flags: [])
            let after = Layer.from(image: gdoc.composite(), name: "").pixel(100, 60)
            check(after.r > 200 && after.g < 60, "and after the mouse comes up")

            let chip = Layer(width: 30, height: 30, name: ""); chip.fill(RGBA(r: 10, g: 200, b: 10))
            gc.addImageLayer(chip.image(), named: "Chip", at: CGPoint(x: 50, y: 50))
            let objIdx = gdoc.active, c0 = gdoc.activeLayer.object!.center
            st.tool = .moveSelected
            ge.down(CGPoint(x: 50, y: 50), right: false, flags: []); ge.drag(CGPoint(x: 120, y: 80), flags: [])
            ge.cancel()
            check(gdoc.layers[objIdx].object?.center == c0 && gdoc.layers[objIdx].pixel(50, 50) == RGBA(r: 10, g: 200, b: 10)
                  && gdoc.layers[objIdx].pixel(120, 80).a == 0, "Esc during a layer drag puts it back")
            gdoc.active = 0
            ge.down(CGPoint(x: 100, y: 100), right: false, flags: []); ge.drag(CGPoint(x: 110, y: 100), flags: []); ge.up(CGPoint(x: 110, y: 100), flags: [])
            check(gdoc.layers[0].object == nil, "the next drag doesn't inherit the cancelled one")

            st.tool = .text; st.textEffects = TextSpec(); st.fontSize = 24; st.primary = .black; st.outlineWidth = 0
            ge.down(CGPoint(x: 20, y: 20), right: false, flags: []); ge.up(CGPoint(x: 20, y: 20), flags: [])
            for ch in "Hi" { ge.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            ge.finishText()
            let a0 = gdoc.activeLayer.text?.anchor
            st.tool = .moveSelected
            ge.nudge(1, 0)
            check(gdoc.activeLayer.text != nil && gdoc.activeLayer.text?.anchor.x == (a0?.x ?? 0) + 1, "arrow keys move text and keep it editable")
        }

        // The Library: keep things, bring them back into another image (text stays text).
        do {
            Library.folder = dir.appendingPathComponent("library", isDirectory: true)
            Library.useTrash = false
            try? FileManager.default.removeItem(at: Library.folder)
            try? FileManager.default.createDirectory(at: Library.folder, withIntermediateDirectories: true)
            let ldoc = Document(width: 200, height: 120, background: .white)
            let lc = EditorWindowController(doc: ldoc), le = lc.canvas.engine
            st.tool = .text; st.textEffects = TextSpec(); st.fontSize = 30; st.primary = .black; st.outlineWidth = 0
            le.down(CGPoint(x: 20, y: 20), right: false, flags: []); le.up(CGPoint(x: 20, y: 20), flags: [])
            for ch in "Keep" { le.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            le.finishText()
            lc.addToLibrary(nil)
            ldoc.active = 0
            ldoc.selection = Selection.path(CGPath(rect: CGRect(x: 100, y: 60, width: 30, height: 20), transform: nil), width: 200, height: 120, antialias: false)
            ldoc.layers[0].fill(RGBA(r: 0, g: 150, b: 60)); ldoc.layers[0].touch()
            lc.addToLibrary(nil)
            let items = Library.items()
            check(items.count == 2 && items.contains { $0.kind == "text" } && items.contains { $0.kind == "picture" } && items.allSatisfy { $0.thumbnail != nil },
                  "Add to Library keeps a text layer (live) and a selected part (pixels), with thumbnails")
            let other = Document(width: 300, height: 200, background: .white)
            let oc = EditorWindowController(doc: other)
            let textItem = items.first { $0.kind == "text" }!, picItem = items.first { $0.kind == "picture" }!
            oc.insertLibraryItem(textItem.url, at: CGPoint(x: 150, y: 100))
            check(other.activeLayer.text?.string == "Keep" && TextEditor.frame(of: other.activeLayer.text!).contains(CGPoint(x: 150, y: 100)),
                  "a kept text comes back as editable text where it's placed")
            oc.insertLibraryItem(picItem.url, at: CGPoint(x: 50, y: 50))
            check(other.activeLayer.object != nil && other.activeLayer.pixel(50, 50) == RGBA(r: 0, g: 150, b: 60)
                  && other.activeLayer.pixel(70, 50).a == 0, "a kept picture comes back as a movable picture (30×20)")
            Library.rename(picItem.url, to: "Green")
            check(Library.items().contains { $0.name == "Green" }, "things can be renamed")
            let panel = LibraryPanel.shared
            if let v = panel.contentView {
                panel.setContentSize(NSSize(width: 420, height: 300)); v.layoutSubtreeIfNeeded()
                (v.subviews.last as? NSScrollView).flatMap { $0.documentView as? LibraryGrid }?.reload()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("12-library.png"))
                }
            }
            Library.remove(picItem.url)
            check(Library.items().count == 1, "and removed")
        }

        // Vectorize: a drawn circle becomes sharp vector art that scales cleanly and saves.
        do {
            let vdoc = Document(width: 200, height: 160, background: .white)
            let vc = EditorWindowController(doc: vdoc)
            vc.addLayer(nil)
            let L = vdoc.activeLayer
            L.ctx.setFillColor(RGBA(r: 220, g: 40, b: 120).cg); L.ctx.fillEllipse(in: CGRect(x: 50, y: 40, width: 100, height: 80)); L.touch()
            Dialogs.testValues = [4, 1, 0.5]
            vc.vectorize(nil)
            Dialogs.testValues = nil
            let until = Date().addingTimeInterval(20)
            while vdoc.history.last?.name != "Vectorize" && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let vl = vdoc.activeLayer
            check(vl.object?.vector.map { !$0.regions.isEmpty } == true && !L.visible, "Vectorize makes a vector layer and hides the original")
            let inside = vdoc.compositePixel(100, 80)
            check(abs(Int(inside.r) - 220) < 12 && abs(Int(inside.g) - 40) < 12 && vdoc.compositePixel(10, 10) == .white,
                  "the traced shape has the drawing's colour, and nothing outside it (\(inside))")
            if var o = vl.object {
                o.sx = 8; o.sy = 8
                let big = Layer(width: 1000, height: 1000, name: "")
                o.center = CGPoint(x: 500, y: 500)
                o.render(into: big)
                // Sharp at 8×: across the edge it goes from shape to clear within a couple of pixels.
                var row: [UInt8] = []
                for x in 0..<1000 { row.append(big.pixel(x, 500).a) }
                let edge = row.firstIndex { $0 > 0 } ?? 0
                let solid = row.firstIndex { $0 == 255 } ?? 0
                check(edge > 0 && solid - edge <= 3, "scaled 8×, its edge stays crisp (\(solid - edge) px ramp)")
            }
            let vf = dir.appendingPathComponent("vector.sooth")
            try? vdoc.save(to: vf, format: .sooth)
            check((try? Document.load(url: vf))?.layers.last?.object?.vector?.regions.count == vl.object?.vector?.regions.count,
                  "vector art survives saving and opening")
            check(vl.object?.vector?.svg().contains("<path") == true, "and exports as SVG")
        }

        // Layer masks and adjustment layers.
        do {
            let mdoc = Document(width: 100, height: 50, background: .white)
            let mc = EditorWindowController(doc: mdoc), me = mc.canvas.engine
            mc.addLayer(nil); mdoc.activeLayer.fill(RGBA(r: 200, g: 0, b: 0)); mdoc.commit("Fill", symbol: "x")
            mdoc.selection = Selection.path(CGPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50), transform: nil), width: 100, height: 50, antialias: false)
            mc.addLayerMask(nil)
            func px(_ x: Int, _ y: Int) -> RGBA { mdoc.compositePixel(x, y) }
            check(mdoc.activeLayer.mask != nil && mdoc.editingMask && px(10, 25) == RGBA(r: 200, g: 0, b: 0) && px(80, 25) == .white,
                  "a mask from a selection shows the layer only there")
            st.tool = .brush; st.primary = .black; st.brushWidth = 8; st.brushOpacity = 1; st.brushHardness = 1
            me.down(CGPoint(x: 20, y: 25), right: false, flags: []); me.up(CGPoint(x: 20, y: 25), flags: [])
            check(px(20, 25) == .white && mdoc.activeLayer.pixel(20, 25) == RGBA(r: 200, g: 0, b: 0),
                  "painting black on the mask hides the layer there, and leaves its pixels alone")
            mdoc.undo()
            check(px(20, 25) == RGBA(r: 200, g: 0, b: 0), "undo takes the mask stroke back")
            let mf = dir.appendingPathComponent("masked.sooth")
            try? mdoc.save(to: mf, format: .sooth)
            let back = try? Document.load(url: mf)
            check(back?.layers[1].mask != nil && back?.compositePixel(80, 25) == .white && back?.compositePixel(10, 25) == RGBA(r: 200, g: 0, b: 0),
                  "masks survive saving and opening")
            mc.applyLayerMask(nil)
            check(mdoc.activeLayer.mask == nil && mdoc.activeLayer.pixel(80, 25).a == 0 && px(10, 25) == RGBA(r: 200, g: 0, b: 0),
                  "Apply Layer Mask erases the hidden part for good")

            let adoc = Document(width: 60, height: 40, background: .white)
            let ac = EditorWindowController(doc: adoc), ae = ac.canvas.engine
            ac.newAdjustmentLayer(AdjustmentSpec.filters.first { $0.name == "Invert Colors" }!)
            check(adoc.layers.count == 2 && adoc.compositePixel(30, 20) == .black && adoc.layers[0].pixel(30, 20) == .white,
                  "an Invert adjustment layer changes the look, not the pixels below")
            ae.down(CGPoint(x: 10, y: 10), right: false, flags: []); ae.up(CGPoint(x: 10, y: 10), flags: [])
            check(adoc.compositePixel(10, 10) == .white && adoc.compositePixel(40, 20) == .black, "painting it black keeps it off there")
            adoc.activeLayer.opacity = 0.5; adoc.structureChanged()
            let half = adoc.compositePixel(40, 20)
            check(abs(Int(half.r) - 128) < 3, "its opacity sets how strongly it applies (\(half))")
            adoc.activeLayer.opacity = 1; adoc.structureChanged()
            Dialogs.testValues = [60, 0]
            ac.newAdjustmentLayer(AdjustmentSpec.filters.first { $0.name == "Brightness / Contrast" }!)
            check(adoc.activeLayer.adjustment?.values == [60, 0], "a new adjustment layer keeps its settings")
            Dialogs.testValues = [-60, 0]
            ac.editAdjustment(nil)
            check(adoc.activeLayer.adjustment?.values == [-60, 0], "and they can be changed later")
            Dialogs.testValues = nil
            adoc.undo()
            check(adoc.activeLayer.adjustment?.values == [60, 0], "undo puts the old settings back")
            let af = dir.appendingPathComponent("adjust.sooth")
            try? adoc.save(to: af, format: .sooth)
            let aback = try? Document.load(url: af)
            check(aback?.layers.last?.adjustment == adoc.activeLayer.adjustment && aback?.compositePixel(40, 20) == adoc.compositePixel(40, 20),
                  "adjustment layers survive saving and opening")
            if let w = ac.window, let v = w.contentView {   // for eyeballing the layers panel
                w.setContentSize(NSSize(width: 1100, height: 820)); v.layoutSubtreeIfNeeded(); ac.structureChanged()
                w.setFrameOrigin(NSPoint(x: -30000, y: -30000)); w.orderFrontRegardless()
                RunLoop.main.run(until: Date().addingTimeInterval(0.2)); v.displayIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("13-adjustment-layers.png"))
                }
                w.orderOut(nil)
            }
            adoc.active = 1; adoc.mergeDown()
            check(adoc.layers.count == 2 && adoc.layers[0].pixel(40, 20) == .black && adoc.layers[0].pixel(10, 10) == .white,
                  "merging an adjustment down applies it to the pixels")
            adoc.canvasSize(width: 80, height: 40, anchorX: 0, anchorY: 0, fill: .white)
            check(adoc.layers[1].adjustment != nil && adoc.layers[1].pixel(75, 20) == .white, "a bigger canvas extends where adjustments apply")
            st.tool = .brush
        }

        // Click off to deselect; drag the canvas's own handles to resize it.
        do {
            let kdoc = Document(width: 200, height: 100, background: .white)
            let kc = EditorWindowController(doc: kdoc), ke = kc.canvas.engine, kv = kc.canvas!
            if let w = kc.window { w.setContentSize(NSSize(width: 1000, height: 820)); w.contentView?.layoutSubtreeIfNeeded() }
            kc.setZoom(1)
            let chip = Layer(width: 40, height: 40, name: ""); chip.fill(RGBA(r: 200, g: 10, b: 10))
            kc.addImageLayer(chip.image(), named: "Chip", at: CGPoint(x: 40, y: 50))
            st.tool = .moveSelected
            ke.down(CGPoint(x: 160, y: 50), right: false, flags: []); ke.up(CGPoint(x: 160, y: 50), flags: [])
            check(ke.handlesHidden && kdoc.layers[0].pixel(160, 50) == .white && kdoc.layers.count == 2, "clicking off a picture deselects it (and moves nothing)")
            ke.down(CGPoint(x: 40, y: 50), right: false, flags: []); ke.up(CGPoint(x: 40, y: 50), flags: [])
            check(!ke.handlesHidden, "clicking it again selects it")
            kdoc.selection = Selection.path(CGPath(rect: CGRect(x: 100, y: 20, width: 40, height: 40), transform: nil),
                                            width: 200, height: 100, antialias: false)
            kdoc.commit("Select", symbol: "x", touch: .none)
            ke.down(CGPoint(x: 10, y: 90), right: false, flags: []); ke.up(CGPoint(x: 10, y: 90), flags: [])
            check(kdoc.selection == nil, "clicking off a selection with the Move tool deselects it")

            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: kv.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                                   windowNumber: kc.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let grip = CGPoint(x: 200 + 16, y: 50)   // right edge's handle, at 100%
            check(kv.canvasHandle(at: grip) != nil, "the canvas has a handle past its right edge")
            kv.mouseDown(with: mouse(.leftMouseDown, grip))
            kv.mouseDragged(with: mouse(.leftMouseDragged, grip + CGPoint(x: 100, y: 0)))
            check(kv.canvasPreview?.width == 300 && kdoc.width == 200, "dragging it previews the new size")
            kv.mouseUp(with: mouse(.leftMouseUp, grip + CGPoint(x: 100, y: 0)))
            check(kdoc.width == 300 && kdoc.height == 100, "letting go makes the canvas that size (\(kdoc.width)×\(kdoc.height))")
            check(kdoc.layers[0].pixel(280, 50) == .white, "a white page grows white, whatever the second colour is")
            let leftGrip = CGPoint(x: -16, y: 50)
            kv.mouseDown(with: mouse(.leftMouseDown, leftGrip))
            kv.mouseDragged(with: mouse(.leftMouseDragged, leftGrip - CGPoint(x: 50, y: 0)))
            kv.mouseUp(with: mouse(.leftMouseUp, leftGrip - CGPoint(x: 50, y: 0)))
            check(kdoc.width == 350 && kdoc.layers[1].object.map { abs($0.center.x - 90) < 1 } == true,
                  "growing to the left keeps the picture where it was (now 50 px further in)")
            kdoc.undo()
            check(kdoc.width == 300, "undo puts the canvas back")
            // For eyeballing: a picture hanging off the canvas shows faintly past the edge.
            let big = Layer(width: 160, height: 90, name: ""); big.fill(RGBA(r: 40, g: 120, b: 230))
            kc.addImageLayer(big.image(), named: "Off", at: CGPoint(x: 220, y: 50))
            st.tool = .moveSelected
            ke.down(CGPoint(x: 220, y: 50), right: false, flags: []); ke.drag(CGPoint(x: 300, y: 20), flags: []); ke.up(CGPoint(x: 300, y: 20), flags: [])
            check(kdoc.activeLayer.object.map { $0.extent.maxX > 300 } == true, "a picture can be dragged past the canvas edge")
            kc.setZoom(2)
            if let v = kc.window?.contentView {
                kc.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000)); kc.window?.orderFrontRegardless()
                v.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); v.displayIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("00-window-offcanvas.png"))
                }
                kc.window?.orderOut(nil)
            }
            st.tool = .brush
        }

        // An image bigger than the canvas asks first: a fresh blank canvas takes its size, a worked one grows to fit.
        do {
            let big = Layer(width: 1200, height: 500, name: ""); big.fill(RGBA(r: 20, g: 120, b: 220))
            let fdoc = Document(width: 800, height: 600, background: .white)
            let fc = EditorWindowController(doc: fdoc)
            Dialogs.testAnswer = 0
            fc.addImageLayer(big.image(), named: "Big", at: CGPoint(x: 700, y: 100))
            check(fdoc.width == 1200 && fdoc.height == 500 && fdoc.activeLayer.pixel(0, 0) == RGBA(r: 20, g: 120, b: 220)
                  && fdoc.activeLayer.pixel(1199, 499) == RGBA(r: 20, g: 120, b: 220), "a big image on a fresh canvas fits the canvas to it")
            fdoc.undo()
            check(fdoc.width == 800 && fdoc.height == 600, "undo puts the canvas size back")
            let tall = Layer(width: 300, height: 900, name: ""); tall.fill(.black)
            fdoc.dirty = true   // worked on now
            fc.addImageLayer(tall.image(), named: "Tall", at: nil)
            check(fdoc.width == 800 && fdoc.height == 900, "a worked canvas grows to fit (\(fdoc.width)×\(fdoc.height))")
            Dialogs.testAnswer = 2
            let n = fdoc.layers.count
            fc.addImageLayer(big.image(), named: "Big", at: nil)
            check(fdoc.layers.count == n && fdoc.width == 800, "Cancel adds nothing")
            Dialogs.testAnswer = 1
            fc.addImageLayer(big.image(), named: "Big", at: nil)
            check(fdoc.layers.count == n + 1 && fdoc.width == 800, "Keep Size adds it without touching the canvas")
            Dialogs.testAnswer = nil
        }

        // With a full-canvas image layer selected, clicking text on top of it grabs the text.
        do {
            let pdoc2 = Document(width: 300, height: 200, background: .white)
            let pc2 = EditorWindowController(doc: pdoc2), pe2 = pc2.canvas.engine
            pc2.setZoom(1)
            pc2.addImageLayer(Layer.from(image: pdoc2.layers[0].image(), name: "").image(), named: "Photo")
            st.textEffects = TextSpec(); st.fontSize = 30; st.primary = .black; st.outlineWidth = 0; st.textAlign = .left
            st.tool = .text
            pe2.down(CGPoint(x: 40, y: 40), right: false, flags: []); pe2.up(CGPoint(x: 40, y: 40), flags: [])
            for ch in "TOP" { pe2.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            pe2.finishText()
            let textIdx = pdoc2.active
            pdoc2.active = 1   // the photo object is selected
            st.tool = .moveSelected
            let tf = TextEditor.frame(of: pdoc2.layers[textIdx].text!)
            pe2.down(CGPoint(x: tf.midX, y: tf.midY), right: false, flags: []); pe2.drag(CGPoint(x: tf.midX + 30, y: tf.midY), flags: [])
            pe2.up(CGPoint(x: tf.midX + 30, y: tf.midY), flags: [])
            check(pdoc2.active == textIdx && pdoc2.history.last?.name == "Move Text", "text on top of a selected photo layer is what the Move tool grabs")
        }

        // Resizing and cropping keep text, shapes and images live and sharp.
        do {
            let rdoc = Document(width: 400, height: 200, background: .white)
            let rc = EditorWindowController(doc: rdoc), re = rc.canvas.engine
            st.textEffects = TextSpec(); TextPreset.meme.apply(st, imageWidth: 400)
            st.tool = .text
            re.down(CGPoint(x: 200, y: 20), right: false, flags: []); re.up(CGPoint(x: 200, y: 20), flags: [])
            for ch in "HI" { re.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            re.finishText()
            let size0 = rdoc.activeLayer.text?.fontSize ?? 0
            rdoc.resize(width: 800, height: 400, smooth: true); rdoc.commit("Resize", symbol: "x", touch: .none)
            check(rdoc.activeLayer.text?.fontSize == size0 * 2 && rdoc.activeLayer.text?.anchor == CGPoint(x: 400, y: 40),
                  "resizing the image scales text layers and keeps them editable")
            rdoc.crop(to: Selection.path(CGPath(rect: CGRect(x: 100, y: 0, width: 600, height: 300), transform: nil), width: 800, height: 400, antialias: false))
            rdoc.commit("Crop", symbol: "x", touch: .none)
            check(rdoc.activeLayer.text?.anchor == CGPoint(x: 300, y: 40), "cropping moves text layers with the picture")
            st.textEffects = TextSpec(); st.outlineWidth = 0; st.textAlign = .left; st.primary = .black; st.secondary = .white
        }

        // Gradient transparency mode fades the layer; diamond and conical shapes render.
        do {
            let gdoc = Document(width: 200, height: 100, background: RGBA(r: 200, g: 50, b: 50))
            let gc = EditorWindowController(doc: gdoc), ge = gc.canvas.engine
            st.tool = .gradient; st.gradient = .linear; st.gradientTransparency = true; st.primary = .black; st.secondary = .white
            ge.down(CGPoint(x: 0, y: 50), right: false, flags: []); ge.drag(CGPoint(x: 200, y: 50), flags: []); ge.up(CGPoint(x: 200, y: 50), flags: [])
            let a0 = gdoc.layers[0].pixel(5, 50).a, a1 = gdoc.layers[0].pixel(100, 50).a, a2 = gdoc.layers[0].pixel(195, 50).a
            check(a0 > 240 && a1 > 100 && a1 < 160 && a2 < 15 && abs(Int(gdoc.layers[0].pixel(100, 50).r) - 200) <= 2,
                  "Transparency gradient fades the layer out, keeping its colour (\(a0) → \(a1) → \(a2))")
            st.gradientTransparency = false
            for kind in [GradientKind.diamond, .conical] {
                st.gradient = kind
                ge.down(CGPoint(x: 100, y: 50), right: false, flags: []); ge.drag(CGPoint(x: 150, y: 50), flags: []); ge.up(CGPoint(x: 150, y: 50), flags: [])
            }
            check(gdoc.layers[0].pixel(100, 50) != gdoc.layers[0].pixel(140, 20), "Diamond and Conical gradients draw")
            st.gradient = .linear
        }

        // Layer reordering and rasterizing.
        do {
            let ldoc = Document(width: 50, height: 50, background: .white)
            let lc = EditorWindowController(doc: ldoc)
            for n in ["A", "B"] { let l = Layer(width: 50, height: 50, name: n); ldoc.addLayer(l) }
            ldoc.commit("x", symbol: "x", touch: .none)
            lc.moveLayer(from: 0, to: 2)
            check(ldoc.layers.map(\.name) == ["A", "B", "Background"] && ldoc.active == 2, "dragging a layer reorders the stack")
            ldoc.undo()
            check(ldoc.layers.map(\.name) == ["Background", "A", "B"], "undo puts the order back")
            ldoc.active = 2; ldoc.activeLayer.shape = ShapeSpec(kind: .star, frame: CGRect(x: 5, y: 5, width: 30, height: 30), style: .fill,
                                                                 width: 2, primary: .black, secondary: .white, antialias: true)
            lc.rasterizeLayer(nil)
            check(ldoc.activeLayer.shape == nil && ldoc.history.last?.name == "Rasterize Layer", "Rasterize Layer turns a live layer into pixels")
        }

        // Crash recovery: a dirty image is copied in the background and comes back intact.
        do {
            let tmp = dir.appendingPathComponent("recovery", isDirectory: true)
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let realFolder = Recovery.folder
            Recovery.folder = tmp
            let rdoc = Document(width: 200, height: 120, background: .white)
            rdoc.layers[0].fill(RGBA(r: 10, g: 200, b: 90)); rdoc.commit("Fill", symbol: "x")
            let rec = Recovery(doc: rdoc)
            rec.tick()
            Recovery.drain()
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let left = Recovery.leftovers()
            check(left.count == 1 && (try? Document.load(url: left[0]))?.layers[0].pixel(50, 50) == RGBA(r: 10, g: 200, b: 90),
                  "unsaved changes are autosaved for crash recovery")
            rec.stop(); Recovery.drain()
            check(Recovery.leftovers().isEmpty, "the recovery copy goes away when the image is closed")
            Recovery.folder = realFolder
        }

        // Image ops
        doc.transform(.rotCW); doc.commit("Rotate", symbol: "rotate.right", touch: .none)
        check(doc.width == 480 && doc.height == 640, "rotate 90° swaps dimensions")
        doc.undo()
        check(doc.width == 640 && doc.height == 480, "undo rotate restores dimensions")
        doc.canvasSize(width: 700, height: 520, anchorX: 0.5, anchorY: 0.5, fill: .white)
        doc.commit("Canvas Size", symbol: "square.dashed", touch: .none)
        check(doc.width == 700, "canvas size grows the image")
        doc.undo()

        // Every filter runs and finishes
        // A test card: transparent ground, a gradient disc, a red "eye", bars and text.
        let test = Layer(width: 256, height: 192, name: "t")
        test.ctx.saveGState()
        test.ctx.addEllipse(in: CGRect(x: 20, y: 20, width: 150, height: 150)); test.ctx.clip()
        test.ctx.drawLinearGradient(CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 255, g: 200, b: 60).cg, RGBA(r: 0, g: 120, b: 255).cg] as CFArray, locations: [0, 1])!,
                                    start: CGPoint(x: 20, y: 20), end: CGPoint(x: 170, y: 170), options: [])
        test.ctx.restoreGState()
        test.ctx.setFillColor(RGBA(r: 220, g: 20, b: 30).cg); test.ctx.fillEllipse(in: CGRect(x: 80, y: 85, width: 24, height: 24))
        for i in 0..<6 { test.ctx.setFillColor(RGBA(r: UInt8(i * 40), g: 180, b: UInt8(255 - i * 40)).cg); test.ctx.fill(CGRect(x: 185 + i * 11, y: 20, width: 9, height: 150)) }
        test.ctx.setFillColor(.white); test.ctx.fill(CGRect(x: 180, y: 0, width: 76, height: 14))
        let tf = NSGraphicsContext(cgContext: test.ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = tf
        ("Sooth" as NSString).draw(at: CGPoint(x: 30, y: 2), withAttributes: [.font: NSFont(name: "Impact", size: 30) ?? NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let tsrc = test.data()
        var fxShots: [(String, CGImage)] = [("Original", test.image())]
        let all = Filters.adjustments + Filters.effects.flatMap(\.1)
        for f in all {
            if ProcessInfo.processInfo.environment["EASEL_TRACE"] != nil { print("RUN \(f.name)"); fflush(stdout) }
            let out = Layer(width: 256, height: 192, name: "o")
            let t0 = Date()
            tsrc.withUnsafeBytes { raw in
                f.run(FilterIO(src: raw.baseAddress!.assumingMemoryBound(to: UInt8.self), dst: out.bytes, w: 256, h: 192,
                               primary: .black, secondary: .white), f.params.map(\.def))
            }
            var bad = false
            for i in stride(from: 0, to: out.count, by: 4) where out.bytes[i] > out.bytes[i + 3] || out.bytes[i + 1] > out.bytes[i + 3] || out.bytes[i + 2] > out.bytes[i + 3] { bad = true; break }
            check(!bad, String(format: "filter %@ keeps premultiplied pixels valid (%.0f ms)", f.name, Date().timeIntervalSince(t0) * 1000))
            fxShots.append((f.name, out.image()))
            png(out.image(), "fx-" + f.name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "") + ".png")
        }

        // Contact sheet of every effect on the test card.
        do {
            let cols = 8, cw = 256, ch = 192 + 18
            let rows = (fxShots.count + cols - 1) / cols
            let sheet = Layer(width: cols * cw, height: rows * ch, name: "")
            sheet.fill(RGBA(r: 205, g: 205, b: 205))
            let g = NSGraphicsContext(cgContext: sheet.ctx, flipped: false)
            for (i, (name, img)) in fxShots.enumerated() {
                let x = (i % cols) * cw, y = (i / cols) * ch
                sheet.drawImage(img, at: CGPoint(x: x, y: y + 18))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
                (name as NSString).draw(at: CGPoint(x: x + 4, y: sheet.height - y - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
                NSGraphicsContext.restoreGraphicsState()
            }
            png(sheet.image(), "07-effects-sheet.png")
        }

        // Background effect runner: rapid previews coalesce, and the final result is exactly right.
        do {
            let rl = Layer(width: 400, height: 300, name: "r")
            rl.ctx.drawLinearGradient(CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(r: 255, g: 0, b: 80).cg, RGBA(r: 0, g: 120, b: 255).cg] as CFArray, locations: [0, 1])!,
                                      start: .zero, end: CGPoint(x: 400, y: 300), options: [])
            let blur = Filters.effects.flatMap(\.1).first { $0.name == "Gaussian Blur" }!
            let orig = rl.data()
            var expect = Data(count: orig.count)
            orig.withUnsafeBytes { s in expect.withUnsafeMutableBytes { d in
                blur.run(FilterIO(src: s.baseAddress!.assumingMemoryBound(to: UInt8.self), dst: d.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                  w: 400, h: 300, primary: .black, secondary: .white), [9])
            } }
            let runner = FilterRunner(filter: blur, layer: rl, selection: nil, primary: .black, secondary: .white)
            var previews = 0
            runner.onPreview = { previews += 1 }
            for v in stride(from: 1.0, through: 30, by: 1) { runner.preview([v]) }
            var finished = false
            runner.finish([9], window: nil) { _ in finished = true }
            let deadline = Date().addingTimeInterval(10)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            check(finished && rl.data() == expect, "background effect lands the exact final result")
            check(previews <= 1, "stale previews are dropped once the effect is applied (\(previews) shown)")
            runner.cancel()
        }

        // Save / load round trip
        let layered = dir.appendingPathComponent("roundtrip.sooth")
        do {
            try doc.save(to: layered, format: .sooth)
            let back = try Document.load(url: layered)
            check(back.layers.count == doc.layers.count, ".sooth round trip keeps \(doc.layers.count) layers")
            check(back.layers[1].blend == .multiply, ".sooth round trip keeps blend mode")
            check(back.layers[0].pixel(470, 100) == doc.layers[0].pixel(470, 100), ".sooth round trip keeps pixels")
            // Files saved under the app's old name still open.
            let legacy = dir.appendingPathComponent("legacy.easel")
            try? FileManager.default.removeItem(at: legacy)
            try FileManager.default.copyItem(at: layered, to: legacy)
            check((try? Document.load(url: legacy))?.layers.count == doc.layers.count, "old .easel files still open")
            for f in [SaveFormat.png, .jpeg, .tiff, .bmp, .heic] {
                let u = dir.appendingPathComponent("export." + f.ext)
                try doc.save(to: u, format: f)
                let r = try Document.load(url: u)
                check(r.width == 640 && r.height == 480, "export + reopen \(f.ext)")
            }
        } catch {
            check(false, "file IO threw \(error)")
        }

        // Cursor artwork, for eyeballing
        for (name, c) in [("movePixels", Cursors.movePixels), ("moveSelection", Cursors.moveSelection),
                          ("rotate", Cursors.rotate), ("resize45", Cursors.resize(angle: .pi / 4))] {
            if let t = c.image.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("cursor-\(name).png"))
            }
        }

        // Render the editor window
        if let win = ctl.window, let view = win.contentView {
            win.setContentSize(NSSize(width: 1320, height: 860))
            view.layoutSubtreeIfNeeded()
            ctl.zoomFit(nil)
            ctl.structureChanged()
            st.tool = .brush
            view.layoutSubtreeIfNeeded()
            func shot(_ name: String, _ ap: NSAppearance.Name) {
                win.appearance = NSAppearance(named: ap)
                view.needsDisplay = true
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                let img = NSImage(size: view.bounds.size)
                img.lockFocus()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.black.setFill(); view.bounds.fill()
                }
                rep.draw(in: view.bounds)
                img.unlockFocus()
                if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t) {
                    try? r.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
            }
            shot("00-window-dark.png", .darkAqua)
            // Move tool with handles on a selection
            doc.selection = Selection.path(CGPath(rect: CGRect(x: 360, y: 40, width: 240, height: 160), transform: nil),
                                           width: doc.width, height: doc.height, antialias: false)
            doc.commit("Rectangle Select", symbol: "x", touch: .none)
            st.tool = .moveSelected
            ctl.canvas.needsDisplay = true
            shot("00-window-move.png", .darkAqua)
            // Live meme text being edited
            doc.selection = nil; doc.commit("Deselect", symbol: "x", touch: .none)
            st.fontName = "Impact"; st.fontSize = 64; st.primary = .white; st.secondary = .black
            st.outlineWidth = 4; st.textAlign = .center
            st.tool = .text
            eng.down(CGPoint(x: 320, y: 360), right: false, flags: []); eng.up(CGPoint(x: 320, y: 360), flags: [])
            eng.text?.view.insertText("WHEN IT JUST WORKS", replacementRange: NSRange(location: NSNotFound, length: 0))
            ctl.canvas.needsDisplay = true
            shot("00-window-text.png", .darkAqua)
            eng.finishText()
        }

        // Probe: real mouse events through CanvasView, and typing with spaces one key at a time.
        if ProcessInfo.processInfo.environment["EASEL_PROBE"] != nil, let win = ctl.window {
            doc.active = 0
            doc.selection = Selection.path(CGPath(rect: CGRect(x: 360, y: 40, width: 120, height: 80), transform: nil),
                                           width: doc.width, height: doc.height, antialias: false)
            doc.commit("Rectangle Select", symbol: "x", touch: .none)
            st.tool = .moveSelected
            let cv = ctl.canvas!
            func ev(_ t: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                let w = cv.convert(p, to: nil)
                return NSEvent.mouseEvent(with: t, location: w, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let before = doc.activeLayer.pixel(420, 80), mag = cv.magnification
            cv.mouseDown(with: ev(.leftMouseDown, CGPoint(x: 420, y: 80)))
            cv.mouseDragged(with: ev(.leftMouseDragged, CGPoint(x: 420, y: 180)))
            cv.mouseUp(with: ev(.leftMouseUp, CGPoint(x: 420, y: 180)))
            print("PROBE mag=\(mag) moved pixel before=\(before) after-at-dest=\(doc.activeLayer.pixel(420, 180)) src-now=\(doc.activeLayer.pixel(420, 80)) sel=\(doc.selection?.bounds ?? .zero) last=\(doc.history.last?.name ?? "")")
            st.tool = .text; st.textAlign = .center; st.fontSize = 48; st.outlineWidth = 3
            eng.down(CGPoint(x: 300, y: 300), right: false, flags: []); eng.up(CGPoint(x: 300, y: 300), flags: [])
            if let ed = eng.text {
                for ch in "HELLO WORLD THIS IS " { ed.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                var lines = 0
                ed.layout.enumerateLineFragments(forGlyphRange: ed.layout.glyphRange(for: ed.container)) { _, _, _, _, _ in lines += 1 }
                print("PROBE text lines=\(lines) frame=\(ed.view.frame) container=\(ed.container.size)")
                eng.finishText()
            }
            // A photo-sized canvas zoomed to fit, typing as a person would.
            let big = Document(width: 3024, height: 4032, background: RGBA(r: 120, g: 150, b: 190))
            let bc = EditorWindowController(doc: big)
            if let bw = bc.window, let bv = bw.contentView {
                bw.setContentSize(NSSize(width: 1320, height: 860)); bv.layoutSubtreeIfNeeded(); bc.zoomFit(nil)
                let be = bc.canvas.engine
                st.tool = .text; st.fontName = "Helvetica Neue"; st.fontSize = 36; st.outlineWidth = 0; st.textAlign = .left
                st.primary = .black
                be.down(CGPoint(x: 800, y: 1500), right: false, flags: []); be.up(CGPoint(x: 800, y: 1500), flags: [])
                for ch in "Hello there, typing" { be.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                print("PROBE big mag=\(bc.canvas.magnification) frame=\(be.text?.view.frame ?? .zero)")
                bv.needsDisplay = true; bv.layoutSubtreeIfNeeded()
                if let rep = bv.bitmapImageRepForCachingDisplay(in: bv.bounds) {
                    bv.cacheDisplay(in: bv.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("probe-big-text.png"))
                }
                st.fontSize = 200; be.styleChanged()
                for ch in " BIG" { be.text?.view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
                bv.needsDisplay = true; bv.layoutSubtreeIfNeeded()
                if let rep = bv.bitmapImageRepForCachingDisplay(in: bv.bounds) {
                    bv.cacheDisplay(in: bv.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("probe-big-text2.png"))
                }
            }
        }

        // Regressions found in the 2026-10-16 review: each of these once corrupted, crashed or lost work.
        do {
            let red = RGBA(r: 255, g: 0, b: 0)
            // Flip Layer while painting its mask, then undo: the layer flips back too.
            do {
                let d = Document(width: 100, height: 100, background: .white)
                let c = EditorWindowController(doc: d)
                d.activeLayer.ctx.setFillColor(red.cg); d.activeLayer.ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
                d.commit("paint", symbol: "x")
                c.addLayerMask(nil)
                c.flipLayerH(nil)
                c.doUndo(nil)
                check(d.activeLayer.pixel(10, 50) == red, "undoing Flip Layer while editing the mask flips the layer back")
                c.doRedo(nil)
                d.canvasSize(width: 120, height: 100, anchorX: 0, anchorY: 0, fill: .white); d.commit("cs", symbol: "x", touch: .none)
                c.doUndo(nil)
                check(d.activeLayer.pixel(10, 50) != red, "redo then undo of a later step keeps the flip")
            }
            // Move Selected Pixels, switch to the mask, move again: layer pixels never land in the mask.
            do {
                let d = Document(width: 100, height: 100, background: .white)
                let c = EditorWindowController(doc: d)
                let e = c.canvas.engine
                d.activeLayer.ctx.setFillColor(red.cg); d.activeLayer.ctx.fill(CGRect(x: 10, y: 60, width: 20, height: 20))
                d.commit("paint", symbol: "x")
                c.addLayerMask(nil); c.toggleMaskEditing(nil)
                d.selection = Selection.path(CGPath(rect: CGRect(x: 10, y: 20, width: 20, height: 20), transform: nil), width: 100, height: 100, antialias: false)
                d.commit("sel", symbol: "x", touch: .none)
                st.tool = .moveSelected
                e.down(CGPoint(x: 20, y: 30), right: false, flags: []); e.drag(CGPoint(x: 30, y: 30), flags: []); e.up(CGPoint(x: 30, y: 30), flags: [])
                c.toggleMaskEditing(nil)
                e.down(CGPoint(x: 30, y: 30), right: false, flags: []); e.drag(CGPoint(x: 40, y: 30), flags: []); e.up(CGPoint(x: 40, y: 30), flags: [])
                var redInMask = 0
                if let m = d.activeLayer.mask {
                    for y in 0..<100 { for x in 0..<100 { let p = m.pixel(x, y); if p.r > 200 && p.g < 50 && p.a > 200 { redInMask += 1 } } }
                }
                check(redInMask == 0, "moving pixels after switching to the mask doesn't copy colour into the mask (\(redInMask) red)")
            }
            // Eraser edits on a picture layer survive a .sooth round trip.
            do {
                let d = Document(width: 200, height: 200, background: .white)
                let c = EditorWindowController(doc: d)
                let src = Layer(width: 100, height: 100, name: ""); src.fill(RGBA(r: 0, g: 0, b: 255))
                c.addImageLayer(src.image(), named: "blue", at: CGPoint(x: 100, y: 100))
                st.tool = .eraser; st.brushWidth = 30; st.brushOpacity = 1; st.brushHardness = 1
                c.canvas.engine.down(CGPoint(x: 100, y: 100), right: false, flags: []); c.canvas.engine.up(CGPoint(x: 100, y: 100), flags: [])
                let url = dir.appendingPathComponent("erased-picture.sooth")
                try? d.save(to: url, format: .sooth)
                if let d2 = try? Document.load(url: url) {
                    let c2 = EditorWindowController(doc: d2)
                    d2.active = 1
                    st.tool = .moveSelected
                    c2.canvas.engine.nudge(1, 0)
                    let px = d2.compositePixel(101, 100)
                    check(px.r > 200 && px.g > 200, "Eraser edits on a picture layer are kept in .sooth files (got \(px))")
                    withExtendedLifetime(c2) {}
                } else { check(false, "erased picture layer reopens") }
            }
            // Editing text, then a history jump that reorders layers: the text lands on its own layer.
            do {
                let d = Document(width: 200, height: 200, background: .white)
                let c = EditorWindowController(doc: d)
                let e = c.canvas.engine
                var spec = TextSpec(); spec.string = "Hello"; spec.anchor = CGPoint(x: 20, y: 20); spec.fontSize = 40
                let t = Layer(width: 200, height: 200, name: "Hello"); t.text = spec; TextEditor.render(spec, into: t)
                d.addLayer(t); d.commit("Add Text", symbol: "x", touch: .none)
                d.addLayer(); d.activeLayer.name = "Paint"
                d.activeLayer.ctx.setFillColor(red.cg); d.activeLayer.ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
                d.commit("Paint", symbol: "x")
                let before = d.cursor
                c.moveLayer(from: 2, to: 1)
                st.tool = .text
                let f = TextEditor.frame(of: spec)
                e.down(CGPoint(x: f.midX, y: f.midY), right: false, flags: []); e.up(CGPoint(x: f.midX, y: f.midY), flags: [])
                d.jump(to: before)
                e.finishText()
                let paint = d.layers.first { $0.name == "Paint" }
                check(paint?.text == nil && paint?.pixel(150, 150) == red, "finishing text after a history jump never overwrites another layer")
            }
            // A damaged layered file (active −1) opens without trapping.
            do {
                let root: [String: Any] = ["format": "sooth", "version": 1, "width": 10, "height": 10, "active": -1, "layers": [["name": "a"]]]
                let url = dir.appendingPathComponent("negative-active.sooth")
                try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0).write(to: url)
                check((try? Document.load(url: url))?.active == 0, "a file with a bad active layer opens on layer 0")
            }
            // A stroke whose canvas shrinks under it (crop while the pen is down) neither crashes nor paints off the end.
            do {
                let d = Document(width: 400, height: 400, background: .white)
                let c = EditorWindowController(doc: d)
                let e = c.canvas.engine
                d.selection = Selection.path(CGPath(rect: CGRect(x: 0, y: 0, width: 20, height: 20), transform: nil), width: 400, height: 400, antialias: false)
                st.tool = .brush; st.brushWidth = 20
                e.down(CGPoint(x: 5, y: 5), right: false, flags: [])
                check(!c.validateMenuItem(NSMenuItem(title: "Undo", action: #selector(EditorWindowController.doUndo(_:)), keyEquivalent: "")),
                      "menu commands wait while a stroke is going")
                c.cropToSelection(nil)
                e.drag(CGPoint(x: 390, y: 390), flags: []); e.up(CGPoint(x: 390, y: 390), flags: [])
                check(d.width == 20 && d.activeLayer.width == 20, "a stroke cut short by a crop leaves a sound image")
                withExtendedLifetime(c) {}
            }
            // Two images share no subject cache.
            do {
                let a = Document(width: 300, height: 200, background: RGBA(r: 140, g: 190, b: 242))
                let ac = a.layers[0].ctx
                ac.setFillColor(RGBA(r: 255, g: 216, b: 178).cg); ac.fillEllipse(in: CGRect(x: 125, y: 115, width: 50, height: 50))
                ac.setFillColor(RGBA(r: 230, g: 76, b: 128).cg); ac.fill(CGRect(x: 127, y: 45, width: 45, height: 72))
                a.layers[0].touch()
                let b = Document(width: 600, height: 400, background: .white)
                let ca = EditorWindowController(doc: a), cb = EditorWindowController(doc: b)
                st.tool = .magicWand; st.wandSubject = true; st.sampleImage = true
                ca.canvas.engine.down(CGPoint(x: 150, y: 120), right: false, flags: []); ca.canvas.engine.up(CGPoint(x: 150, y: 120), flags: [])
                while b.revision < a.revision - 1 { b.commit("noop", symbol: "x", touch: .none) }
                cb.canvas.engine.down(CGPoint(x: 150, y: 120), right: false, flags: []); cb.canvas.engine.up(CGPoint(x: 150, y: 120), flags: [])
                check(b.selection == nil || b.selection?.mask.count == 600 * 400, "the subject wand never borrows another image's subject")
                st.wandSubject = false; st.sampleImage = false
                withExtendedLifetime((ca, cb)) {}
            }
        }

        // The look picker: a click on a look's name or blurb chooses that look (the labels mustn't swallow it).
        do {
            let picker = LookPicker()
            if let cv = picker.window?.contentView {
                cv.layoutSubtreeIfNeeded()
                func find(_ v: NSView) -> NSTextField? {
                    if let t = v as? NSTextField, t.stringValue == "Platinum" { return t }
                    for s in v.subviews { if let f = find(s) { return f } }
                    return nil
                }
                if let lab = find(cv), let sup = cv.superview {
                    let p = sup.convert(NSPoint(x: lab.bounds.midX, y: lab.bounds.midY), from: lab)
                    let hit = sup.hitTest(p)
                    check(hit.map { String(describing: type(of: $0)).contains("LookRow") } == true, "clicking a look's name in the picker hits its row")
                } else { check(false, "the picker lists Platinum") }
            }
            picker.window?.delegate = nil
            picker.window?.orderOut(nil)
        }

        print(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }
}
