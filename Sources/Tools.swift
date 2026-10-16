import AppKit

/// Mouse-driven tool behaviour for one canvas. Points are in image coordinates (y down).
final class ToolEngine {
    unowned let doc: Document
    unowned let canvas: CanvasView

    var st: AppState { AppState.shared }
    var L: Layer { doc.paintTarget }   // the mask instead, while editing it

    private var active = false
    /// True while the mouse or pen is down on the canvas (commands that change the image wait for it).
    var isDragging: Bool { active }
    private var right = false
    private var tool: ToolKind = .brush
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private var points: [CGPoint] = []
    private var snap: Data?
    private var prevDirty: CGRect?
    private var mode: SelectMode = .replace
    /// Pixels touched since the last redraw request (image coordinates); nil = only overlays moved.
    private var dirtyArea: CGRect?
    private func mark(_ r: CGRect) { dirtyArea = dirtyArea.map { $0.union(r) } ?? r }
    private func flush() {
        if let d = dirtyArea { L.drew(in: d); doc.pixelsChanged(d) } else { doc.overlayChanged() }
        dirtyArea = nil
    }

    private(set) var previewPath: CGPath?
    /// The live layer whose handles were let go of by clicking off it (it stays the active layer).
    private weak var letGo: Layer?
    /// The active layer's handles are hidden: clicking empty space deselected it.
    var handlesHidden: Bool { letGo != nil && letGo === L }
    /// Move / scale / rotate state for the two Move tools.
    private var session: TransformSession?
    private var tdrag: TransformDrag?
    private var resizeCursors: [Int: NSCursor] = [:]
    /// A Move-tool drag on a text layer: moves or resizes the text itself, never its pixels.
    private var textMove: (spec: TextSpec, frame: CGRect, handle: Handle, start: CGPoint, ink: CGRect)?
    /// A Move-tool drag on an object layer: changes where its original pixels are drawn, losslessly.
    private var objectMove: (spec: ObjectSpec, handle: Handle, start: CGPoint, ink: CGRect)?
    /// A drag on a shape layer (Shapes or Move tool): moves, resizes or rotates the shape itself.
    private var shapeMove: (spec: ShapeSpec, handle: Handle, start: CGPoint, ink: CGRect)?
    /// A new shape being drawn into its own (not yet recorded) layer.
    private var drawingShape: (layer: Layer, ink: CGRect)?
    /// Toolbar edits to a shape are recorded once they settle.
    private var shapeEditTimer: Timer?
    /// The selected shape layer's handles and toolbar edits are live only while this is set: right
    /// after drawing or clicking a shape, until the tool changes or Return / Esc.
    private(set) var shapeSelected = false

    private(set) var cloneSource: CGPoint?
    private var cloneOffset = CGPoint.zero
    private var cloneImage: CGImage?

    var hover: CGPoint?
    /// Pen pressure for the current event (1 for a mouse or trackpad).
    var pressure: CGFloat = 1
    private var brush: BrushStroke?
    private var maskBrush: MaskBrush?
    private var brushSize: CGFloat { st.brushWidth * (st.pressureSize ? max(0.08, pressure) : 1) }

    /// The live text box while the Text tool is editing, if any.
    private(set) var text: TextEditor?
    private var movingText = false
    private var textGrab = CGPoint.zero

    init(doc: Document, canvas: CanvasView) {
        self.doc = doc
        self.canvas = canvas
    }

    private var color: RGBA { right ? st.secondary : st.primary }
    private var other: RGBA { right ? st.primary : st.secondary }

    // MARK: Painting helpers

    /// Runs `body` in image coordinates on the active layer, clipped to the selection.
    private func paint(clip: Bool = true, _ body: (CGContext) -> Void) {
        let c = L.ctx
        c.saveGState()
        if clip, let s = doc.selection { c.clip(to: L.rect, mask: s.image) }
        c.translateBy(x: 0, y: CGFloat(L.height))
        c.scaleBy(x: 1, y: -1)
        c.setShouldAntialias(st.antialias)
        body(c)
        c.restoreGState()
    }

    /// Restore the pre-operation pixels in `r` (and the previous preview's area).
    private func restore(_ r: CGRect?) {
        guard let s = snap else { return }
        guard let r else { L.load(s); prevDirty = nil; mark(L.rect); return }
        let area = (prevDirty.map { $0.union(r) } ?? r).insetBy(dx: -2, dy: -2)
        L.load(s, rect: area)
        mark(area)
        prevDirty = r
    }

    private func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.move(to: pts[0])
        if pts.count < 3 {
            for q in pts.dropFirst() { p.addLine(to: q) }
            return p
        }
        for i in 1..<(pts.count - 1) {
            let mid = (pts[i] + pts[i + 1]) * 0.5
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    private func bbox(_ pts: [CGPoint], pad: CGFloat) -> CGRect {
        var r = CGRect(origin: pts[0], size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.insetBy(dx: -pad, dy: -pad)
    }

    private func selMode(_ f: NSEvent.ModifierFlags) -> SelectMode {
        if f.contains(.shift) && f.contains(.option) { return .intersect }
        if f.contains(.shift) { return .union }
        if f.contains(.option) { return .exclude }
        return st.selectMode
    }

    // MARK: Events

    func down(_ p: CGPoint, right: Bool, flags: NSEvent.ModifierFlags) {
        self.right = right
        tool = st.tool
        start = p; last = p
        points = [p]
        prevDirty = nil
        objectMove = nil; textMove = nil; shapeMove = nil; drawingShape = nil   // nothing left over from a cut-short drag
        flushShapeEdit()
        let paints: Set<ToolKind> = [.bucket, .gradient, .brush, .eraser, .pencil, .recolor, .line]
        if paints.contains(tool) && tool != .eraser { st.noteRecent(color) }
        let editsMask = tool == .eraser && L.object != nil && L.object?.vector == nil   // vector art erases as pixels
        // (Clone without a source does nothing, so it mustn't flatten anything either.)
        if L.isLive && !editsMask && (paints.contains(tool) || (tool == .clone && !flags.contains(.option) && cloneSource != nil)) {
            L.rasterize()   // painting on a text or object layer turns it into ordinary pixels
            doc.structureChanged()
        }
        switch tool {
        case .rectSelect, .ellipseSelect, .lasso:
            mode = selMode(flags)
            active = true
            previewPath = nil
        case .magicWand:
            wand(p, mode: selMode(flags))
        case .moveSelection, .moveSelected:
            beginTransform(p, right: right, flags: flags)
        case .zoom:
            canvas.controller?.zoomStep(in: !(right || flags.contains(.option)), at: p)
        case .pan:
            break
        case .bucket:
            bucket(p)
        case .shapes:
            shapeDown(p, right: right)
        case .gradient, .line:
            active = true
            snap = L.data()
        case .eraser where L.object != nil && L.object?.vector == nil:
            active = true
            let mb = MaskBrush(spec: L.object!, restore: right, opacity: st.brushOpacity, hardness: st.brushHardness)
            maskBrush = mb
            snap = L.data()
            mark(mb.add(p, size: brushSize, into: L))
        case .brush, .eraser:
            active = true
            let b = BrushStroke(layer: L, color: color, erase: tool == .eraser, opacity: st.brushOpacity,
                                hardness: st.brushHardness, antialias: st.antialias, selection: doc.selection)
            brush = b
            snap = b.snap
            mark(b.add(p, size: brushSize, into: L))
        case .pencil:
            active = true
            pencil(p, p)
        case .picker:
            pick(p)
        case .clone:
            if flags.contains(.option) {
                cloneSource = p
                canvas.needsDisplay = true
                return
            }
            guard let s = cloneSource else { NSSound.beep(); return }
            active = true
            snap = L.data()
            cloneImage = L.image()
            cloneOffset = s - p
            renderClone()
        case .recolor:
            active = true
            recolor(at: p)
        case .text:
            textDown(p)
        }
        flush()
    }

    func drag(_ p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard active else { return }
        switch tool {
        case .rectSelect, .ellipseSelect:
            let r = selectionRect(to: p)
            previewPath = tool == .rectSelect ? CGPath(rect: r.integral, transform: nil) : CGPath(ellipseIn: r, transform: nil)
        case .lasso:
            points.append(p)
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            previewPath = path
        case .moveSelection, .moveSelected:
            if objectMove != nil { dragObject(to: p, shift: flags.contains(.shift)) }
            else if shapeMove != nil { dragShape(to: p, shift: flags.contains(.shift)) }
            else if textMove != nil { dragTextLayer(to: p) } else if let s = session, let d = tdrag {
                d.apply(to: s, at: p, shift: flags.contains(.shift))
                renderTransform()
            }
        case .gradient:
            renderGradient(to: p)
        case .shapes:
            if shapeMove != nil { dragShape(to: p, shift: flags.contains(.shift)) } else { drawShape(to: p, square: flags.contains(.shift)) }
        case .line:
            renderLine(to: p, snapAngle: flags.contains(.shift))
        case .brush, .eraser:
            if let mb = maskBrush { mark(mb.add(p, size: brushSize, into: L)) }
            else if let b = brush { mark(b.add(p, size: brushSize, into: L)) }
        case .pencil:
            pencil(last, p)
        case .clone:
            points.append(p)
            renderClone()
        case .text:
            if movingText, let ed = text {
                ed.anchor = CGPoint(x: (p.x - textGrab.x).rounded(), y: (p.y - textGrab.y).rounded())
                ed.relayout()
            }
        case .recolor:
            let d = (p - last).length
            let step = max(1, st.brushWidth / 4)
            let n = max(1, Int(d / step))
            for i in 1...n { recolor(at: last + (p - last) * (CGFloat(i) / CGFloat(n))) }
        default:
            break
        }
        last = p
        flush()
    }

    func up(_ p: CGPoint, flags: NSEvent.ModifierFlags) {
        guard active else { return }
        active = false
        defer {
            snap = nil; previewPath = nil; prevDirty = nil
            cloneImage = nil; tdrag = nil; brush = nil; maskBrush = nil
            if movingText { movingText = false; if let v = text?.view { canvas.window?.makeFirstResponder(v) } }
            flush()
        }
        switch tool {
        case .rectSelect, .ellipseSelect, .lasso:
            finishSelection()
        case .moveSelection, .moveSelected:
            if objectMove != nil { finishObjectMove() } else if shapeMove != nil { finishShapeMove() } else if textMove != nil { finishTextMove() } else { finishTransformDrag() }
        case .eraser where maskBrush != nil:
            let spec = maskBrush!.finish()
            maskBrush = nil
            L.object = spec
            spec.render(into: L)
            mark(L.rect)
            doc.commit(right ? "Restore Mask" : "Erase Mask", symbol: tool.symbol)
        case .shapes:
            if shapeMove != nil { finishShapeMove() } else { finishDrawingShape() }
        case .gradient, .line, .brush, .eraser, .pencil, .clone, .recolor:
            doc.commit(tool.title, symbol: tool.symbol, recomposite: false)
        default:
            break
        }
    }

    /// Abort an in-progress drag (Escape).
    func cancel() {
        guard active else { return }
        active = false
        // Live layers being dragged go back to where they were, untouched.
        if let om = objectMove {
            objectMove = nil
            L.object = om.spec
            om.spec.render(into: L, clearing: om.ink.union(om.spec.extent))
            mark(om.ink.union(om.spec.extent)); flush()
            return
        }
        if let tm = textMove {
            textMove = nil
            L.text = tm.spec
            let ink = TextEditor.frame(of: tm.spec).insetBy(dx: -2, dy: -2)
            TextEditor.render(tm.spec, into: L, antialias: st.antialias, clearing: tm.ink.union(ink))
            mark(tm.ink.union(ink)); flush()
            return
        }
        if let sm = shapeMove {
            shapeMove = nil
            L.shape = sm.spec
            sm.spec.render(into: L, clearing: sm.ink.union(sm.spec.extent))
            mark(sm.ink.union(sm.spec.extent)); flush()
            return
        }
        if let ds = drawingShape {
            drawingShape = nil
            if let i = doc.layers.firstIndex(where: { $0 === ds.layer }) { doc.active = i; doc.deleteLayer() }
            doc.structureChanged()
            return
        }
        if let s = session, let d = tdrag {
            s.center = d.center; s.sx = d.sx; s.sy = d.sy; s.angle = d.angle
            renderTransform()
            tdrag = nil
            flush()
            return
        }
        if let s = snap { L.load(s) }
        snap = nil; previewPath = nil; brush = nil; maskBrush = nil
        dirtyArea = nil
        doc.pixelsChanged()
    }

    // MARK: Selection tools

    private func finishSelection() {
        let path: CGPath?
        switch tool {
        case .rectSelect:
            let r = selectionRect(to: last).integral
            path = r.width >= 1 && r.height >= 1 ? CGPath(rect: r, transform: nil) : nil
        case .ellipseSelect:
            let r = selectionRect(to: last)
            path = r.width >= 1 && r.height >= 1 ? CGPath(ellipseIn: r, transform: nil) : nil
        default:
            if points.count > 2 {
                let p = CGMutablePath()
                p.addLines(between: points)
                p.closeSubpath()
                path = p
            } else { path = nil }
        }
        guard let path else {
            if mode == .replace && doc.selection != nil {
                doc.selection = nil
                doc.commit("Deselect", symbol: "rectangle.slash", touch: .none)
            }
            return
        }
        let s = Selection.path(path, width: doc.width, height: doc.height, antialias: tool != .rectSelect)
        doc.selection = doc.selection.map { $0.combine(s, mode) } ?? s
        if doc.selection?.isEmpty == true { doc.selection = nil }
        doc.commit(tool.title, symbol: tool.symbol, touch: .none)
    }

    /// The rectangle being selected, honouring Fixed Ratio / Fixed Size.
    private func selectionRect(to p: CGPoint) -> CGRect {
        switch st.selectShape {
        case 1:
            let ratio = max(0.01, st.selectW) / max(0.01, st.selectH)
            let dx = p.x - start.x, dy = p.y - start.y
            let w = max(abs(dx), abs(dy) * ratio), h = w / ratio
            return CGRect(x: dx < 0 ? start.x - w : start.x, y: dy < 0 ? start.y - h : start.y, width: w, height: h)
        case 2:
            // Fixed size follows the pointer, centred on it.
            let w = max(1, st.selectW), h = max(1, st.selectH)
            return CGRect(x: (p.x - w / 2).rounded(), y: (p.y - h / 2).rounded(), width: w, height: h)
        default:
            return CGRect(p1: start, p2: p)
        }
    }

    private func wand(_ p: CGPoint, mode: SelectMode) {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < doc.width, y < doc.height else { return }
        if st.wandSubject {
            // Subject mode: the model's soft mask of the thing under the click, in canvas space.
            let img = st.sampleImage ? Layer.from(image: doc.composite(), name: "").image() : L.image()
            // Every image's revisions count from 0, so the composite's key names the document too.
            let key = st.sampleImage ? "c\(ObjectIdentifier(doc).hashValue).\(doc.revision)" : "r\(L.rev)"
            NSCursor.operationNotAllowed.push()
            defer { NSCursor.pop() }
            guard let map = SubjectMap.cached(img, key: key), let inst = map.instance(at: p),
                  let m = map.mask(IndexSet(integer: inst)), m.count == doc.width * doc.height else { NSSound.beep(); return }
            let s = Selection(width: doc.width, height: doc.height, mask: m)
            doc.selection = doc.selection.map { $0.combine(s, mode) } ?? s
            if doc.selection?.isEmpty == true { doc.selection = nil }
            doc.commit("Select Subject", symbol: ToolKind.magicWand.symbol, touch: .none)
            return
        }
        let src = st.sampleImage ? doc.compositeBytes() : UnsafePointer(L.bytes)
        let m = floodMask(src, w: doc.width, h: doc.height, x: x, y: y, tol: st.tolerance, global: st.floodGlobal)
        let s = Selection(width: doc.width, height: doc.height, mask: m)
        doc.selection = doc.selection.map { $0.combine(s, mode) } ?? s
        if doc.selection?.isEmpty == true { doc.selection = nil }
        doc.commit("Magic Wand Select", symbol: ToolKind.magicWand.symbol, touch: .none)
    }

    // MARK: Move, scale, rotate

    private var handleRadius: CGFloat { 7 / canvas.magnification }
    private var rotateRing: CGFloat { 36 / canvas.magnification }
    private var isMoveTool: Bool { st.tool == .moveSelected || st.tool == .moveSelection }

    /// The session for the current tool, if the document hasn't moved on since it last committed.
    private func liveSession() -> TransformSession? {
        guard let s = session, s.revision == doc.revision, s.layer == doc.active, s.onMask == doc.editingMask,
              s.pixels == (st.tool == .moveSelected) else { return nil }
        return s
    }

    /// Text layer the Move tool would grab at `p`: the active text's handles, or any text under it.
    private func textTarget(at p: CGPoint) -> (Int, Handle)? {
        if let spec = L.text, !handlesHidden {
            let f = TextEditor.frame(of: spec)
            for (ux, uy) in TransformSession.handles {
                let q = CGPoint(x: f.midX + CGFloat(ux) * f.width / 2, y: f.midY + CGFloat(uy) * f.height / 2)
                if (q - p).length <= handleRadius { return (doc.active, .scale(ux, uy)) }
            }
            if f.contains(p) { return (doc.active, .move) }
        }
        if let i = textLayer(at: p) { return (i, .move) }
        return nil
    }

    func pixelLayer(at p: CGPoint) -> Int? { layerWithPixels(at: p) }

    /// Topmost visible layer with a visible pixel at `p` (text layers count by their box instead).
    private func layerWithPixels(at p: CGPoint) -> Int? {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < doc.width, y < doc.height else { return nil }
        return doc.layers.indices.reversed().first { i in
            let l = doc.layers[i]
            return l.visible && l.text == nil && l.pixel(x, y).a > 8
        }
    }

    /// Text or object layer the Move tool would act on at `p`, and how: the active layer's
    /// handles first, then text under the pointer, then an object whose pixels are under it.
    private func liveTarget(at p: CGPoint) -> (Int, Handle)? {
        // 1. The selected layer's handles always win.
        let activeSession = handlesHidden ? nil : L.object?.session ?? L.shape?.session
        let activeHit = activeSession?.hit(p, radius: handleRadius, ring: rotateRing)
        if case .scale = activeHit { return (doc.active, activeHit!) }
        // 2. Otherwise what's on top under the pointer: text, then shapes, then image layers.
        if let t = textTarget(at: p) { return t }
        let top = layerWithPixels(at: p)
        let shapeHit = shapeLayer(at: p)
        if let i = shapeHit, top == nil || i >= top! { return (i, .move) }
        if let i = top, doc.layers[i].object != nil || doc.layers[i].shape != nil { return (i, .move) }
        // 3. The selected layer: inside its box moves it, the ring just outside rotates it.
        if let s = activeSession {
            let inside = s.bounds.contains(p.applying(s.transform.inverted()))
            if inside && (top == nil || top! <= doc.active) { return (doc.active, .move) }
            if !inside && activeHit == .rotate { return (doc.active, .rotate) }
        }
        return nil   // ordinary pixels: the pixel mover takes it
    }

    /// Move, resize or rotate an object layer by redrawing its original pixels.
    private func dragObject(to p: CGPoint, shift: Bool) {
        guard let om = objectMove else { return }
        var spec = om.spec
        let s = spec.session
        TransformDrag(handle: om.handle, start: om.start, center: s.center, sx: s.sx, sy: s.sy, angle: s.angle)
            .apply(to: s, at: p, shift: shift)
        spec.take(s)
        let ink = spec.extent
        L.object = spec
        spec.render(into: L, clearing: om.ink.union(ink))
        mark(om.ink.union(ink))
        objectMove?.ink = ink
    }

    private func finishObjectMove() {
        guard let om = objectMove else { return }
        objectMove = nil
        guard let spec = L.object, spec.center != om.spec.center || spec.sx != om.spec.sx || spec.sy != om.spec.sy
                || spec.angle != om.spec.angle else { return }
        let verb: String
        switch om.handle {
        case .move: verb = "Move"
        case .rotate: verb = "Rotate"
        case .scale: verb = "Resize"
        }
        doc.commit("\(verb) Layer", symbol: st.tool.symbol, recomposite: false)
    }

    /// What the handles would act on right now (no pixel copies; for drawing and hit tests).
    private func frameSession() -> TransformSession? {
        if st.tool == .shapes { return drawingShape == nil && shapeSelected ? L.shape?.session : nil }
        if let s = liveSession() { return s }
        guard isMoveTool else { return nil }
        if st.tool == .moveSelected, doc.selection == nil {
            // Without a selection, only an active text or object layer shows handles.
            if handlesHidden { return nil }
            if let o = L.object { return o.session }
            if let sh = L.shape { return sh.session }
            guard let spec = L.text else { return nil }
            let f = TextEditor.frame(of: spec)
            return TransformSession(pixels: false, layer: doc.active, bounds: f, base: nil, floating: nil, selection: nil,
                                    outline: CGPath(rect: f, transform: nil))
        }
        let b = doc.selection?.bounds ?? .null
        guard !b.isNull, !b.isEmpty else { return nil }
        return TransformSession(pixels: false, layer: doc.active, bounds: b, base: nil, floating: nil, selection: nil,
                                outline: CGPath(rect: b, transform: nil))
    }

    private func makeSession() -> TransformSession? {
        let pixels = st.tool == .moveSelected
        let sel = doc.selection
        if !pixels && sel == nil { return nil }
        let b = sel?.bounds ?? doc.fullRect
        guard !b.isEmpty else { return nil }
        var floatImg: CGImage?, base: Data?
        if pixels && L.isLive { L.rasterize() }   // moving some of a live layer's pixels makes it pixels
        if pixels {
            base = L.data()
            let tmp = Layer(width: L.width, height: L.height, name: "")
            tmp.ctx.saveGState()
            if let sel { tmp.ctx.clip(to: tmp.rect, mask: sel.image) }
            tmp.ctx.draw(L.liveImage(), in: tmp.rect)
            tmp.ctx.restoreGState()
            floatImg = tmp.image().cropping(to: b)
        }
        let s = TransformSession(pixels: pixels, layer: doc.active, bounds: b, base: base, floating: floatImg,
                                 selection: sel, outline: sel?.outline ?? CGPath(rect: b, transform: nil))
        s.revision = doc.revision
        s.onMask = doc.editingMask
        return s
    }

    private func beginTransform(_ p: CGPoint, right: Bool, flags: NSEvent.ModifierFlags) {
        // Clicking off a selection (not on it, its handles or its rotate ring) lets go of it.
        if doc.selection != nil, !right, let s = liveSession() ?? frameSession(),
           s.hit(p, radius: handleRadius, ring: rotateRing) == .move,
           !s.bounds.insetBy(dx: -1, dy: -1).contains(p.applying(s.transform.inverted())) {
            session = nil
            doc.selection = nil
            doc.commit("Deselect", symbol: "rectangle.slash", touch: .none)
            return
        }
        if st.tool == .moveSelected, doc.selection == nil {
            // No selection: act on what is under the pointer. Text first (the active text's handles,
            // then any text), then the topmost layer with pixels there; empty space lets go.
            if let (i, h0) = liveTarget(at: p) {
                letGo = nil
                if doc.active != i { doc.active = i; session = nil; doc.structureChanged() }
                if let spec = L.text {
                    let f = TextEditor.frame(of: spec)
                    textMove = (spec, f, h0, p, f.insetBy(dx: -2, dy: -2))
                } else if let spec = L.object {
                    objectMove = (spec, right ? .rotate : h0, p, spec.extent)
                } else if let spec = L.shape {
                    shapeMove = (spec, right ? .rotate : h0, p, spec.extent)
                }
                active = true
                return
            }
            // Clicking off the selected text, picture or shape onto empty space (nothing, or only the
            // bottom layer) deselects it; a second click there moves what's under the pointer, as before.
            let under = layerWithPixels(at: p)
            if L.isLive && !handlesHidden && (under == nil || under == 0) {
                letGo = L
                session = nil
                doc.overlayChanged()
                return
            }
            guard let i = layerWithPixels(at: p) else {
                if L.text != nil { session = nil; doc.overlayChanged() }
                return
            }
            if doc.active != i { doc.active = i; session = nil; doc.structureChanged() }
        }
        guard let s = liveSession() ?? makeSession() else { NSSound.beep(); return }
        session = s
        if flags.contains(.option) && s.pixels {
            // Leave a copy behind: the layer as it is now becomes the backdrop the pixels move over.
            s.base = L.data()
            s.clearOriginal = false
        }
        let h: Handle = right ? .rotate : s.hit(p, radius: handleRadius, ring: rotateRing)
        tdrag = TransformDrag(handle: h, start: p, center: s.center, sx: s.sx, sy: s.sy, angle: s.angle)
        active = true
    }

    /// Redraw the transformed pixels from the originals over the session's backdrop.
    private func renderTransform() {
        guard let s = session else { return }
        let ext = s.extent
        if s.pixels, let base = s.base, let f = s.floating {
            var area = s.lastExtent.union(ext)
            if s.clearOriginal { area = area.union(s.bounds.insetBy(dx: -2, dy: -2)) }
            area = area.intersection(L.rect).integral
            if !area.isEmpty {
                L.load(base, rect: area)
                let c = L.ctx, H = CGFloat(L.height)
                c.saveGState()
                c.clip(to: CGRect(x: area.minX, y: H - area.maxY, width: area.width, height: area.height))
                if s.clearOriginal {
                    c.saveGState()
                    if let sel = s.selection { c.clip(to: L.rect, mask: sel.image) }
                    c.clear(L.rect)
                    c.restoreGState()
                }
                c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
                c.concatenate(s.transform)
                c.interpolationQuality = s.isPureMove ? .none : .high
                c.setShouldAntialias(st.antialias)
                c.translateBy(x: s.bounds.minX, y: s.bounds.maxY); c.scaleBy(x: 1, y: -1)
                c.draw(f, in: CGRect(origin: .zero, size: s.bounds.size))
                c.restoreGState()
                mark(area)
            }
        }
        s.lastExtent = ext
    }

    private func finishTransformDrag() {
        guard let s = session, let d = tdrag else { return }
        guard s.center != d.center || s.sx != d.sx || s.sy != d.sy || s.angle != d.angle else { return }
        if s.selection != nil {
            doc.selection = s.transformedSelection(width: doc.width, height: doc.height)
            if doc.selection?.isEmpty == true { doc.selection = nil }
        }
        let verb: String
        switch d.handle {
        case .move: verb = "Move"
        case .rotate: verb = "Rotate"
        case .scale: verb = "Resize"
        }
        doc.commit(s.pixels ? "\(verb) Selected Pixels" : "\(verb) Selection", symbol: st.tool.symbol,
                   touch: s.pixels ? .active : .none)
        s.revision = doc.revision
    }

    /// Move or resize a text layer by re-laying out its text: it stays sharp and editable.
    private func dragTextLayer(to p: CGPoint) {
        guard let tm = textMove else { return }
        var spec = tm.spec
        switch tm.handle {
        case .move, .rotate:
            let d = p - tm.start
            spec.anchor = CGPoint(x: tm.spec.anchor.x + d.x.rounded(), y: tm.spec.anchor.y + d.y.rounded())
        case .scale(let ux, let uy):
            let probe = TransformSession(pixels: false, layer: 0, bounds: tm.frame, base: nil, floating: nil, selection: nil,
                                         outline: CGPath(rect: tm.frame, transform: nil))
            TransformDrag(handle: tm.handle, start: tm.start, center: probe.center, sx: 1, sy: 1, angle: 0)
                .apply(to: probe, at: p, shift: true)
            let k = ux != 0 && uy != 0 ? max(probe.sx, probe.sy) : (ux != 0 ? probe.sx : probe.sy)
            spec.fontSize = max(1, (tm.spec.fontSize * k * 2).rounded() / 2)
            let ks = spec.fontSize / tm.spec.fontSize
            spec.outlineWidth = (tm.spec.outlineWidth * ks * 2).rounded() / 2
            let opp = CGPoint(x: tm.frame.midX - CGFloat(ux) * tm.frame.width / 2, y: tm.frame.midY - CGFloat(uy) * tm.frame.height / 2)
            spec.anchor = CGPoint(x: (opp.x + (tm.spec.anchor.x - opp.x) * ks).rounded(), y: (opp.y + (tm.spec.anchor.y - opp.y) * ks).rounded())
        }
        let ink = TextEditor.frame(of: spec).insetBy(dx: -2, dy: -2)
        L.text = spec
        TextEditor.render(spec, into: L, antialias: st.antialias, clearing: tm.ink.union(ink))
        mark(tm.ink.union(ink))
        textMove?.ink = ink
    }

    private func finishTextMove() {
        guard let tm = textMove else { return }
        textMove = nil
        guard let spec = L.text, spec != tm.spec else { return }
        doc.commit(spec.fontSize != tm.spec.fontSize ? "Resize Text" : "Move Text", symbol: ToolKind.text.symbol, recomposite: false)
    }

    // MARK: Shape layers

    func shapeLayer(at p: CGPoint) -> Int? {
        doc.layers.indices.reversed().first { i in
            let l = doc.layers[i]
            return l.visible && (l.shape?.contains(p) ?? false)
        }
    }

    private func toolbarShape(frame: CGRect) -> ShapeSpec {
        ShapeSpec(kind: st.shape, frame: frame, style: st.fillStyle, width: st.brushWidth,
                  primary: st.primary, secondary: st.secondary, antialias: st.antialias)
    }

    /// Put a shape's style in the toolbar so editing starts from how it looks.
    private func loadShapeStyle(_ sp: ShapeSpec) {
        loadingShape = true
        st.shape = sp.kind; st.fillStyle = sp.style; st.brushWidth = sp.width; st.antialias = sp.antialias
        st.primary = sp.stroke
        if sp.style == .both { st.secondary = sp.fill } else if sp.style == .fill { st.primary = sp.fill }
        loadingShape = false
    }
    private var loadingShape = false

    /// Shapes tool click: grab the selected shape (or another shape under the pointer), else draw a new one.
    private func shapeDown(_ p: CGPoint, right: Bool) {
        active = true
        if let i = liveShapeHit(p) {
            shapeSelected = true
            if doc.active != i.0 { doc.active = i.0; doc.structureChanged() }
            let sp = L.shape!
            loadShapeStyle(sp)
            shapeMove = (sp, right ? .rotate : i.1, p, sp.extent)
            return
        }
        let l = Layer(width: doc.width, height: doc.height, name: st.shape.title)
        l.shape = toolbarShape(frame: CGRect(origin: p, size: .zero))
        doc.addLayer(l)
        drawingShape = (l, .null)
        doc.structureChanged()
    }

    private func liveShapeHit(_ p: CGPoint) -> (Int, Handle)? {
        if shapeSelected, let s = L.shape?.session {
            let h = s.hit(p, radius: handleRadius, ring: rotateRing)
            if case .scale = h { return (doc.active, h) }
            if s.bounds.contains(p.applying(s.transform.inverted())) { return (doc.active, .move) }
            if h == .rotate { return (doc.active, .rotate) }
        }
        if let i = shapeLayer(at: p) { return (i, .move) }
        return nil
    }

    private func drawShape(to p: CGPoint, square: Bool) {
        guard let ds = drawingShape, var sp = ds.layer.shape else { return }
        var r = CGRect(p1: start, p2: p)
        if square {
            let s = max(r.width, r.height)
            r = CGRect(x: p.x < start.x ? start.x - s : start.x, y: p.y < start.y ? start.y - s : start.y, width: s, height: s)
        }
        sp.frame = r
        ds.layer.shape = sp
        let ink = sp.extent
        sp.render(into: ds.layer, clearing: ds.ink.isNull ? ink : ds.ink.union(ink))
        mark(ds.ink.isNull ? ink : ds.ink.union(ink))
        drawingShape?.ink = ink
    }

    private func finishDrawingShape() {
        guard let ds = drawingShape else { return }
        drawingShape = nil
        guard let sp = ds.layer.shape, sp.frame.width >= 2, sp.frame.height >= 2,
              let i = doc.layers.firstIndex(where: { $0 === ds.layer }) else {
            if let i = doc.layers.firstIndex(where: { $0 === ds.layer }) { doc.active = i; doc.deleteLayer() }
            doc.structureChanged()
            return
        }
        doc.active = i
        shapeSelected = true
        doc.commit("Add \(sp.kind.title)", symbol: ToolKind.shapes.symbol, touch: .none)
    }

    private func dragShape(to p: CGPoint, shift: Bool) {
        guard let sm = shapeMove else { return }
        var sp = sm.spec
        let s = sp.session
        TransformDrag(handle: sm.handle, start: sm.start, center: s.center, sx: 1, sy: 1, angle: s.angle).apply(to: s, at: p, shift: shift)
        sp.take(s)
        let ink = sp.extent
        L.shape = sp
        sp.render(into: L, clearing: sm.ink.union(ink))
        mark(sm.ink.union(ink))
        shapeMove?.ink = ink
    }

    private func finishShapeMove() {
        guard let sm = shapeMove else { return }
        shapeMove = nil
        guard let sp = L.shape, sp != sm.spec else { return }
        let verb: String
        switch sm.handle {
        case .move: verb = "Move"
        case .rotate: verb = "Rotate"
        case .scale: verb = "Resize"
        }
        doc.commit("\(verb) Shape", symbol: ToolKind.shapes.symbol, recomposite: false)
    }

    /// Toolbar changed while a shape layer is selected with the Shapes tool: restyle it live.
    private func restyleShape() {
        guard st.tool == .shapes, shapeSelected, !active, !loadingShape, var sp = L.shape else { return }
        var n = sp
        n.kind = st.shape; n.style = st.fillStyle; n.width = st.brushWidth; n.antialias = st.antialias
        n.stroke = st.primary
        n.fill = st.fillStyle == .both ? st.secondary : st.primary
        guard n != sp else { return }
        let old = sp.extent
        sp = n
        L.shape = sp
        sp.render(into: L, clearing: old.union(sp.extent))
        doc.pixelsChanged(old.union(sp.extent))
        shapeEditTimer?.invalidate()
        shapeEditTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.flushShapeEdit() }
    }

    /// Return / Esc with the Shapes tool: let go of the selected shape.
    func deselectShape() {
        guard shapeSelected else { return }
        flushShapeEdit()
        shapeSelected = false
        doc.overlayChanged()
    }

    /// Record a pending toolbar edit to a shape as one history step.
    func flushShapeEdit() {
        guard let t = shapeEditTimer else { return }
        t.invalidate()
        shapeEditTimer = nil
        doc.commit("Edit Shape", symbol: ToolKind.shapes.symbol)
    }

    /// Double-click with a Move tool on text: start editing it.
    func editText(at p: CGPoint) -> Bool {
        guard let i = textLayer(at: p) else { return false }
        st.tool = .text
        beginEditing(layer: i, at: p)
        return true
    }

    /// Arrow keys with a Move tool: nudge by a pixel (⇧ ten).
    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        if st.tool == .moveSelected, doc.selection == nil, !active, var o = L.object {
            let old = o.extent
            o.center = CGPoint(x: o.center.x + dx, y: o.center.y + dy)
            L.object = o
            o.render(into: L, clearing: old.union(o.extent))
            mark(old.union(o.extent))
            doc.commit("Move Layer", symbol: st.tool.symbol)
            flush()
            return
        }
        // Text and shape layers move by their recipe, so they stay live (not turned into pixels).
        if st.tool == .moveSelected, doc.selection == nil, !active, var t = L.text {
            let old = TextEditor.frame(of: t).insetBy(dx: -2, dy: -2)
            t.anchor = CGPoint(x: t.anchor.x + dx, y: t.anchor.y + dy)
            L.text = t
            let ink = TextEditor.frame(of: t).insetBy(dx: -2, dy: -2)
            TextEditor.render(t, into: L, antialias: st.antialias, clearing: old.union(ink))
            mark(old.union(ink))
            doc.commit("Move Text", symbol: ToolKind.text.symbol)
            flush()
            return
        }
        if st.tool == .moveSelected, doc.selection == nil, !active, var sh = L.shape {
            let old = sh.extent
            sh.frame = sh.frame.offsetBy(dx: dx, dy: dy)
            L.shape = sh
            sh.render(into: L, clearing: old.union(sh.extent))
            mark(old.union(sh.extent))
            doc.commit("Move Layer", symbol: st.tool.symbol)
            flush()
            return
        }
        guard isMoveTool, !active, let s = liveSession() ?? makeSession() else { NSSound.beep(); return }
        session = s
        tdrag = TransformDrag(handle: .move, start: .zero, center: s.center, sx: s.sx, sy: s.sy, angle: s.angle)
        s.center = s.center + CGPoint(x: dx, y: dy)
        renderTransform()
        finishTransformDrag()
        tdrag = nil
        flush()
    }

    /// Return: finish the current transform so the next drag starts fresh from the pixels as they are.
    func finishTransform() { session = nil; doc.overlayChanged() }

    /// The selection outline to show while a transform drag is live.
    var liveOutline: CGPath? {
        guard tdrag != nil, let s = session, s.selection != nil else { return nil }
        var t = s.transform
        return s.outline.copy(using: &t)
    }

    /// Cursor for the pointer at `p`, when it depends on what is under it.
    func cursor(at p: CGPoint) -> NSCursor? {
        switch st.tool {
        case .moveSelected, .moveSelection, .shapes:
            if (st.tool == .moveSelected && doc.selection == nil && !handlesHidden) || (st.tool == .shapes && shapeSelected),
               let s = L.object?.session ?? L.shape?.session {
                switch s.hit(p, radius: handleRadius, ring: rotateRing) {
                case .scale(let ux, let uy):
                    let a = atan2(CGFloat(uy) * s.bounds.height * s.sy, CGFloat(ux) * s.bounds.width * s.sx) + s.angle
                    let key = (Int((a / (.pi / 12)).rounded()) % 12 + 12) % 12
                    if let c = resizeCursors[key] { return c }
                    let c = Cursors.resize(angle: CGFloat(key) * .pi / 12)
                    resizeCursors[key] = c
                    return c
                case .rotate where !s.bounds.contains(p.applying(s.transform.inverted())): return Cursors.rotate
                default: return st.tool.cursor
                }
            }
            if st.tool == .moveSelected, doc.selection == nil {
                if let (_, h) = textTarget(at: p), case .scale(let ux, let uy) = h, let spec = L.text {
                    let f = TextEditor.frame(of: spec)
                    let a = atan2(CGFloat(uy) * f.height, CGFloat(ux) * f.width)
                    let key = (Int((a / (.pi / 12)).rounded()) % 12 + 12) % 12
                    if let c = resizeCursors[key] { return c }
                    let c = Cursors.resize(angle: CGFloat(key) * .pi / 12)
                    resizeCursors[key] = c
                    return c
                }
                return st.tool.cursor
            }
            guard let s = frameSession() else { return nil }
            switch s.hit(p, radius: handleRadius, ring: rotateRing) {
            case .move: return st.tool.cursor
            case .rotate: return Cursors.rotate
            case .scale(let ux, let uy):
                let a = atan2(CGFloat(uy) * s.bounds.height * s.sy, CGFloat(ux) * s.bounds.width * s.sx) + s.angle
                let key = Int((a / (.pi / 12)).rounded()) % 12
                if let c = resizeCursors[key] { return c }
                let c = Cursors.resize(angle: CGFloat(key) * .pi / 12)
                resizeCursors[key] = c
                return c
            }
        case .text:
            guard let ed = text else { return nil }
            let m = 8 / canvas.magnification
            let inside = ed.outline.contains(p)
            return ed.inkRect.insetBy(dx: -m, dy: -m).contains(p) && !inside ? .openHand : nil
        default:
            return nil
        }
    }

    // MARK: Brushes

    private func pencil(_ a: CGPoint, _ b: CGPoint) {
        var x0 = Int(floor(a.x)), y0 = Int(floor(a.y))
        let x1 = Int(floor(b.x)), y1 = Int(floor(b.y))
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var err = dx + dy
        var px: [CGRect] = []
        while true {
            px.append(CGRect(x: x0, y: y0, width: 1, height: 1))
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x0 += sx }
            if e2 <= dx { err += dx; y0 += sy }
        }
        paint { c in
            c.setShouldAntialias(false)
            c.setFillColor(color.cg)
            c.fill(px)
        }
        mark(CGRect(p1: a, p2: b).insetBy(dx: -2, dy: -2))
    }

    private func renderClone() {
        guard let img = cloneImage else { return }
        let w = st.brushWidth
        restore(bbox(points, pad: w))
        let H = CGFloat(L.height), W = CGFloat(L.width)
        paint { c in
            if points.count == 1 {
                c.addEllipse(in: CGRect(x: points[0].x - w / 2, y: points[0].y - w / 2, width: w, height: w))
            } else {
                c.addPath(smoothPath(points).copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
            c.clip()
            c.scaleBy(x: 1, y: -1)
            c.translateBy(x: 0, y: -H)
            c.draw(img, in: CGRect(x: -cloneOffset.x, y: cloneOffset.y, width: W, height: H))
        }
    }

    private func recolor(at p: CGPoint) {
        let r = st.brushWidth / 2
        let w = L.width, h = L.height
        let x0 = max(0, Int(p.x - r)), x1 = min(w - 1, Int(p.x + r))
        let y0 = max(0, Int(p.y - r)), y1 = min(h - 1, Int(p.y + r))
        guard x0 <= x1, y0 <= y1 else { return }
        mark(CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1))
        let target = other, repl = color
        let limit = Int(st.tolerance * st.tolerance * 3 * 255 * 255)
        let b = L.bytes
        for y in y0...y1 {
            for x in x0...x1 {
                let ddx = CGFloat(x) + 0.5 - p.x, ddy = CGFloat(y) + 0.5 - p.y
                if ddx * ddx + ddy * ddy > r * r { continue }
                let m = Int(doc.selection?.mask[y * w + x] ?? 255)
                if m == 0 { continue }
                let i = (y * w + x) * 4
                let a = b[i + 3]
                if a == 0 { continue }
                let cr = Int(unpremul(b[i], a)), cg = Int(unpremul(b[i + 1], a)), cb = Int(unpremul(b[i + 2], a))
                let dr = cr - Int(target.r), dg = cg - Int(target.g), db = cb - Int(target.b)
                if dr * dr + dg * dg + db * db > limit { continue }
                let nr = cr + (Int(repl.r) - cr) * m / 255
                let ng = cg + (Int(repl.g) - cg) * m / 255
                let nb = cb + (Int(repl.b) - cb) * m / 255
                b[i] = premul(nr, Int(a)); b[i + 1] = premul(ng, Int(a)); b[i + 2] = premul(nb, Int(a))
            }
        }
    }

    // MARK: Fills, gradients, shapes

    private func bucket(_ p: CGPoint) {
        let x = Int(p.x), y = Int(p.y)
        guard x >= 0, y >= 0, x < doc.width, y < doc.height else { return }
        let src = st.sampleImage ? doc.compositeBytes() : UnsafePointer(L.bytes)
        var m = floodMask(src, w: doc.width, h: doc.height, x: x, y: y, tol: st.tolerance, global: st.floodGlobal)
        if let s = doc.selection { for i in 0..<m.count { m[i] = min(m[i], s.mask[i]) } }
        let mask = Selection(width: doc.width, height: doc.height, mask: m)
        let c = L.ctx
        c.saveGState()
        c.clip(to: L.rect, mask: mask.image)
        c.setFillColor(color.cg)
        c.fill(L.rect)
        c.restoreGState()
        mark(L.rect)
        doc.commit("Paint Bucket", symbol: ToolKind.bucket.symbol)
    }

    private func renderGradient(to p: CGPoint) {
        restore(nil)
        if st.gradientTransparency || st.gradient == .diamond || st.gradient == .conical {
            renderGradientPixels(to: p)
            return
        }
        let a = color.cg, b = other.cg
        paint { c in
            switch st.gradient {
            case .linear:
                let g = CGGradient(colorsSpace: sRGBSpace, colors: [a, b] as CFArray, locations: [0, 1])!
                c.drawLinearGradient(g, start: start, end: p, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .reflected:
                let g = CGGradient(colorsSpace: sRGBSpace, colors: [b, a, b] as CFArray, locations: [0, 0.5, 1])!
                c.drawLinearGradient(g, start: start - (p - start), end: p,
                                     options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            case .radial:
                let g = CGGradient(colorsSpace: sRGBSpace, colors: [a, b] as CFArray, locations: [0, 1])!
                c.drawRadialGradient(g, startCenter: start, startRadius: 0, endCenter: start,
                                     endRadius: max(1, (p - start).length), options: [.drawsAfterEndLocation])
            case .diamond, .conical:
                break   // drawn per pixel above
            }
        }
    }

    /// Gradients computed per pixel: Diamond and Conical shapes, and Transparency mode, which fades
    /// the layer's existing pixels from opaque at the start to clear at the end.
    private func renderGradientPixels(to p: CGPoint) {
        guard let s = snap else { return }
        let w = L.width, h = L.height
        let ux = p.x - start.x, uy = p.y - start.y
        let len2 = max(1, ux * ux + uy * uy), len = len2.squareRoot()
        let kind = st.gradient, transparency = st.gradientTransparency, reversed = right
        let a = color, b = other
        let sel = doc.selection?.mask
        let sx = start.x, sy = start.y
        func t(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            let dx = x - sx, dy = y - sy
            let along = (dx * ux + dy * uy) / len, across = (dx * -uy + dy * ux) / len
            switch kind {
            case .linear: return min(1, max(0, along / len))
            case .reflected: return min(1, abs(along) / len)
            case .radial: return min(1, (dx * dx + dy * dy).squareRoot() / len)
            case .diamond: return min(1, (abs(along) + abs(across)) / len)
            case .conical:
                var ang = atan2(across, along) / (2 * .pi)
                if ang < 0 { ang += 1 }
                return ang
            }
        }
        let dst = L.bytes
        s.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            parallelRows(h) { y in
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    var k = t(CGFloat(x) + 0.5, CGFloat(y) + 0.5)
                    let m = sel.map { Int($0[y * w + x]) } ?? 255
                    if m == 0 { continue }
                    if transparency {
                        // the start keeps the pixels, the end clears them (right-drag reverses)
                        k = min(1, max(0, k))
                        let keep = reversed ? k : 1 - k
                        let f = 1 - (1 - keep) * CGFloat(m) / 255
                        for c in 0..<4 { dst[i + c] = UInt8(CGFloat(src[i + c]) * f + 0.5) }
                    } else {
                        k = min(1, max(0, k))
                        let ca = (CGFloat(a.a) * (1 - k) + CGFloat(b.a) * k) * CGFloat(m) / 255
                        let cr = CGFloat(a.r) * (1 - k) + CGFloat(b.r) * k, cg = CGFloat(a.g) * (1 - k) + CGFloat(b.g) * k
                        let cb = CGFloat(a.b) * (1 - k) + CGFloat(b.b) * k
                        let inv = 1 - ca / 255
                        dst[i] = UInt8(min(255, cr * ca / 255 + CGFloat(src[i]) * inv + 0.5))
                        dst[i + 1] = UInt8(min(255, cg * ca / 255 + CGFloat(src[i + 1]) * inv + 0.5))
                        dst[i + 2] = UInt8(min(255, cb * ca / 255 + CGFloat(src[i + 2]) * inv + 0.5))
                        dst[i + 3] = UInt8(min(255, ca + CGFloat(src[i + 3]) * inv + 0.5))
                    }
                }
            }
        }
        mark(L.rect)
    }

    private func renderLine(to p: CGPoint, snapAngle: Bool) {
        var end = p
        if snapAngle {
            let d = p - start
            let step = CGFloat.pi / 12
            let ang = (atan2(d.y, d.x) / step).rounded() * step
            end = start + CGPoint(x: cos(ang), y: sin(ang)) * d.length
        }
        let w = st.brushWidth
        let head = max(w * 3.5, 10)
        restore(CGRect(p1: start, p2: end).insetBy(dx: -w - head, dy: -w - head))
        let d = end - start, len = max(0.001, d.length)
        let u = CGPoint(x: d.x / len, y: d.y / len), n = CGPoint(x: -u.y, y: u.x)
        let (as0, ae) = (st.arrowStart, st.arrowEnd)
        paint { c in
            c.setStrokeColor(color.cg); c.setFillColor(color.cg); c.setLineWidth(w); c.setLineCap(.round)
            // Stop the shaft inside each arrowhead so the tip stays sharp.
            let a = as0 ? start + u * (head * 0.6) : start, b = ae ? end - u * (head * 0.6) : end
            c.move(to: a); c.addLine(to: b); c.strokePath()
            func arrow(_ tip: CGPoint, _ dir: CGPoint) {
                let base = tip - dir * head
                c.move(to: tip)
                c.addLine(to: base + n * (head * 0.55)); c.addLine(to: base - n * (head * 0.55))
                c.closePath(); c.fillPath()
            }
            if as0 && len > 1 { arrow(start, CGPoint(x: -u.x, y: -u.y)) }
            if ae && len > 1 { arrow(end, u) }
        }
    }

    // MARK: Picker and text

    private func pick(_ p: CGPoint) {
        let x = Int(p.x), y = Int(p.y)
        let c = st.sampleImage ? doc.compositePixel(x, y) : L.pixel(x, y)
        if right { st.secondary = c } else { st.primary = c }
    }

    /// Text tool click: grab the live box by its frame, edit the text layer under the pointer,
    /// or start new text here.
    private func textDown(_ p: CGPoint) {
        if let ed = text {
            let m = 8 / canvas.magnification
            if ed.inkRect.insetBy(dx: -m, dy: -m).contains(p) {
                active = true
                movingText = true
                textGrab = p - ed.anchor
                return
            }
            finishText()
        }
        if let i = textLayer(at: p) { beginEditing(layer: i, at: p); return }
        var spec = st.textStyle(over: TextSpec())
        spec.anchor = p
        open(TextEditor(spec: spec))
    }

    /// Topmost visible text layer whose text is under `p`.
    func textLayer(at p: CGPoint) -> Int? {
        doc.layers.indices.reversed().first { i in
            let l = doc.layers[i]
            guard l.visible, let t = l.text else { return false }
            return TextEditor.frame(of: t).contains(p)
        }
    }

    private func open(_ ed: TextEditor) {
        ed.view.onFinish = { [weak self] in self?.finishText() }
        canvas.addSubview(ed.view)
        text = ed
        canvas.window?.makeFirstResponder(ed.view)
        doc.overlayChanged()
    }

    /// Reopen a text layer in the live editor; its pixels are hidden while the editor shows it.
    private func beginEditing(layer i: Int, at p: CGPoint?) {
        let l = doc.layers[i]
        guard let spec = l.text else { return }
        if doc.active != i { doc.active = i; doc.structureChanged() }
        st.loadTextStyle(spec)
        let ed = TextEditor(spec: spec)
        ed.layerIndex = i
        ed.layer = doc.layers[i]
        ed.original = spec
        l.fill(.clear)
        doc.pixelsChanged(ed.inkRect)
        open(ed)
        if let p { ed.placeCaret(at: p) } else { ed.view.setSelectedRange(NSRange(location: ed.storage.length, length: 0)) }
    }

    /// Toolbar or tool changed: restyle the live text, or finish it when leaving the Text tool.
    func styleChanged() {
        if !isMoveTool { session = nil }
        if st.tool == .shapes { restyleShape() } else { flushShapeEdit(); shapeSelected = false }
        guard let ed = text else { return }
        if st.tool != .text { finishText(); return }
        let old = ed.inkRect
        ed.spec = st.textStyle(over: ed.spec)
        ed.applyStyle()
        doc.pixelsChanged(old.union(ed.inkRect))
    }

    /// Finish the live text: it becomes (or updates) a text layer, recorded in history.
    func finishText() {
        guard let ed = text else { return }
        text = nil
        movingText = false
        ed.view.undoManager?.removeAllActions()
        let hadFocus = canvas.window?.firstResponder === ed.view
        ed.view.removeFromSuperview()
        if hadFocus { canvas.window?.makeFirstResponder(canvas) }
        let spec = ed.current
        // Find the layer by identity: undo or a history jump may have reordered the stack.
        if ed.layerIndex != nil, ed.original != nil, ed.layer.flatMap({ l in doc.layers.firstIndex { $0 === l } }) == nil {
            doc.overlayChanged()   // the layer it belonged to is gone; drop the edit rather than overwrite another
            return
        }
        if ed.layerIndex != nil, let lay = ed.layer, let i = doc.layers.firstIndex(where: { $0 === lay }), let original = ed.original {
            let l = doc.layers[i]
            let area = ed.inkRect.union(TextEditor.frame(of: original).insetBy(dx: -2, dy: -2))
            if ed.isEmpty && doc.layers.count > 1 {
                doc.active = i
                doc.deleteLayer()
                doc.commit("Delete Text", symbol: "minus.square", touch: .none)
                return
            }
            l.text = ed.isEmpty ? nil : spec
            if ed.isEmpty { l.fill(.clear); l.touch() } else { TextEditor.render(spec, into: l, antialias: st.antialias) }
            doc.pixelsChanged(area)
            if l.text != original { doc.commit("Edit Text", symbol: ToolKind.text.symbol, touch: .none) }
            return
        }
        guard !ed.isEmpty else { doc.overlayChanged(); return }
        let first = spec.string.split(separator: "\n").first.map(String.init) ?? "Text"
        let l = Layer(width: doc.width, height: doc.height, name: String(first.trimmingCharacters(in: .whitespaces).prefix(28)))
        l.text = spec
        TextEditor.render(spec, into: l, antialias: st.antialias)
        doc.addLayer(l)
        doc.pixelsChanged(ed.inkRect)
        doc.commit("Add Text", symbol: ToolKind.text.symbol, touch: .none)
    }

    // MARK: Overlay

    func drawOverlay(_ c: CGContext, lw: CGFloat) {
        if let p = previewPath { canvas.drawAnts(c, path: p, offset: .zero) }
        if let s = frameSession() {
            c.saveGState()
            // White on a black underline, square grips: the house look's frame.
            c.addPath(s.quad)
            c.setStrokeColor(CGColor(gray: 0, alpha: 0.7)); c.setLineWidth(lw * 3)
            c.strokePath()
            c.addPath(s.quad)
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); c.setLineWidth(lw)
            c.strokePath()
            let r = 4 * lw
            for (ux, uy) in TransformSession.handles {
                let q = s.point(ux, uy)
                let grip = CGRect(x: q.x - r, y: q.y - r, width: r * 2, height: r * 2)
                c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(grip)
                c.setStrokeColor(CGColor(gray: 0, alpha: 1)); c.setLineWidth(lw)
                c.stroke(grip)
            }
            c.restoreGState()
        }
        if let ed = text {
            let f0 = ed.boxFrame.insetBy(dx: -4 * lw, dy: -4 * lw)
            var rt = ed.rotationTransform
            canvas.drawAnts(c, path: CGPath(rect: f0, transform: &rt), offset: .zero)
            let k = 7 * lw
            let corner = CGPoint(x: f0.maxX, y: f0.maxY).applying(rt)
            let grip = CGRect(x: corner.x - k / 2, y: corner.y - k / 2, width: k, height: k)
            c.saveGState()
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(grip)
            c.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); c.setLineWidth(lw); c.stroke(grip)
            c.restoreGState()
        }
        if st.tool.showsBrushCursor, let h = hover {
            let w = max(1, st.brushWidth)
            let r = CGRect(x: h.x - w / 2, y: h.y - w / 2, width: w, height: w)
            c.saveGState()
            c.setLineWidth(lw * 1.5); c.setStrokeColor(CGColor(gray: 0, alpha: 0.8)); c.strokeEllipse(in: r)
            c.setLineWidth(lw * 0.75); c.setStrokeColor(CGColor(gray: 1, alpha: 0.9)); c.strokeEllipse(in: r)
            c.restoreGState()
        }
        if st.tool == .clone, let s = cloneSource {
            let at = active ? last + cloneOffset : s
            let k = 6 * lw
            c.saveGState()
            c.setLineWidth(lw * 1.5); c.setStrokeColor(CGColor(srgbRed: 1, green: 0.2, blue: 0.4, alpha: 1))
            c.move(to: at - CGPoint(x: k, y: 0)); c.addLine(to: at + CGPoint(x: k, y: 0))
            c.move(to: at - CGPoint(x: 0, y: k)); c.addLine(to: at + CGPoint(x: 0, y: k))
            c.strokePath()
            c.restoreGState()
        }
        if active && tool == .gradient {
            c.saveGState()
            c.setLineWidth(lw); c.setStrokeColor(CGColor(gray: 0.5, alpha: 0.9))
            c.move(to: start); c.addLine(to: last); c.strokePath()
            for q in [start, last] {
                c.setFillColor(CGColor(gray: 1, alpha: 1))
                c.fillEllipse(in: CGRect(x: q.x - 4 * lw, y: q.y - 4 * lw, width: 8 * lw, height: 8 * lw))
                c.strokeEllipse(in: CGRect(x: q.x - 4 * lw, y: q.y - 4 * lw, width: 8 * lw, height: 8 * lw))
            }
            c.restoreGState()
        }
    }
}

/// Scanline flood fill. Returns a 0/255 mask. `tol` is 0...1 over RGBA distance.
func floodMask(_ px: UnsafePointer<UInt8>, w: Int, h: Int, x: Int, y: Int, tol: Double, global: Bool) -> [UInt8] {
    var mask = [UInt8](repeating: 0, count: w * h)
    let i0 = (y * w + x) * 4
    let sr = Int(px[i0]), sg = Int(px[i0 + 1]), sb = Int(px[i0 + 2]), sa = Int(px[i0 + 3])
    let limit = Int(tol * tol * 4 * 255 * 255)
    @inline(__always) func match(_ i: Int) -> Bool {
        let j = i * 4
        let dr = Int(px[j]) - sr, dg = Int(px[j + 1]) - sg, db = Int(px[j + 2]) - sb, da = Int(px[j + 3]) - sa
        return dr * dr + dg * dg + db * db + da * da <= limit
    }
    mask.withUnsafeMutableBufferPointer { m in
        if global {
            for i in 0..<(w * h) where match(i) { m[i] = 255 }
            return
        }
        var stack = [(x, y)]
        while let (sx, sy) = stack.popLast() {
            let row = sy * w
            if m[row + sx] != 0 { continue }
            var lx = sx, rx = sx
            while lx > 0 && m[row + lx - 1] == 0 && match(row + lx - 1) { lx -= 1 }
            while rx < w - 1 && m[row + rx + 1] == 0 && match(row + rx + 1) { rx += 1 }
            for i in lx...rx { m[row + i] = 255 }
            for ny in [sy - 1, sy + 1] where ny >= 0 && ny < h {
                let nrow = ny * w
                var i = lx
                while i <= rx {
                    if m[nrow + i] == 0 && match(nrow + i) {
                        stack.append((i, ny))
                        while i <= rx && m[nrow + i] == 0 && match(nrow + i) { i += 1 }
                    } else { i += 1 }
                }
            }
        }
    }
    return mask
}
