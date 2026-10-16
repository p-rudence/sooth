import AppKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let doc: Document
    private(set) var canvas: CanvasView!
    private var scroll: NSScrollView!
    private var layersPanel: LayersPanel!
    private var historyPanel: HistoryPanel!
    private var statusBar: StatusBar!
    private var lastFilter: (Filter, [Double])?
    private(set) var recovery: Recovery!
    private var observers: [Any] = []
    private var lookObserver: Any?
    private var titleBar: TitleBarView?

    init(doc: Document) {
        self.doc = doc
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.tabbingMode = .preferred
        w.isRestorable = false
        w.tabbingIdentifier = "SoothImage"
        w.minSize = NSSize(width: 760, height: 800)   // the side panels need about 760 of content
        w.isReleasedWhenClosed = false
        // The suite window: black, no title bar ink (the name lives in the status line). Other looks dress it their way.
        dressWindow(w)
        super.init(window: w)
        w.delegate = self
        buildUI()
        lookObserver = NotificationCenter.default.addObserver(forName: .lookChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyLook()
        }
        recovery = Recovery(doc: doc)
        doc.onPixels = { [weak self] r in
            guard let c = self?.canvas else { return }
            if let r { c.setNeedsDisplay(r.insetBy(dx: -2, dy: -2)) } else { c.needsDisplay = true }
        }
        doc.onOverlay = { [weak self] in self?.canvas.overlay?.needsDisplay = true }
        doc.onStructure = { [weak self] in self?.structureChanged() }
        structureChanged()
        w.center()
        DispatchQueue.main.async { self.zoomFit(nil) }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// A panel under its name, with any buttons for it on the right of that line.
    private func titled(_ title: String, _ v: NSView, _ buttons: [Strip.Part] = []) -> NSView {
        PanelBox(title: title, body: v, buttons: buttons)
    }

    /// The look changed: dress the window again and rebuild every panel in the new look, keeping the view.
    private func applyLook() {
        guard let w = window else { return }
        canvas.engine.finishText()
        canvas.engine.finishTransform()
        let mag = scroll.magnification
        let mid = CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        dressWindow(w)
        buildUI()
        structureChanged()
        w.layoutIfNeeded()
        setZoom(mag, at: mid)
    }

    private func buildUI() {
        guard let w = window else { return }
        let content = LookBackdrop()
        w.contentView = content
        let top: NSLayoutYAxisAnchor
        if Look.current.ownsTitleBar {
            let bar = TitleBarView()
            bar.title = doc.displayName
            bar.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: content.topAnchor),
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: TitleBarView.height),
            ])
            titleBar = bar
            top = bar.bottomAnchor
        } else {
            titleBar = nil
            top = content.topAnchor
        }

        canvas = CanvasView(doc: doc)
        canvas.controller = self
        scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 64
        scroll.backgroundColor = Ink.canvas
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = Look.current != .glass   // Glass paints its sky in the clip view
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.statusChanged()
            self?.canvas.overlay?.needsDisplay = true
        })
        observers.append(NotificationCenter.default.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.window?.invalidateCursorRects(for: self.canvas)
            self.canvas.engine.styleChanged()
            self.canvas.needsDisplay = true
        })

        let options = OptionsBar()
        let palette = ToolPaletteView()
        layersPanel = LayersPanel(doc: doc)
        layersPanel.controller = self
        historyPanel = HistoryPanel(doc: doc)
        historyPanel.controller = self
        statusBar = StatusBar()
        statusBar.onZoomIn = { [weak self] in self?.zoomIn(nil) }
        statusBar.onZoomOut = { [weak self] in self?.zoomOut(nil) }
        statusBar.onFit = { [weak self] in self?.zoomFit(nil) }

        let c = { [weak self] in self }
        let colors = titled("colours", ColorsPanel())
        let layers = titled("layers", layersPanel, [.button("mask", tip: "Add a layer mask (from the selection, if any); ⌘\\ switches painting between mask and layer") {
                                                         if c()?.doc.activeLayer.mask == nil { c()?.addLayerMask(nil) } else { c()?.toggleMaskEditing(nil) }
                                                     }, .text(" "),
                                                     .button("remove bg", tip: "Cut the subject out of this layer (⌥⌘B); run it again to re-tune") { c()?.removeBackground(nil) }, .text(" "),
                                                     .button("props", tip: "Layer Properties… (or double-click a layer)") { c()?.layerProperties(nil) }])
        let history = titled("history", historyPanel, [.button("undo", tip: "Undo (⌘Z)") { c()?.doUndo(nil) }, .text(" "),
                                                       .button("redo", tip: "Redo (⇧⌘Z)") { c()?.doRedo(nil) }])
        let side = QuietSplitView()
        side.isVertical = false
        side.dividerStyle = .thin
        side.addArrangedSubview(colors)
        side.addArrangedSubview(layers)
        side.addArrangedSubview(history)
        colors.heightAnchor.constraint(equalToConstant: Look.current == .tianmu ? 292 : 284).isActive = true
        layers.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        // Extra height goes to Layers first; History keeps a useful strip.
        history.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        side.setHoldingPriority(.init(260), forSubviewAt: 0)
        side.setHoldingPriority(.init(240), forSubviewAt: 1)
        side.setHoldingPriority(.init(250), forSubviewAt: 2)

        let l1 = Hairline(vertical: false), l2 = Hairline(vertical: false), l3 = Hairline(vertical: true), l4 = Hairline(vertical: true)
        let overlay = CanvasOverlay(canvas: canvas)
        for v in [options, palette, scroll!, overlay, side, statusBar!, l1, l2, l3, l4] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            options.topAnchor.constraint(equalTo: top),
            options.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            options.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            l1.topAnchor.constraint(equalTo: options.bottomAnchor),
            l1.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            l1.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            palette.topAnchor.constraint(equalTo: l1.bottomAnchor),
            palette.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            palette.bottomAnchor.constraint(equalTo: l2.topAnchor),
            l3.topAnchor.constraint(equalTo: l1.bottomAnchor),
            l3.bottomAnchor.constraint(equalTo: l2.topAnchor),
            l3.leadingAnchor.constraint(equalTo: palette.trailingAnchor),
            l3.widthAnchor.constraint(equalToConstant: Chrome.ruleWidth),

            scroll.topAnchor.constraint(equalTo: l1.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: l3.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: l2.topAnchor),
            overlay.topAnchor.constraint(equalTo: scroll.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            l4.topAnchor.constraint(equalTo: l1.bottomAnchor),
            l4.bottomAnchor.constraint(equalTo: l2.topAnchor),
            l4.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            l4.widthAnchor.constraint(equalToConstant: Chrome.ruleWidth),

            side.topAnchor.constraint(equalTo: l1.bottomAnchor),
            side.leadingAnchor.constraint(equalTo: l4.trailingAnchor),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            side.bottomAnchor.constraint(equalTo: l2.topAnchor),
            side.widthAnchor.constraint(equalToConstant: Look.current == .tianmu ? 288 : 336),

            l2.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            l2.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            l2.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.initialFirstResponder = canvas
    }

    // MARK: State refresh

    func structureChanged() {
        canvas.sizeToDocument()
        canvas.needsDisplay = true
        layersPanel.reload()
        historyPanel.reload()
        updateTitle()
        statusChanged()
    }

    func updateTitle() {
        window?.title = doc.displayName
        titleBar?.title = doc.displayName
        window?.representedURL = doc.fileURL
        window?.isDocumentEdited = doc.dirty
        statusBar.name = doc.displayName
        statusBar.dirty = doc.dirty
    }

    func statusChanged() {
        statusBar.size = "\(doc.width)×\(doc.height)"
        if let b = doc.selection?.bounds, !b.isEmpty {
            statusBar.sel = "\(Int(b.width))×\(Int(b.height))"
        } else {
            statusBar.sel = ""
        }
        statusBar.zoom = "\(Int((scroll.magnification * 100).rounded()))%"
    }

    func updateCursor(_ p: CGPoint?) {
        statusBar.pos = p.map { "\(Int(floor($0.x))),\(Int(floor($0.y)))" } ?? ""
    }

    // MARK: Zoom

    static let zoomLevels: [CGFloat] = [0.02, 0.05, 0.1, 0.125, 0.166, 0.25, 0.33, 0.5, 0.66, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64]

    func setZoom(_ m: CGFloat, at p: CGPoint? = nil) {
        let m = min(64, max(0.02, m))
        let c = p ?? CGPoint(x: canvas.visibleRect.midX, y: canvas.visibleRect.midY)
        scroll.setMagnification(m, centeredAt: c)
        statusChanged()
        canvas.needsDisplay = true
    }

    func zoomStep(in zoomIn: Bool, at p: CGPoint? = nil) {
        let m = scroll.magnification
        let lv = Self.zoomLevels
        let next = zoomIn ? (lv.first { $0 > m * 1.01 } ?? 64) : (lv.last { $0 < m * 0.99 } ?? 0.02)
        setZoom(next, at: p)
    }

    @objc func zoomIn(_ s: Any?) { zoomStep(in: true) }
    @objc func zoomOut(_ s: Any?) { zoomStep(in: false) }
    @objc func actualSize(_ s: Any?) { setZoom(1) }
    @objc func zoomFit(_ s: Any?) {
        let avail = scroll.contentSize
        let m = min(avail.width / CGFloat(doc.width), avail.height / CGFloat(doc.height)) * 0.94
        setZoom(min(1, m), at: CGPoint(x: CGFloat(doc.width) / 2, y: CGFloat(doc.height) / 2))
    }
    @objc func toggleGrid(_ s: Any?) { canvas.showGrid.toggle() }

    // MARK: History

    @objc func doUndo(_ s: Any?) {
        guard !canvas.engine.isDragging else { NSSound.beep(); return }
        if let ed = canvas.engine.text, let um = ed.view.undoManager, um.canUndo { um.undo(); return }
        canvas.engine.finishText()
        doc.undo()
    }
    @objc func doRedo(_ s: Any?) {
        guard !canvas.engine.isDragging else { NSSound.beep(); return }
        if let ed = canvas.engine.text, let um = ed.view.undoManager, um.canRedo { um.redo(); return }
        canvas.engine.finishText()
        doc.redo()
    }

    // MARK: Saving

    @objc func saveDocument(_ s: Any?) { canvas.engine.finishText();
        if let u = doc.fileURL, let f = doc.fileFormat {
            save(to: u, format: f)
        } else {
            saveDocumentAs(s)
        }
    }

    @objc func saveDocumentAs(_ s: Any?) { canvas.engine.finishText();
        guard let win = window else { return }
        let panel = NSSavePanel()
        var fmt = doc.fileFormat ?? (doc.layers.count > 1 ? .sooth : .png)
        panel.allowedContentTypes = [fmt.utType]
        panel.nameFieldStringValue = ((doc.fileURL?.deletingPathExtension().lastPathComponent) ?? "Untitled") + "." + fmt.ext
        let q = NSSlider(value: Double(AppState.shared.exportQuality * 100), minValue: 1, maxValue: 100, target: nil, action: nil)
        q.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let qv = label("\(Int(AppState.shared.exportQuality * 100))%")
        qv.widthAnchor.constraint(equalToConstant: 40).isActive = true
        q.onAction { c in AppState.shared.exportQuality = CGFloat(c.doubleValue / 100); qv.stringValue = "\(Int(c.doubleValue))%" }
        let qualityRow = NSStackView(views: [label("Quality:"), q, qv])
        let pop = popup(SaveFormat.allCases.map(\.title), selected: fmt.rawValue) { i in
            fmt = SaveFormat(rawValue: i)!
            panel.allowedContentTypes = [fmt.utType]
            qualityRow.isHidden = !(fmt == .jpeg || fmt == .heic)
        }
        pop.controlSize = .regular
        qualityRow.isHidden = !(fmt == .jpeg || fmt == .heic)
        let acc = NSStackView(views: [NSStackView(views: [label("Format:"), pop]), qualityRow])
        acc.orientation = .vertical
        acc.alignment = .leading
        acc.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        acc.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: 64))
        panel.accessoryView = acc
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK, let url = panel.url else { return }
            self.save(to: url, format: fmt)
        }
    }

    /// File ▸ Share…: AirDrop, Messages, Mail and friends get the flattened image.
    @objc func shareImage(_ s: Any?) { canvas.engine.finishText();
        let name = (doc.fileURL?.deletingPathExtension().lastPathComponent ?? doc.displayName.replacingOccurrences(of: ".sooth", with: "").replacingOccurrences(of: ".easel", with: ""))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        guard let data = try? Document.encode(doc.composite(), as: .png), (try? data.write(to: url, options: .atomic)) != nil,
              let view = window?.contentView else { NSSound.beep(); return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    @discardableResult
    func save(to url: URL, format: SaveFormat) -> Bool {
        do {
            try doc.save(to: url, format: format)
            doc.fileURL = url
            doc.fileFormat = format
            // A flat format (PNG, JPEG…) can't hold layers or live text: the file is written, but the
            // image still has things only an .sooth file keeps, so closing it should still ask.
            let flatLoses = format != .sooth && (doc.layers.count > 1 || doc.layers.contains { $0.isLive })
            doc.dirty = flatLoses
            if !flatLoses { recovery.discard() }
            updateTitle()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.engine.finishText()
        return confirmClose()
    }

    /// Returns true if the window may close (saved, discarded, or clean).
    func confirmClose() -> Bool {
        guard doc.dirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let r = Dialogs.ask("Save changes to “\(doc.displayName)”?",
                            info: "Your changes will be lost if you don't save them.",
                            buttons: ["Save", "Cancel", "Don't Save"])
        switch r {
        case 0:
            // A flat file (PNG, JPEG…) can't keep layers or live text: saving over it would quietly lose them.
            let loses = doc.layers.count > 1 || doc.layers.contains { $0.isLive }
            if let u = doc.fileURL, let f = doc.fileFormat, f == .sooth || !loses { return save(to: u, format: f) }
            let panel = NSSavePanel()
            let fmt: SaveFormat = loses ? .sooth : .png
            panel.allowedContentTypes = [fmt.utType]
            let base = doc.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
            panel.nameFieldStringValue = base + "." + fmt.ext
            if doc.fileURL != nil {
                panel.message = "“\(doc.displayName)” can't keep layers or live text. Save them in a layered Sooth file."
            }
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return save(to: url, format: SaveFormat.from(url: url) ?? fmt)
        case 2: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        recovery.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let lookObserver { NotificationCenter.default.removeObserver(lookObserver) }
        (NSApp.delegate as? AppDelegate)?.closed(self)
    }

    // MARK: Clipboard

    private func selectedImage(merged: Bool) -> CGImage? {
        let src = merged ? doc.composite() : doc.paintTarget.image()   // the mask, while painting the mask
        let sel = doc.selection
        let b = sel?.bounds ?? doc.fullRect
        guard !b.isEmpty else { return nil }
        let out = Layer(width: Int(b.width), height: Int(b.height), name: "")
        let r = CGRect(x: -b.minX, y: b.minY + b.height - CGFloat(doc.height), width: CGFloat(doc.width), height: CGFloat(doc.height))
        out.ctx.saveGState()
        if let sel { out.ctx.clip(to: r, mask: sel.image) }
        out.ctx.draw(src, in: r)
        out.ctx.restoreGState()
        return out.image()
    }

    private func put(_ img: CGImage) {
        let rep = NSBitmapImageRep(cgImage: img)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let png = rep.representation(using: .png, properties: [:]) { pb.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
    }

    private func pastedImage() -> CGImage? {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d), let cg = rep.cgImage {
            return cg
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let u = urls.first,
           let d = try? Document.load(url: u) {
            return d.composite()   // the same path as opening it, so phone photos come in upright
        }
        guard let img = NSImage(pasteboard: pb) else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    @objc func copy(_ s: Any?) { canvas.engine.finishText(); if let i = selectedImage(merged: false) { put(i) } }
    @objc func copyMerged(_ s: Any?) { canvas.engine.finishText(); if let i = selectedImage(merged: true) { put(i) } }
    @objc func cut(_ s: Any?) { canvas.engine.finishText();
        guard let i = selectedImage(merged: false) else { return }
        put(i)
        eraseSelection(nil, name: "Cut")
    }

    @objc func paste(_ s: Any?) { canvas.engine.finishText(); pasteNewLayer(s) }

    @objc func pasteNewLayer(_ s: Any?) { canvas.engine.finishText();
        guard let img = pastedImage() else { NSSound.beep(); return }
        guard let grew = fitCanvas(to: img) else { return }
        // Centre it in view (inside the canvas), as a movable object layer.
        let vis = canvas.visibleRect.intersection(doc.fullRect)
        let l = Layer(width: doc.width, height: doc.height, name: doc.nextLayerName())
        let spec = ObjectSpec(source: img, center: placement(of: img, near: CGPoint(x: vis.midX, y: vis.midY)))
        l.object = spec
        spec.render(into: l)
        doc.addLayer(l)
        doc.selection = nil
        doc.commit("Paste", symbol: "doc.on.clipboard", touch: .none)
        AppState.shared.tool = .moveSelected
        if grew { zoomFit(nil) }
    }

    /// An image bigger than the canvas: ask whether to grow the canvas to fit it.
    /// Returns nil on Cancel, else whether the canvas grew. A fresh blank canvas takes the image's size exactly.
    func fitCanvas(to img: CGImage) -> Bool? {
        guard img.width > doc.width || img.height > doc.height else { return false }
        let pristine = doc.fileURL == nil && !doc.dirty && doc.history.count == 1
        let w = pristine ? img.width : max(doc.width, img.width), h = pristine ? img.height : max(doc.height, img.height)
        guard Limits.ok(w, h) else { return false }
        let r = Dialogs.ask("This image is bigger than the canvas.",
                            info: "It's \(img.width)×\(img.height); the canvas is \(doc.width)×\(doc.height). Make the canvas \(w)×\(h) so it fits?",
                            buttons: ["Fit Canvas", "Keep Size", "Cancel"])
        if r == 2 { return nil }
        guard r == 0 else { return false }
        doc.canvasSize(width: w, height: h, anchorX: 0.5, anchorY: 0.5, fill: AppState.shared.secondary)
        return true
    }

    /// Where an image goes: centred on `p`, but kept inside the canvas (centred where it's too big).
    private func placement(of img: CGImage, near p: CGPoint) -> CGPoint {
        func axis(_ c: CGFloat, _ size: Int, _ limit: Int) -> CGFloat {
            let half = CGFloat(size) / 2
            let v = size >= limit ? CGFloat(limit) / 2 : min(max(c.rounded(), half), CGFloat(limit) - half)
            return (v - half).rounded() + half
        }
        return CGPoint(x: axis(p.x, img.width, doc.width), y: axis(p.y, img.height, doc.height))
    }

    @objc func pasteNewImage(_ s: Any?) { canvas.engine.finishText();
        guard let img = pastedImage() else { NSSound.beep(); return }
        guard Limits.ok(img.width, img.height) else { Limits.tooBig(); return }
        let d = Document(layers: [Layer.from(image: img, name: "Background")])
        d.dirty = true   // never saved anywhere: closing it should ask, and recovery should keep it
        (NSApp.delegate as? AppDelegate)?.show(d)
    }

    // MARK: Selection

    @objc override func selectAll(_ s: Any?) { canvas.engine.finishText();
        doc.selection = Selection.all(doc.width, doc.height)
        doc.commit("Select All", symbol: "checkmark.rectangle", touch: .none)
    }

    @objc func deselect(_ s: Any?) { canvas.engine.finishText();
        guard doc.selection != nil else { return }
        doc.selection = nil
        doc.commit("Deselect", symbol: "rectangle.slash", touch: .none)
    }

    @objc func invertSelection(_ s: Any?) { canvas.engine.finishText();
        doc.selection = (doc.selection ?? Selection(width: doc.width, height: doc.height,
                                                     mask: [UInt8](repeating: 0, count: doc.width * doc.height))).inverted()
        doc.commit("Invert Selection", symbol: "rectangle.on.rectangle.angled", touch: .none)
    }

    @objc func eraseSelection(_ s: Any?) { canvas.engine.finishText(); eraseSelection(s, name: "Erase Selection") }

    private func eraseSelection(_ s: Any?, name: String) {
        let L = doc.paintTarget
        L.rasterize()
        L.ctx.saveGState()
        if let sel = doc.selection { L.ctx.clip(to: L.rect, mask: sel.image) }
        L.ctx.clear(L.rect)
        L.ctx.restoreGState()
        doc.commit(name, symbol: "eraser")
    }

    @objc func fillSelection(_ s: Any?) { canvas.engine.finishText();
        let L = doc.paintTarget
        L.rasterize()
        L.ctx.saveGState()
        if let sel = doc.selection { L.ctx.clip(to: L.rect, mask: sel.image) }
        L.ctx.setFillColor(AppState.shared.primary.cg)
        L.ctx.fill(L.rect)
        L.ctx.restoreGState()
        doc.commit("Fill Selection", symbol: "drop.fill")
    }

    // MARK: Image menu

    @objc func cropToSelection(_ s: Any?) { canvas.engine.finishText();
        guard let sel = doc.selection, !sel.isEmpty else { NSSound.beep(); return }
        doc.crop(to: sel)
        doc.commit("Crop to Selection", symbol: "crop", touch: .none)
        zoomFit(nil)
    }

    /// Image ▸ Auto-Crop: trim transparent edges, or edges of one flat colour.
    @objc func autoCrop(_ s: Any?) { canvas.engine.finishText();
        let w = doc.width, h = doc.height
        let px = doc.compositeBytes()
        let c0 = (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
        func same(_ i: Int) -> Bool {
            let j = i * 4
            if c0.3 == 0 { return px[j + 3] == 0 }
            return abs(Int(px[j]) - c0.0) + abs(Int(px[j + 1]) - c0.1) + abs(Int(px[j + 2]) - c0.2) + abs(Int(px[j + 3]) - c0.3) <= 24
        }
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where !same(y * w + x) {
            if x < x0 { x0 = x }; if x > x1 { x1 = x }; if y < y0 { y0 = y }; if y > y1 { y1 = y }
        } }
        guard x1 >= 0, x1 - x0 + 1 < w || y1 - y0 + 1 < h else { NSSound.beep(); return }
        let r = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        doc.crop(to: Selection.path(CGPath(rect: r, transform: nil), width: w, height: h, antialias: false))
        doc.commit("Auto-Crop", symbol: "crop", touch: .none)
        zoomFit(nil)
    }

    @objc func resizeImage(_ s: Any?) { canvas.engine.finishText();
        guard let (w, h, smooth) = Dialogs.resize(width: doc.width, height: doc.height) else { return }
        guard Limits.ok(w, h) else { Limits.tooBig(); return }
        doc.resize(width: w, height: h, smooth: smooth)
        doc.commit("Resize Image", symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", touch: .none)
        zoomFit(nil)
    }

    @objc func canvasSize(_ s: Any?) { canvas.engine.finishText();
        guard let (w, h, ax, ay) = Dialogs.canvasSize(width: doc.width, height: doc.height) else { return }
        guard Limits.ok(w, h) else { Limits.tooBig(); return }
        doc.canvasSize(width: w, height: h, anchorX: ax, anchorY: ay, fill: AppState.shared.secondary)
        doc.commit("Canvas Size", symbol: "square.dashed", touch: .none)
        zoomFit(nil)
    }

    private func geo(_ op: GeoOp, _ name: String, _ sym: String) {
        doc.transform(op)
        doc.commit(name, symbol: sym, touch: .none)
        if op == .rotCW || op == .rotCCW { zoomFit(nil) }
    }

    @objc func flipImageH(_ s: Any?) { canvas.engine.finishText(); geo(.flipH, "Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") }
    @objc func flipImageV(_ s: Any?) { canvas.engine.finishText(); geo(.flipV, "Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") }
    @objc func rotateCW(_ s: Any?) { canvas.engine.finishText(); geo(.rotCW, "Rotate 90° Clockwise", "rotate.right") }
    @objc func rotateCCW(_ s: Any?) { canvas.engine.finishText(); geo(.rotCCW, "Rotate 90° Counter-Clockwise", "rotate.left") }
    @objc func rotate180(_ s: Any?) { canvas.engine.finishText(); geo(.rot180, "Rotate 180°", "arrow.triangle.2.circlepath") }

    @objc func flatten(_ s: Any?) { canvas.engine.finishText();
        guard doc.layers.count > 1 else { return }
        doc.flatten()
        doc.commit("Flatten", symbol: "square.3.layers.3d.down.right", touch: .none)
    }

    // MARK: Layers menu

    @objc func addLayer(_ s: Any?) { canvas.engine.finishText(); doc.addLayer(); doc.commit("Add New Layer", symbol: "plus.square", touch: .none) }
    @objc func deleteLayer(_ s: Any?) { canvas.engine.finishText();
        guard doc.layers.count > 1 else { NSSound.beep(); return }
        doc.deleteLayer(); doc.commit("Delete Layer", symbol: "minus.square", touch: .none)
    }
    @objc func duplicateLayer(_ s: Any?) { canvas.engine.finishText(); doc.duplicateLayer(); doc.commit("Duplicate Layer", symbol: "plus.square.on.square", touch: .none) }
    @objc func mergeDown(_ s: Any?) { canvas.engine.finishText();
        guard doc.active > 0 else { NSSound.beep(); return }
        doc.mergeDown(); doc.commit("Merge Layer Down", symbol: "arrow.down.to.line")
    }
    @objc func moveLayerUp(_ s: Any?) { canvas.engine.finishText();
        guard doc.active < doc.layers.count - 1 else { return }
        doc.moveLayer(up: true); doc.commit("Move Layer Up", symbol: "chevron.up", touch: .none)
    }
    @objc func moveLayerDown(_ s: Any?) { canvas.engine.finishText();
        guard doc.active > 0 else { return }
        doc.moveLayer(up: false); doc.commit("Move Layer Down", symbol: "chevron.down", touch: .none)
    }
    @objc func flipLayerH(_ s: Any?) { canvas.engine.finishText(); doc.transformActiveLayer(.flipH); doc.commit("Flip Layer Horizontal", symbol: "arrow.left.and.right") }
    @objc func flipLayerV(_ s: Any?) { canvas.engine.finishText(); doc.transformActiveLayer(.flipV); doc.commit("Flip Layer Vertical", symbol: "arrow.up.and.down") }
    @objc func rotateLayer180(_ s: Any?) { canvas.engine.finishText(); doc.transformActiveLayer(.rot180); doc.commit("Rotate Layer 180°", symbol: "arrow.triangle.2.circlepath") }

    func moveLayer(from: Int, to: Int) {
        canvas.engine.finishText()
        guard from != to, doc.layers.indices.contains(from), doc.layers.indices.contains(to) else { return }
        let l = doc.layers.remove(at: from)
        doc.layers.insert(l, at: to)
        doc.active = to
        doc.commit("Move Layer", symbol: "arrow.up.arrow.down", touch: .none)
    }

    /// Turn a text, image or shape layer into plain pixels (they already look the same).
    @objc func rasterizeLayer(_ s: Any?) { canvas.engine.finishText();
        guard doc.activeLayer.isLive else { NSSound.beep(); return }
        doc.activeLayer.rasterize()
        doc.commit("Rasterize Layer", symbol: "square.grid.3x3.fill", touch: .none)
    }

    @objc func layerProperties(_ s: Any?) { canvas.engine.finishText();
        let l = doc.activeLayer
        if Dialogs.layerProperties(l, preview: { [weak self] in self?.doc.pixelsChanged() }) {
            doc.commit("Layer Properties", symbol: "slider.horizontal.3", touch: .none)
        } else {
            doc.structureChanged()
        }
    }

    // MARK: Vectorize

    /// Layers ▸ Vectorize…: trace the layer (or the selected part of it) into smooth filled shapes
    /// that stay sharp at any size. The result is a new layer above; the original is hidden, not lost.
    @objc func vectorize(_ s: Any?) { canvas.engine.finishText()
        let L = doc.activeLayer
        guard L.adjustment == nil, L.object?.vector == nil else { NSSound.beep(); return }
        // What shows of the layer (its mask applied), only inside the selection if there is one.
        let full = Layer(width: doc.width, height: doc.height, name: "")
        full.ctx.saveGState()
        if let sel = doc.selection { full.ctx.clip(to: full.rect, mask: sel.image) }
        if let m = L.mask { full.ctx.clip(to: full.rect, mask: m.greyImage(refreshing: m.rect)) }
        full.ctx.draw(L.image(), in: full.rect)
        full.ctx.restoreGState()
        full.touch()
        let b = full.contentBounds.integral
        guard !b.isNull, !b.isEmpty, let img = full.image().cropping(to: b) else { NSSound.beep(); return }
        let out = Layer(width: doc.width, height: doc.height, name: L.name + " (vector)")
        let center = CGPoint(x: b.midX, y: b.midY)
        let wasVisible = L.visible
        doc.addLayer(out)
        L.visible = false
        doc.selection = nil
        doc.structureChanged()
        func trace(_ v: [Double]) -> VectorArt {
            Vectorizer.trace(img, options: .init(colors: Int(v[0].rounded()), smoothness: v[1], detail: v[2]))
        }
        func show(_ art: VectorArt) {
            let spec = ObjectSpec(vector: art, center: center)
            out.object = spec
            spec.render(into: out)
            doc.pixelsChanged()
        }
        // Live preview, traced off the main thread; only the latest settings are drawn.
        let q = DispatchQueue(label: "sooth.vectorize", qos: .userInitiated)
        var busy = false, pending: [Double]?, closed = false
        func preview(_ v: [Double]) {
            if busy { pending = v; return }
            busy = true
            q.async {
                let art = trace(v)
                DispatchQueue.main.async {
                    busy = false
                    guard !closed else { return }
                    show(art)
                    if let n = pending { pending = nil; preview(n) }
                }
            }
        }
        let params = [Param(name: "Colours", min: 2, max: 24, def: 8),
                      Param(name: "Smoothness", min: 0, max: 2, def: 1, step: 0.1),
                      Param(name: "Detail", min: 0, max: 1, def: 0.5, step: 0.05)]
        let chosen = Dialogs.params(title: "Vectorize", params: params, preview: preview)
        closed = true
        guard let chosen else {
            if let i = doc.layers.firstIndex(where: { $0 === out }) { doc.active = i; doc.deleteLayer() }
            L.visible = wasVisible
            doc.structureChanged()
            return
        }
        withProgress("Tracing…", { trace(chosen) }) { [weak self] art in
            show(art)
            self?.doc.commit("Vectorize", symbol: "scribble.variable", touch: .none)
        }
    }

    /// Layers ▸ Export Vector as SVG…: the traced art as an SVG file, at its own size.
    @objc func exportSVG(_ s: Any?) {
        guard let v = doc.activeLayer.object?.vector, let win = window else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.svg]
        panel.nameFieldStringValue = doc.activeLayer.name.replacingOccurrences(of: " (vector)", with: "") + ".svg"
        panel.beginSheetModal(for: win) { r in
            guard r == .OK, let u = panel.url else { return }
            do { try v.svg().write(to: u, atomically: true, encoding: .utf8) } catch { NSAlert(error: error).runModal() }
        }
    }

    // MARK: Library

    /// Edit ▸ Add to Library: keep the selected layer (or the selected part of it) for reuse.
    @objc func addToLibrary(_ s: Any?) { canvas.engine.finishText()
        let l = doc.activeLayer
        let name = doc.selection != nil ? "\(l.name) (part)" : l.name
        do {
            try Library.add(l, selection: doc.selection, in: doc, name: name)
            if !LibraryPanel.shared.isVisible { LibraryPanel.toggle() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func toggleLibrary(_ s: Any?) { LibraryPanel.toggle() }

    /// Put a Library thing into this image, centred on `point` (or the middle of the view).
    func insertLibraryItem(_ url: URL, at point: CGPoint?) {
        canvas.engine.finishText()
        let vis = canvas.visibleRect.intersection(doc.fullRect)
        let p = point ?? CGPoint(x: vis.isNull ? CGFloat(doc.width) / 2 : vis.midX, y: vis.isNull ? CGFloat(doc.height) / 2 : vis.midY)
        guard let l = Library.layer(from: url, for: doc, at: p) else { NSSound.beep(); return }
        doc.addLayer(l)
        doc.selection = nil
        doc.commit("Add from Library", symbol: "books.vertical", touch: .none)
        AppState.shared.tool = .moveSelected
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layer masks

    /// Layers ▸ Add Layer Mask: everything shows (or only the selection, if there is one); brushes now
    /// paint the mask: black hides, white brings back.
    @objc func addLayerMask(_ s: Any?) { canvas.engine.finishText()
        let l = doc.activeLayer
        guard l.mask == nil else { doc.editingMask = true; structureChanged(); return }
        let m = Layer(width: doc.width, height: doc.height, name: "Mask")
        if let sel = doc.selection {
            m.fill(.black)
            m.ctx.saveGState(); m.ctx.clip(to: m.rect, mask: sel.image); m.ctx.setFillColor(RGBA.white.cg); m.ctx.fill(m.rect); m.ctx.restoreGState()
            doc.selection = nil
        } else {
            m.fill(.white)
        }
        l.mask = m
        doc.editingMask = true
        doc.commit("Add Layer Mask", symbol: "circle.lefthalf.filled", touch: .none)
    }

    /// Switch brushes between the layer's mask and its pixels.
    @objc func toggleMaskEditing(_ s: Any?) { canvas.engine.finishText()
        guard doc.activeLayer.mask != nil else { NSSound.beep(); return }
        doc.editingMask.toggle()
        structureChanged()
    }

    /// Layers ▸ Apply Layer Mask: hidden parts are erased for good and the mask goes.
    @objc func applyLayerMask(_ s: Any?) { canvas.engine.finishText()
        let l = doc.activeLayer
        guard let m = l.mask else { NSSound.beep(); return }
        l.rasterize()
        parallelRows(l.height) { y in
            for x in 0..<l.width {
                let i = y * l.width + x, k = m.greyValue(i)
                if k == 255 { continue }
                for c in 0..<4 { l.bytes[i * 4 + c] = UInt8(Int(l.bytes[i * 4 + c]) * k / 255) }
            }
        }
        l.mask = nil
        doc.editingMask = false
        doc.commit("Apply Layer Mask", symbol: "circle.lefthalf.filled")
    }

    @objc func deleteLayerMask(_ s: Any?) { canvas.engine.finishText()
        guard doc.activeLayer.mask != nil else { NSSound.beep(); return }
        doc.activeLayer.mask = nil
        doc.editingMask = false
        doc.commit("Delete Layer Mask", symbol: "circle.lefthalf.filled", touch: .none)
    }

    // MARK: Adjustment layers

    /// Layers ▸ New Adjustment Layer ▸ …: an adjustment that changes everything below, live and
    /// re-editable. Paint the layer black where it shouldn't apply.
    @objc func addAdjustmentLayer(_ sender: NSMenuItem) {
        guard let f = sender.representedObject as? Filter else { return }
        newAdjustmentLayer(f)
    }

    func newAdjustmentLayer(_ f: Filter) {
        canvas.engine.finishText()
        let l = Layer(width: doc.width, height: doc.height, name: f.name)
        l.fill(.white)
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        l.adjustment = AdjustmentSpec(name: f.name, values: f.rawValues ? Curves.encode(mode: .luminosity, curves: [line, line, line])
                                                                         : f.params.map(\.def))
        doc.addLayer(l)
        doc.editingMask = false
        doc.structureChanged()
        guard editAdjustmentValues(l) else {
            if let i = doc.layers.firstIndex(where: { $0 === l }) { doc.active = i; doc.deleteLayer() }
            doc.structureChanged()
            return
        }
        doc.commit("Add \(f.name) Layer", symbol: "slider.horizontal.3", touch: .none)
    }

    /// Open an adjustment layer's settings with live preview. False (and the old settings) on Cancel.
    func editAdjustmentValues(_ l: Layer) -> Bool {
        guard let adj = l.adjustment, let f = adj.filter else { return false }
        let old = adj.values
        let preview: ([Double]) -> Void = { [weak self] v in l.adjustment?.values = v; self?.doc.pixelsChanged() }
        let chosen: [Double]?
        if f.rawValues {
            chosen = Dialogs.curves(initial: old, preview: preview)
        } else if f.params.isEmpty {
            chosen = []   // nothing to set (Black and White, Invert Colors, Sepia)
        } else {
            let ps = f.params.enumerated().map { i, p in
                Param(name: p.name, min: p.min, max: p.max, def: i < old.count ? old[i] : p.def, step: p.step)
            }
            chosen = Dialogs.params(title: f.name, params: ps, preview: preview)
        }
        guard let chosen else { l.adjustment?.values = old; doc.pixelsChanged(); return false }
        l.adjustment?.values = chosen
        doc.pixelsChanged()
        return true
    }

    /// Layers ▸ Edit Adjustment… (or double-click the layer).
    @objc func editAdjustment(_ s: Any?) { canvas.engine.finishText()
        let l = doc.activeLayer
        guard let adj = l.adjustment else { NSSound.beep(); return }
        if editAdjustmentValues(l), l.adjustment != adj {
            doc.commit("Edit \(adj.name)", symbol: "slider.horizontal.3", touch: .none)
        }
    }

    /// Layers ▸ Text Effects… (also `[effects]` on the Text tool's line, which a narrow window can cut off).
    @objc func showTextEffects(_ s: Any?) { TextEffectsPanel.show() }

    @objc func importFromFile(_ s: Any?) { canvas.engine.finishText();
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { importLayer(from: u) }
    }

    func importLayer(from url: URL, at point: CGPoint? = nil) {
        guard let d = try? Document.load(url: url) else { NSSound.beep(); return }
        let img = Layer.from(image: d.composite(), name: "").image()   // its own copy, not a live view
        addImageLayer(img, named: url.deletingPathExtension().lastPathComponent, at: point)
    }

    /// Add an image as a new movable object layer, centred on `point` (or the canvas).
    func addImageLayer(_ img: CGImage, named name: String, at point: CGPoint? = nil) {
        canvas.engine.finishText()
        guard let grew = fitCanvas(to: img) else { return }
        let c = grew ? nil : point
        let l = Layer(width: doc.width, height: doc.height, name: name)
        let spec = ObjectSpec(source: img, center: c.map { placement(of: img, near: $0) }
                              ?? CGPoint(x: CGFloat(doc.width) / 2, y: CGFloat(doc.height) / 2))
        l.object = spec
        spec.render(into: l)
        doc.addLayer(l)
        doc.selection = nil
        doc.commit("Add Image", symbol: "photo", touch: .none)
        AppState.shared.tool = .moveSelected
        if grew { zoomFit(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Subjects (background removal, lifting)

    /// Run `work` off the main thread; show a progress sheet if it takes more than a moment.
    /// If the image changes before the work is done (an undo in the moment before the sheet
    /// appears), the result is dropped rather than landing on a different image.
    private func withProgress<T>(_ title: String, _ work: @escaping () -> T, then done: @escaping (T) -> Void) {
        var finished = false, sheet: NSWindow?
        let rev = doc.revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard !finished, let w = self?.window else { return }
            sheet = FilterRunner.progressSheet(title: title)
            w.beginSheet(sheet!)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = work()
            DispatchQueue.main.async {
                finished = true
                if let sheet { self?.window?.endSheet(sheet) }
                guard self?.doc.revision == rev else { NSSound.beep(); return }
                done(r)
            }
        }
    }

    private func noSubject() {
        let a = NSAlert()
        a.messageText = "Sooth couldn't find a subject here."
        a.informativeText = "Subject detection works best on photos and drawings with a clear foreground. You can still erase the background by hand."
        a.runModal()
    }

    /// Layers ▸ Remove Background: cut the subject out, keeping the settings so they can be re-tuned
    /// later (run it again on the same layer). The layer becomes a movable object layer.
    @objc func removeBackground(_ s: Any?) { canvas.engine.finishText();
        let L = doc.activeLayer
        guard L.text == nil, L.object?.vector == nil else { NSSound.beep(); return }
        let before = L.object, original = L.data()
        let spec = L.object ?? ObjectSpec(source: L.image(), center: CGPoint(x: CGFloat(doc.width) / 2, y: CGFloat(doc.height) / 2))
        let run: (Data) -> Void = { [weak self] raw in
            guard let self else { return }
            let cut = spec.cutout ?? Cutout(raw: raw)
            let q = DispatchQueue(label: "sooth.cutout", qos: .userInitiated)
            var busy = false, pending: [Double]?, closed = false
            func make(_ v: [Double]) -> ObjectSpec {
                var c = cut
                c.strength = CGFloat(v[0]); c.softness = CGFloat(v[1]); c.grow = CGFloat(v[2]); c.rev = Rev.next()
                var sp = spec; sp.cutout = c
                return sp
            }
            func preview(_ v: [Double]) {
                if busy { pending = v; return }
                busy = true
                q.async {
                    let sp = make(v)
                    DispatchQueue.main.async {
                        busy = false
                        guard !closed else { return }
                        L.object = sp; sp.render(into: L); self.doc.pixelsChanged()
                        if let n = pending { pending = nil; preview(n) }
                    }
                }
            }
            let params = [Param(name: "Strength", min: 0, max: 100, def: Double(cut.strength)),
                          Param(name: "Edge softness", min: 0, max: 30, def: Double(cut.softness), step: 0.5),
                          Param(name: "Grow / shrink", min: -40, max: 40, def: Double(cut.grow))]
            let v = Dialogs.params(title: "Remove Background", params: params, preview: preview)
            closed = true
            guard let v else {
                L.object = before
                L.load(original); L.touch()
                self.doc.pixelsChanged()
                return
            }
            self.withProgress("Removing background…", { make(v) }) { sp in
                L.object = sp; L.shape = nil; sp.render(into: L)   // it's a cut-out now, not a shape
                self.doc.pixelsChanged()
                self.doc.commit("Remove Background", symbol: "person.crop.rectangle")
            }
        }
        if let raw = spec.cutout?.raw { run(raw); return }
        let img = spec.source, key = "o\(Unmanaged.passUnretained(img).toOpaque())"
        withProgress("Finding the subject…", { SubjectMap.cached(img, key: key)?.mask() }) { [weak self] m in
            guard let m else { self?.noSubject(); return }
            run(Data(m))
        }
    }

    /// Double-click with the Move tool on a subject in a flat layer: lift it into its own movable
    /// object layer. Plain double-click cuts it out of the layer; ⌥ leaves the original in place.
    func liftSubject(at p: CGPoint, keepOriginal: Bool) {
        guard let i = canvas.engine.pixelLayer(at: p) else { NSSound.beep(); return }
        let L = doc.layers[i]
        guard L.object == nil, L.text == nil else { return }
        let img = L.image(), key = "r\(L.rev)", w = doc.width, h = doc.height
        withProgress("Finding the subject…", { () -> [UInt8]? in
            guard let map = SubjectMap.cached(img, key: key), let inst = map.instance(at: p) else { return nil }
            return map.mask(IndexSet(integer: inst))
        }) { [weak self] m in
            guard let self else { return }
            guard let m, let b = SubjectMap.bounds(of: m, width: w, height: h) else { self.noSubject(); return }
            self.finishLift(L: L, layerIndex: i, img: img, m: m, b: b, keepOriginal: keepOriginal)
        }
    }

    private func finishLift(L: Layer, layerIndex i: Int, img: CGImage, m: [UInt8], b: CGRect, keepOriginal: Bool) {
        let w = doc.width, h = doc.height
        do {
            let crop = b.insetBy(dx: -2, dy: -2).intersection(self.doc.fullRect).integral
            guard let part = img.cropping(to: crop) else { return }
            let cw = Int(crop.width), ch = Int(crop.height), cx = Int(crop.minX), cy = Int(crop.minY)
            var raw = [UInt8](repeating: 0, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw { raw[y * cw + x] = m[(y + cy) * w + x + cx] } }
            let cut = Cutout(raw: Data(raw))
            let spec = ObjectSpec(source: part, center: CGPoint(x: crop.midX, y: crop.midY), cutout: cut)
            if !keepOriginal {
                // Take the subject out of the layer it came from and fill the gap from its surroundings.
                let eff = ObjectSpec.mask(cut, width: cw, height: ch)
                var hole = [UInt8](repeating: 0, count: w * h)
                for y in 0..<ch { for x in 0..<cw where eff[y * cw + x] > 8 { hole[(y + cy) * w + x + cx] = 255 } }
                // grow the hole a few pixels so no fringe of the subject is left behind
                hole = Inpaint.dilate(hole, width: w, height: h, by: 3)
                Inpaint.fill(L.bytes, width: w, height: h, mask: hole)
                L.touch()
            }
            let nl = Layer(width: w, height: h, name: "Subject")
            nl.object = spec
            spec.render(into: nl)
            self.doc.active = i
            self.doc.addLayer(nl)
            self.doc.pixelsChanged()
            self.doc.commit("Lift Subject", symbol: "person.crop.rectangle")
        }
    }

    /// Edit ▸ Content-Aware Fill: replace the selection with texture from around it.
    @objc func contentAwareFill(_ s: Any?) { canvas.engine.finishText();
        guard let sel = doc.selection, !sel.isEmpty else { NSSound.beep(); return }
        let L = doc.paintTarget
        L.rasterize()
        let w = doc.width, h = doc.height
        var work = L.data()
        let mask = sel.mask
        withProgress("Filling…", {
            work.withUnsafeMutableBytes { Inpaint.fill($0.baseAddress!.assumingMemoryBound(to: UInt8.self), width: w, height: h, mask: mask) }
            return work
        }) { [weak self] out in
            guard let self else { return }
            L.load(out); L.touch()
            self.doc.pixelsChanged(sel.bounds)
            self.doc.commit("Content-Aware Fill", symbol: "wand.and.rays")
        }
    }

    // MARK: Adjustments and effects

    @objc func runFilter(_ sender: NSMenuItem) { canvas.engine.finishText();
        guard let f = sender.representedObject as? Filter else { return }
        apply(f, values: nil)
    }

    @objc func repeatFilter(_ s: Any?) { canvas.engine.finishText();
        guard let (f, v) = lastFilter else { NSSound.beep(); return }
        apply(f, values: v)
    }

    private var runningFilter: FilterRunner?

    private func apply(_ f: Filter, values given: [Double]?) {
        guard runningFilter == nil else { NSSound.beep(); return }
        let L = doc.paintTarget
        let live = (L.text, L.object, L.shape)
        L.rasterize()   // effects work on pixels, so a text or object layer becomes pixels
        let unrasterize = { (L.text, L.object, L.shape) = live }   // Cancel leaves it editable
        let st = AppState.shared
        let runner = FilterRunner(filter: f, layer: L, selection: doc.selection, primary: st.primary, secondary: st.secondary)
        runner.onPreview = { [weak self] in self?.doc.pixelsChanged() }
        runningFilter = runner
        var vals = given ?? f.params.map(\.def)
        if given == nil && f.rawValues {
            guard let v = Dialogs.curves(preview: { runner.preview($0) }) else {
                runner.cancel(); unrasterize(); runningFilter = nil; doc.pixelsChanged(); return
            }
            vals = v
        } else if given == nil && !f.params.isEmpty {
            guard let v = Dialogs.params(title: f.name, params: f.params, preview: { runner.preview($0) }) else {
                runner.cancel()
                unrasterize()
                runningFilter = nil
                doc.pixelsChanged()
                return
            }
            vals = v
        }
        let rev = doc.revision
        runner.finish(vals, window: window, valid: { [weak self] in self?.doc.revision == rev }) { [weak self] ok in
            guard let self else { return }
            runningFilter = nil
            guard ok else {
                // The image moved on (an undo, say) before the result arrived: put back the pixels the preview changed.
                runner.cancel(); unrasterize(); doc.pixelsChanged()
                NSSound.beep(); return
            }
            lastFilter = (f, vals)
            doc.pixelsChanged()
            doc.commit(f.name, symbol: "sparkles")
        }
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Nothing may change the image under a stroke or drag that's still going (⌘Z with the other hand).
        if canvas.engine.isDragging { return false }
        switch item.action {
        case #selector(doUndo(_:)) where canvas.engine.text?.view.undoManager?.canUndo == true:
            item.title = "Undo Typing"
            return true
        case #selector(doRedo(_:)) where canvas.engine.text?.view.undoManager?.canRedo == true:
            item.title = "Redo Typing"
            return true
        case #selector(doUndo(_:)):
            item.title = doc.canUndo ? "Undo \(doc.history[doc.cursor].name)" : "Undo"
            return doc.canUndo
        case #selector(doRedo(_:)):
            item.title = doc.canRedo ? "Redo \(doc.history[doc.cursor + 1].name)" : "Redo"
            return doc.canRedo
        case #selector(deselect(_:)), #selector(cropToSelection(_:)):
            return doc.selection != nil
        case #selector(deleteLayer(_:)), #selector(flatten(_:)):
            return doc.layers.count > 1
        case #selector(rasterizeLayer(_:)):
            return doc.activeLayer.isLive
        case #selector(addLayerMask(_:)):
            item.title = doc.selection != nil ? "Add Mask from Selection" : "Add Layer Mask"
            return doc.activeLayer.mask == nil
        case #selector(toggleMaskEditing(_:)):
            item.title = doc.editingMask ? "Edit Layer" : "Edit Mask"
            return doc.activeLayer.mask != nil
        case #selector(applyLayerMask(_:)), #selector(deleteLayerMask(_:)):
            return doc.activeLayer.mask != nil
        case #selector(editAdjustment(_:)):
            return doc.activeLayer.adjustment != nil
        case #selector(vectorize(_:)):
            return doc.activeLayer.adjustment == nil && doc.activeLayer.object?.vector == nil
        case #selector(exportSVG(_:)):
            return doc.activeLayer.object?.vector != nil
        case #selector(mergeDown(_:)), #selector(moveLayerDown(_:)):
            return doc.active > 0
        case #selector(moveLayerUp(_:)):
            return doc.active < doc.layers.count - 1
        case #selector(repeatFilter(_:)):
            item.title = lastFilter.map { "Repeat \($0.0.name)" } ?? "Repeat Last Effect"
            return lastFilter != nil
        case #selector(toggleGrid(_:)):
            item.state = canvas.showGrid ? .on : .off
            return true
        case #selector(paste(_:)), #selector(pasteNewLayer(_:)), #selector(pasteNewImage(_:)):
            let pb = NSPasteboard.general
            return pb.availableType(from: [.png, .tiff, .fileURL]) != nil || NSImage.canInit(with: pb)
        default:
            return true
        }
    }
}

/// Blend a filter result back toward the source using a selection mask.
func blendMask(src: UnsafePointer<UInt8>, dst: UnsafeMutablePointer<UInt8>, mask: [UInt8]) {
    mask.withUnsafeBufferPointer { m in
        for p in 0..<m.count {
            let k = Int(m[p])
            if k == 255 { continue }
            let i = p * 4
            if k == 0 {
                dst[i] = src[i]; dst[i + 1] = src[i + 1]; dst[i + 2] = src[i + 2]; dst[i + 3] = src[i + 3]
            } else {
                for c in 0..<4 { dst[i + c] = UInt8((Int(src[i + c]) * (255 - k) + Int(dst[i + c]) * k) / 255) }
            }
        }
    }
}

/// A split view whose dividers are the suite's hairlines.
final class QuietSplitView: NSSplitView {
    override var dividerColor: NSColor { Look.current == .tianmu || Look.current == .native ? Ink.line : .clear }
}
