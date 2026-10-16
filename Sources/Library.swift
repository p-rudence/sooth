import AppKit

/// The Library: things kept for reuse across images (pictures, cut-outs, text, shapes, vector art).
/// Each is one small file in ~/Library/Application Support/Sooth/Library, so they can also be
/// backed up, shared or dragged in from Finder. Text, shapes and pictures stay live (editable).
enum Library {
    static let ext = "sooththing"
    /// Things kept before the rename are still read.
    static let exts: Set<String> = [ext, "easelthing"]
    static let changed = Notification.Name("SoothLibraryChanged")

    /// Where things are kept (the self-test points this at a temporary folder).
    nonisolated(unsafe) static var folder: URL = {
        supportFolder("Library")
    }()

    struct Item {
        let url: URL
        var name: String
        let date: Date
        let thumbnail: NSImage?
        let kind: String
    }

    /// Everything in the Library, newest first.
    static func items() -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { exts.contains($0.pathExtension) }.compactMap { u in
            guard let d = plist(u) else { return nil }
            let thumb = (d["thumb"] as? Data).flatMap { NSImage(data: $0) }
            return Item(url: u, name: d["name"] as? String ?? u.deletingPathExtension().lastPathComponent,
                        date: d["date"] as? Date ?? .distantPast, thumbnail: thumb, kind: d["kind"] as? String ?? "picture")
        }.sorted { $0.date > $1.date }
    }

    private static func plist(_ u: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: u),
              let d = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              ["sooth-thing", "easel-thing"].contains(d["format"] as? String ?? "") else { return nil }
        return d
    }

    /// Keep a layer (or just the selected part of it). Live layers stay live; a mask is baked in.
    @discardableResult
    static func add(_ l: Layer, selection: Selection?, in doc: Document, name: String) throws -> URL {
        var d: [String: Any] = ["format": "sooth-thing", "version": 1, "name": name, "date": Date()]
        let live = selection == nil && l.mask == nil && l.adjustment == nil && l.isLive
        if live {
            // Live: keep the recipe, moved so its box starts at 0,0.
            let b = extent(of: l).integral
            let tmp = Layer(width: max(1, Int(b.width)), height: max(1, Int(b.height)), name: l.name)
            doc.carryLive(l, into: tmp, kx: 1, ky: 1, dx: -b.minX, dy: -b.minY)
            if let t = tmp.text { d["text"] = t.plist; d["kind"] = "text" }
            if let o = tmp.object { d["object"] = o.plist; d["kind"] = o.vector != nil ? "vector" : o.cutout != nil ? "cut-out" : "picture" }
            if let s = tmp.shape { d["shape"] = s.plist; d["kind"] = s.kind.title.lowercased() }
            d["width"] = tmp.width; d["height"] = tmp.height
            d["thumb"] = try Document.encode(thumbImage(tmp.image()), as: .png)
        } else {
            // Pixels: what shows of the layer (mask applied), cropped to its content or the selection.
            let full = Layer(width: l.width, height: l.height, name: "")
            full.ctx.saveGState()
            if let sel = selection { full.ctx.clip(to: full.rect, mask: sel.image) }
            if let m = l.mask { full.ctx.clip(to: full.rect, mask: m.greyImage(refreshing: m.rect)) }
            full.ctx.draw(l.image(), in: full.rect)
            full.ctx.restoreGState()
            full.touch()
            let b = full.contentBounds
            guard !b.isNull, !b.isEmpty, let img = full.image().cropping(to: b.integral) else {
                throw SoothError(message: "There's nothing there to keep.")
            }
            d["png"] = try Document.encode(img, as: .png)
            d["kind"] = "picture"
            d["width"] = img.width; d["height"] = img.height
            d["thumb"] = try Document.encode(thumbImage(img), as: .png)
        }
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0).write(to: url, options: .atomic)
        NotificationCenter.default.post(name: changed, object: nil)
        return url
    }

    /// The box a live layer's content occupies (it may hang past the canvas).
    static func extent(of l: Layer) -> CGRect {
        if let o = l.object { return o.extent }
        if let s = l.shape { return s.extent }
        if let t = l.text { return TextEditor.frame(of: t).insetBy(dx: -4, dy: -4) }
        return l.contentBounds
    }

    private static func thumbImage(_ img: CGImage) -> CGImage {
        let s = min(1, 160 / CGFloat(max(img.width, img.height)))
        let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
        let l = Layer(width: w, height: h, name: "")
        l.ctx.interpolationQuality = .high
        l.ctx.draw(img, in: l.rect)
        return l.image()
    }

    /// A new layer for `doc` holding the thing, centred on `point`.
    static func layer(from url: URL, for doc: Document, at point: CGPoint) -> Layer? {
        guard let d = plist(url) else { return nil }
        let name = d["name"] as? String ?? "From Library"
        let w = CGFloat(d["width"] as? Int ?? 1), h = CGFloat(d["height"] as? Int ?? 1)
        let dx = (point.x - w / 2).rounded(), dy = (point.y - h / 2).rounded()
        let n = Layer(width: doc.width, height: doc.height, name: name)
        let src = Layer(width: 1, height: 1, name: name)
        if let t = d["text"] as? [String: Any] { src.text = TextSpec(plist: t) }
        if let o = d["object"] as? [String: Any] { src.object = ObjectSpec(plist: o) }
        if let s = d["shape"] as? [String: Any] { src.shape = ShapeSpec(plist: s) }
        if src.isLive {
            doc.carryLive(src, into: n, kx: 1, ky: 1, dx: dx, dy: dy)
            return n
        }
        guard let png = d["png"] as? Data, let s = CGImageSourceCreateWithData(png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        // A picture comes in as a movable picture layer, like anything pasted.
        let spec = ObjectSpec(source: img, center: CGPoint(x: dx + CGFloat(img.width) / 2, y: dy + CGFloat(img.height) / 2))
        n.object = spec
        spec.render(into: n)
        return n
    }

    static func rename(_ url: URL, to name: String) {
        guard var d = plist(url) else { return }
        d["name"] = name
        if let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The self-test deletes outright instead of filling the real Trash.
    nonisolated(unsafe) static var useTrash = true

    /// Into the Trash (recoverable), not deleted outright.
    static func remove(_ url: URL) {
        if useTrash { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        else { try? FileManager.default.removeItem(at: url) }
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

// MARK: - The Library window

/// A floating panel of everything kept: click one to put it in the image, drag it onto the canvas
/// to place it, right-click to rename or remove.
final class LibraryPanel: NSPanel {
    private static var instance: LibraryPanel?
    static var shared: LibraryPanel {
        if let i = instance { return i }
        let i = LibraryPanel()
        instance = i
        return i
    }
    /// Drop the panel so it's built again in the current look.
    static func reset() {
        guard let i = instance else { return }
        i.orderOut(nil)
        instance = nil
    }
    private let grid = LibraryGrid()
    private var observer: Any?

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Library"
        titlebarAppearsTransparent = true
        backgroundColor = Look.current == .glass ? NSColor(srgbRed: 0.86, green: 0.94, blue: 0.98, alpha: 1) : Ink.window
        appearance = Look.current.appearance
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 220, height: 200)

        let header = Strip([.text("library", Ink.dim), .spring,
                            .button("+ layer", tip: "Keep the selected layer (or the selected part of it) here") {
                                (NSApp.mainWindow?.windowController as? EditorWindowController)?.addToLibrary(nil)
                            }, .text(" "),
                            .button("folder", tip: "Show the Library folder in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Library.folder])
                            }])
        let scroll = NSScrollView()
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        for v in [header, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        contentView = stack
        grid.frame = NSRect(x: 0, y: 0, width: 420, height: 100)
        grid.autoresizingMask = [.width]
        observer = NotificationCenter.default.addObserver(forName: Library.changed, object: nil, queue: .main) { [weak self] _ in
            self?.grid.reload()
        }
        grid.reload()
    }

    static func toggle() {
        let p = shared
        if p.isVisible { p.orderOut(nil); return }
        p.grid.reload()
        if let w = NSApp.mainWindow {
            p.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - 440, y: w.frame.maxY - 60))
        }
        p.orderFront(nil)
    }
}

/// The tiles: thumbnail above, name below, in the pixel font.
final class LibraryGrid: NSView, NSDraggingSource {
    private var items: [Library.Item] = []
    private let tile = CGSize(width: 120, height: 140)
    private var pressed: (index: Int, at: NSPoint)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        items = Library.items()
        relayout()
        needsDisplay = true
    }

    private var columns: Int { max(1, Int((bounds.width - 8) / tile.width)) }

    private func relayout() {
        let rows = (items.count + columns - 1) / columns
        let h = max(CGFloat(rows) * tile.height + 16, enclosingScrollView?.contentSize.height ?? 100)
        if frame.height != h { setFrameSize(NSSize(width: frame.width, height: h)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let colsBefore = columns
        super.setFrameSize(newSize)
        if columns != colsBefore { relayout(); needsDisplay = true }
    }

    private func frame(of i: Int) -> CGRect {
        CGRect(x: 8 + CGFloat(i % columns) * tile.width, y: 8 + CGFloat(i / columns) * tile.height, width: tile.width, height: tile.height)
    }

    private func index(at p: NSPoint) -> Int? { items.indices.first { frame(of: $0).contains(p) } }

    override func draw(_ dirtyRect: NSRect) {
        if items.isEmpty {
            let s = NSAttributedString(string: "nothing kept yet\n\nright-click a layer > Add to Library,\nor [+ layer] above",
                                       attributes: [.font: pixelFont(), .foregroundColor: Ink.dim])
            s.draw(at: CGPoint(x: 16, y: 16))
            return
        }
        for (i, it) in items.enumerated() {
            let f = frame(of: i)
            guard f.intersects(dirtyRect) else { continue }
            let box = CGRect(x: f.minX + 8, y: f.minY + 4, width: f.width - 16, height: f.width - 16)
            checkerColor.setFill(); box.fill()
            if let t = it.thumbnail {
                let s = min(box.width / t.size.width, box.height / t.size.height)
                let r = CGRect(x: box.midX - t.size.width * s / 2, y: box.midY - t.size.height * s / 2,
                               width: t.size.width * s, height: t.size.height * s)
                t.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            Ink.faint.setStroke()
            NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let name = it.name.count > 12 ? String(it.name.prefix(11)) + "…" : it.name
            NSAttributedString(string: name, attributes: [.font: pixelFont(), .foregroundColor: Ink.soft])
                .draw(at: CGPoint(x: box.minX, y: box.maxY + 2))
        }
    }

    override func resetCursorRects() {
        for i in items.indices { addCursorRect(frame(of: i), cursor: .pointingHand) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        pressed = index(at: p).map { ($0, p) }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let (i, start) = pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        pressed = nil
        // Drag the thing's file: the canvas places it where it's dropped.
        let item = NSDraggingItem(pasteboardWriter: items[i].url as NSURL)
        item.setDraggingFrame(frame(of: i), contents: items[i].thumbnail)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    override func mouseUp(with e: NSEvent) {
        guard let (i, _) = pressed else { return }
        pressed = nil
        // A click puts it in the middle of the image in view.
        (NSApp.mainWindow?.windowController as? EditorWindowController)?.insertLibraryItem(items[i].url, at: nil)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    override func menu(for e: NSEvent) -> NSMenu? {
        guard let i = index(at: convert(e.locationInWindow, from: nil)) else { return nil }
        let it = items[i]
        return pixelMenu(["Rename…", "Show in Finder", "Remove from Library"], selected: nil) { choice in
            switch choice {
            case 0:
                let a = NSAlert()
                a.messageText = "Rename"
                a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
                let f = NSTextField(string: it.name)
                f.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                a.accessoryView = f
                a.window.initialFirstResponder = f
                if a.runModal() == .alertFirstButtonReturn, !f.stringValue.isEmpty { Library.rename(it.url, to: f.stringValue) }
            case 1: NSWorkspace.shared.activateFileViewerSelecting([it.url])
            default: Library.remove(it.url)
            }
        }
    }
}

/// `~/Library/Application Support/Sooth/<name>`, made if missing. A folder left by the app's
/// old name (Easel) is moved across the first time, so nothing kept is lost.
func supportFolder(_ name: String) -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let u = base.appendingPathComponent("Sooth/" + name, isDirectory: true)
    let old = base.appendingPathComponent("Easel/" + name, isDirectory: true)
    if !fm.fileExists(atPath: u.path), fm.fileExists(atPath: old.path) {
        try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: u)
    }
    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
