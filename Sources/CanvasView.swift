import AppKit

/// Keeps a smaller-than-viewport image centred, like Paint.NET's canvas.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        return r
    }

    override func draw(_ dirtyRect: NSRect) {
        // Glass: the image floats on the sky (pinned to the view, so it doesn't scroll with the image).
        if Look.current == .glass { Chrome.sky(bounds) } else { super.draw(dirtyRect) }
    }

    /// Clicks in the black margin go to the canvas, so handles drawn past the image's edge can be grabbed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? documentView : v
    }
}

final class CanvasView: NSView {
    let doc: Document
    weak var controller: EditorWindowController?
    /// Handles, frames, marching ants and the brush ring draw here, above the scroll view, so they can
    /// reach past the image's edge and are always wiped whole (no trails when dragging).
    weak var overlay: CanvasOverlay?
    lazy var engine = ToolEngine(doc: doc, canvas: self)
    var showGrid = false { didSet { needsDisplay = true } }

    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?
    private var tempPan = false
    private var panning: (window: NSPoint, origin: NSPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    init(doc: Document) {
        self.doc = doc
        super.init(frame: NSRect(x: 0, y: 0, width: doc.width, height: doc.height))
        registerForDraggedTypes([.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.image")])
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, self.doc.selection != nil || self.engine.previewPath != nil else { return }
            self.antsPhase += 1
            self.overlay?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { antsTimer?.invalidate() }

    func sizeToDocument() {
        let s = NSSize(width: doc.width, height: doc.height)
        if frame.size != s { setFrameSize(s) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds
        // The checkerboard only shows through transparency; skip it under an opaque bottom layer.
        let bottom = doc.layers.first { $0.visible }
        if !(bottom.map { $0.opacity >= 1 && $0.blend == .normal && $0.isFullyOpaque } ?? false) {
            cg.saveGState()
            cg.clip(to: r.intersection(dirtyRect))
            cg.draw(checkerTile, in: CGRect(x: 0, y: 0, width: 16, height: 16), byTiling: true)
            cg.restoreGState()
        }

        let img = doc.composite()
        let mag = magnification
        // Draw only the part of the image under the dirty rect (padded so smoothing has neighbours).
        // Zoomed out past one image pixel per screen pixel, CoreGraphics shrinks a cropped piece a little
        // differently from the whole image, leaving faint patches along a drag; there the whole image is
        // drawn (AppKit already clips drawing to the dirty region; an extra clip here is 9× slower).
        let shrinking = mag * (window?.backingScaleFactor ?? 2) < 1
        let crop = shrinking ? r : dirtyRect.insetBy(dx: -3, dy: -3).intersection(r).integral
        if !crop.isEmpty, let part = crop == r ? img : img.cropping(to: crop) {
            cg.saveGState()
            cg.interpolationQuality = mag >= 1.5 ? .none : .high
            cg.translateBy(x: 0, y: crop.maxY)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(part, in: CGRect(x: crop.minX, y: 0, width: crop.width, height: crop.height))
            cg.restoreGState()
        }

        let lw = 1 / mag
        if showGrid && mag >= 6 {
            cg.saveGState()
            cg.setStrokeColor(CGColor(gray: 0.5, alpha: 0.35))
            cg.setLineWidth(lw)
            let d = dirtyRect.intersection(r)
            var x = floor(d.minX)
            while x <= d.maxX { cg.move(to: CGPoint(x: x, y: d.minY)); cg.addLine(to: CGPoint(x: x, y: d.maxY)); x += 1 }
            var y = floor(d.minY)
            while y <= d.maxY { cg.move(to: CGPoint(x: d.minX, y: y)); cg.addLine(to: CGPoint(x: d.maxX, y: y)); y += 1 }
            cg.strokePath()
            cg.restoreGState()
        }

        overlay?.needsDisplay = true
    }

    /// The guides, in image coordinates (the overlay sets up the transform).
    func drawGuides(_ cg: CGContext) {
        drawOffCanvas(cg)
        drawCanvasFrame(cg)
        if let live = engine.liveOutline { drawAnts(cg, path: live, offset: .zero) } else if let sel = doc.selection { drawAnts(cg, path: sel.outline, offset: .zero) }
        engine.drawOverlay(cg, lw: 1 / magnification)
    }

    // MARK: Past the edge

    /// Text, shape and image layers that hang past the canvas show there faintly, so nothing is lost
    /// from sight (dragging the canvas bigger brings it in for real).
    private func drawOffCanvas(_ cg: CGContext) {
        let full = doc.fullRect
        for l in doc.layers where l.visible && l.isLive {
            let ext: CGRect
            if let o = l.object { ext = o.extent } else if let sh = l.shape { ext = sh.extent }
            else if let t = l.text { ext = TextEditor.frame(of: t).insetBy(dx: -4, dy: -4) } else { continue }
            if full.contains(ext) { continue }
            cg.saveGState()
            let outside = CGMutablePath()
            outside.addRect(ext.union(full).insetBy(dx: -8, dy: -8))
            outside.addRect(full)
            cg.addPath(outside)
            cg.clip(using: .evenOdd)
            cg.setAlpha(0.4 * l.opacity)
            cg.beginTransparencyLayer(in: ext, auxiliaryInfo: nil)
            if let o = l.object { o.draw(imageSpace: cg) }
            else if let sh = l.shape { sh.draw(imageSpace: cg) }
            else if let t = l.text { TextEditor(spec: t).draw(in: cg) }
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
    }

    // MARK: Canvas size by dragging

    /// Handles a little outside the canvas's corners and edges; drag one to grow or shrink the canvas.
    private var canvasGrip: CGFloat { 16 / magnification }
    private var canvasDrag: (ux: Int, uy: Int, start: CGPoint)?
    /// The canvas rectangle being dragged out (image coordinates), drawn until the mouse comes up.
    private(set) var canvasPreview: CGRect?

    private func canvasHandlePoint(_ ux: Int, _ uy: Int, in r: CGRect) -> CGPoint {
        let g = canvasGrip
        return CGPoint(x: ux < 0 ? r.minX - g : ux > 0 ? r.maxX + g : r.midX,
                       y: uy < 0 ? r.minY - g : uy > 0 ? r.maxY + g : r.midY)
    }

    func canvasHandle(at p: CGPoint) -> (Int, Int)? {
        let reach = 8 / magnification
        return TransformSession.handles.first { (canvasHandlePoint($0.0, $0.1, in: doc.fullRect) - p).length <= reach }
    }

    private func drawCanvasFrame(_ cg: CGContext) {
        let lw = 1 / magnification
        let r = canvasPreview ?? doc.fullRect
        cg.saveGState()
        // The canvas's edge, so it reads clearly against what hangs past it.
        cg.setLineWidth(lw)
        cg.setStrokeColor(Ink.faint.cgColor)
        cg.stroke(doc.fullRect.insetBy(dx: -lw / 2, dy: -lw / 2))
        if let pr = canvasPreview {
            cg.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            cg.setLineDash(phase: 0, lengths: [4 * lw, 3 * lw])
            cg.stroke(pr)
            cg.setLineDash(phase: 0, lengths: [])
        }
        let k = 3.5 * lw
        for (ux, uy) in TransformSession.handles {
            let q = canvasHandlePoint(ux, uy, in: r)
            let box = CGRect(x: q.x - k, y: q.y - k, width: 2 * k, height: 2 * k)
            cg.setFillColor(CGColor(gray: 0, alpha: 1)); cg.fill(box)
            cg.setStrokeColor((canvasPreview != nil ? Ink.soft : Ink.name).cgColor); cg.stroke(box)
        }
        if let pr = canvasPreview {
            // `1200×800` beside the pointer's handle, at screen size.
            let label = NSAttributedString(string: "\(Int(pr.width))×\(Int(pr.height))",
                                           attributes: [.font: pixelFont(), .foregroundColor: Ink.text, .backgroundColor: Ink.window])
            var at = canvasHandlePoint(canvasDrag?.ux ?? 1, canvasDrag?.uy ?? 1, in: pr)
            // Kept on screen even when that edge has been dragged out of view.
            if let clip = enclosingScrollView?.contentView {
                let vis = convert(clip.bounds, from: clip)
                let sz = label.size()
                at.x = min(max(at.x, vis.minX), vis.maxX - (sz.width + 24) * lw)
                at.y = min(max(at.y, vis.minY), vis.maxY - (sz.height + 16) * lw)
            }
            cg.translateBy(x: at.x, y: at.y)
            cg.scaleBy(x: lw, y: lw)
            let g = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
            label.draw(at: CGPoint(x: 12, y: 8))
            NSGraphicsContext.restoreGraphicsState()
        }
        cg.restoreGState()
    }

    /// What new canvas continues: the background's own colour where that edge is one flat colour
    /// (a white page grows white), otherwise nothing (transparent).
    private func edgeFill(_ ux: Int, _ uy: Int) -> RGBA {
        let bg = doc.layers[0]
        guard bg.adjustment == nil, bg.visible else { return .clear }
        var samples: [RGBA] = []
        if ux != 0 {
            let x = ux < 0 ? 0 : bg.width - 1
            for y in stride(from: 0, to: bg.height, by: max(1, bg.height / 64)) { samples.append(bg.pixel(x, y)) }
        }
        if uy != 0 {
            let y = uy < 0 ? 0 : bg.height - 1
            for x in stride(from: 0, to: bg.width, by: max(1, bg.width / 64)) { samples.append(bg.pixel(x, y)) }
        }
        guard let first = samples.first, samples.allSatisfy({ $0 == first }) else { return .clear }
        return first
    }

    private func beginCanvasDrag(_ h: (Int, Int), at p: CGPoint) {
        engine.finishText()
        canvasDrag = (h.0, h.1, p)
        canvasPreview = doc.fullRect
        overlay?.needsDisplay = true
    }

    private func dragCanvas(to p: CGPoint) {
        guard let d = canvasDrag else { return }
        let dx = (p.x - d.start.x).rounded(), dy = (p.y - d.start.y).rounded()
        var x0: CGFloat = 0, y0: CGFloat = 0, x1 = CGFloat(doc.width), y1 = CGFloat(doc.height)
        if d.ux < 0 { x0 = min(x1 - 1, x0 + dx) } else if d.ux > 0 { x1 = max(x0 + 1, x1 + dx) }
        if d.uy < 0 { y0 = min(y1 - 1, y0 + dy) } else if d.uy > 0 { y1 = max(y0 + 1, y1 + dy) }
        canvasPreview = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        overlay?.needsDisplay = true
    }

    private func finishCanvasDrag(apply: Bool) {
        guard let d = canvasDrag, let r = canvasPreview else { return }
        canvasDrag = nil; canvasPreview = nil
        overlay?.needsDisplay = true
        let w = Int(r.width), h = Int(r.height)
        guard apply, w != doc.width || h != doc.height else { return }
        guard Limits.ok(w, h) else { Limits.tooBig(); return }
        // The side being dragged moves; the opposite side stays put.
        let ax: Double = d.ux < 0 ? 1 : 0, ay: Double = d.uy < 0 ? 1 : 0
        let before = visibleRect.origin
        doc.canvasSize(width: w, height: h, anchorX: ax, anchorY: ay, fill: edgeFill(d.ux, d.uy))
        doc.commit("Canvas Size", symbol: "square.dashed", touch: .none)
        // Grown to the left or top: scroll with it so the picture stays where it was on screen.
        scroll(CGPoint(x: before.x - r.minX, y: before.y - r.minY))
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        overlay?.needsDisplay = true
    }

    override var needsDisplay: Bool {
        didSet { if needsDisplay { overlay?.needsDisplay = true } }
    }

    func drawAnts(_ cg: CGContext, path: CGPath, offset: CGPoint) {
        let lw = 1 / magnification
        cg.saveGState()
        cg.translateBy(x: offset.x, y: offset.y)
        cg.setLineWidth(lw)
        cg.addPath(path)
        cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
        cg.strokePath()
        cg.addPath(path)
        cg.setStrokeColor(CGColor(gray: 0, alpha: 1))
        cg.setLineDash(phase: antsPhase * lw, lengths: [4 * lw, 4 * lw])
        cg.strokePath()
        cg.restoreGState()
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private var isPanMode: Bool { tempPan || AppState.shared.tool == .pan }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if isPanMode { beginPan(e); return }
        if let h = canvasHandle(at: point(e)) { beginCanvasDrag(h, at: point(e)); return }
        engine.pressure = e.subtype == .tabletPoint ? CGFloat(e.pressure) : 1
        let tool = AppState.shared.tool
        if e.clickCount == 2, tool == .moveSelected || tool == .moveSelection {
            if engine.editText(at: point(e)) { return }
            // Double-click a subject in a flat layer to lift it out into its own movable layer.
            if tool == .moveSelected, doc.selection == nil, let i = engine.pixelLayer(at: point(e)), !doc.layers[i].isLive {
                controller?.liftSubject(at: point(e), keepOriginal: e.modifierFlags.contains(.option))
                return
            }
        }
        engine.down(point(e), right: e.modifierFlags.contains(.control), flags: e.modifierFlags)
    }

    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if isPanMode { beginPan(e); return }
        engine.down(point(e), right: true, flags: e.modifierFlags)
    }

    override func mouseDragged(with e: NSEvent) {
        if panning != nil { pan(e); return }
        if canvasDrag != nil { dragCanvas(to: point(e)); return }
        engine.hover = point(e)
        engine.pressure = e.subtype == .tabletPoint ? CGFloat(e.pressure) : 1
        engine.drag(point(e), flags: e.modifierFlags)
        controller?.updateCursor(point(e))
    }

    override func rightMouseDragged(with e: NSEvent) { mouseDragged(with: e) }

    override func mouseUp(with e: NSEvent) {
        if panning != nil { panning = nil; NSCursor.openHand.set(); return }
        if canvasDrag != nil { finishCanvasDrag(apply: true); return }
        engine.up(point(e), flags: e.modifierFlags)
    }

    override func rightMouseUp(with e: NSEvent) { mouseUp(with: e) }

    override func mouseMoved(with e: NSEvent) {
        let p = point(e)
        engine.hover = p
        controller?.updateCursor(p)
        if !tempPan, let (ux, uy) = canvasHandle(at: p) {
            Cursors.resize(angle: atan2(CGFloat(uy), CGFloat(ux))).set()
            return
        }
        if !tempPan, let c = engine.cursor(at: p) { c.set() }
        else if !tempPan, !bounds.contains(p) { NSCursor.arrow.set() }
        if AppState.shared.tool.showsBrushCursor { overlay?.needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        engine.hover = nil
        controller?.updateCursor(nil)
        overlay?.needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Tracked over the whole viewport, black margin included (the canvas handles live out there).
        let host: NSView = superview ?? self
        host.trackingAreas.filter { $0.owner === self }.forEach(host.removeTrackingArea)
        host.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                            owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        (tempPan ? NSCursor.openHand : AppState.shared.tool.cursor).set()
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tempPan ? .openHand : AppState.shared.tool.cursor)
    }

    private func beginPan(_ e: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        panning = (e.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func pan(_ e: NSEvent) {
        guard let (w0, o0) = panning, let sv = enclosingScrollView else { return }
        let mag = sv.magnification
        let dx = (e.locationInWindow.x - w0.x) / mag, dy = (e.locationInWindow.y - w0.y) / mag
        let target = NSPoint(x: o0.x - dx, y: o0.y + dy)
        let clip = sv.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin)
        sv.reflectScrolledClipView(clip)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
            let factor = exp(e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            controller?.setZoom(magnification * factor, at: point(e))
        } else {
            super.scrollWheel(with: e)
        }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 49 {
            if !e.isARepeat { tempPan = true; NSCursor.openHand.set(); window?.invalidateCursorRects(for: self) }
            return
        }
        if e.keyCode == 53, canvasDrag != nil { finishCanvasDrag(apply: false); return }
        if e.keyCode == 53 { if AppState.shared.tool == .shapes { engine.deselectShape() }; engine.cancel(); return }
        if (e.keyCode == 36 || e.keyCode == 76), AppState.shared.tool == .shapes { engine.deselectShape(); return }
        let tool = AppState.shared.tool
        if tool == .moveSelected || tool == .moveSelection {
            let k: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            switch e.keyCode {
            case 123: engine.nudge(-k, 0); return
            case 124: engine.nudge(k, 0); return
            case 125: engine.nudge(0, k); return
            case 126: engine.nudge(0, -k); return
            case 36, 76: engine.finishTransform(); return
            default: break
            }
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if e.keyCode == 51 || e.keyCode == 117 {
            if mods == .option { controller?.fillSelection(nil) }
            else if e.modifierFlags.contains(.shift) { controller?.contentAwareFill(nil) }
            else { controller?.eraseSelection(nil) }
            return
        }
        guard mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased().first else {
            super.keyDown(with: e); return
        }
        let st = AppState.shared
        switch ch {
        case "x": st.swapColors()
        case "[": st.brushWidth = max(1, st.brushWidth - (st.brushWidth > 10 ? 5 : 1))
        case "]": st.brushWidth = min(500, st.brushWidth + (st.brushWidth >= 10 ? 5 : 1))
        default:
            let tools = ToolKind.allCases.filter { $0.key == ch }
            guard !tools.isEmpty else { super.keyDown(with: e); return }
            if let i = tools.firstIndex(of: st.tool) {
                st.tool = tools[(i + 1) % tools.count]
            } else {
                st.tool = tools[0]
            }
        }
    }

    override func keyUp(with e: NSEvent) {
        if e.keyCode == 49 {
            tempPan = false
            window?.invalidateCursorRects(for: self)
            AppState.shared.tool.cursor.set()
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let at = convert(sender.draggingLocation, from: nil)
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty, urls.allSatisfy({ Library.exts.contains($0.pathExtension) }) {
            for u in urls { controller?.insertLibraryItem(u, at: at) }   // from the Library window (or Finder)
            return true
        }
        if !urls.isEmpty {
            // Dropped files land as movable layers where you drop them; ⌥ opens them as their own images.
            if NSEvent.modifierFlags.contains(.option) {
                for u in urls { (NSApp.delegate as? AppDelegate)?.open(u) }
            } else {
                for u in urls { controller?.importLayer(from: u, at: at) }
            }
            return true
        }
        // An image dragged straight out of a browser or another app.
        if let img = NSImage(pasteboard: pb) {
            var r = CGRect(origin: .zero, size: img.size)
            if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                controller?.addImageLayer(Layer.from(image: cg, name: "").image(), named: "Dropped Image", at: at)
                return true
            }
        }
        return false
    }
}

/// A see-through layer over the scroll view that draws the canvas's guides. It never takes clicks.
final class CanvasOverlay: NSView {
    weak var canvas: CanvasView?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true   // redraws alone, without making the image underneath redraw
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Guides past the viewport (handles of a scrolled-away canvas edge) must not draw over the
        // tools and panels around it.
        clipsToBounds = true
        layer?.masksToBounds = true
        canvas.overlay = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let cg = NSGraphicsContext.current?.cgContext else { return }
        let o = convert(NSPoint.zero, from: canvas), o1 = convert(NSPoint(x: 1, y: 1), from: canvas)
        cg.saveGState()
        cg.clip(to: bounds)
        cg.translateBy(x: o.x, y: o.y)
        cg.scaleBy(x: o1.x - o.x, y: o1.y - o.y)
        canvas.drawGuides(cg)
        cg.restoreGState()
    }
}
