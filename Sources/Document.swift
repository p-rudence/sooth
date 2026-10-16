import AppKit
import UniformTypeIdentifiers
import ImageIO

struct LayerState {
    let name: String, visible: Bool, opacity: CGFloat, blend: BlendMode, rev: Int, bands: [Data]
    var text: TextSpec?
    var object: ObjectSpec?
    var shape: ShapeSpec?
    var adjustment: AdjustmentSpec?
    /// The layer mask's pixels, if it has one.
    var mask: (rev: Int, bands: [Data])?
}

struct DocState {
    let width: Int, height: Int, layers: [LayerState], active: Int, selection: Selection?
}

struct HistoryItem {
    let name: String
    let symbol: String
    let state: DocState
}

enum Touch { case none, active, all }

enum SaveFormat: Int, CaseIterable {
    case sooth, png, jpeg, tiff, bmp, heic

    var title: String {
        switch self {
        case .sooth: "Sooth (layered, .sooth)"
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .heic: "HEIC"
        }
    }
    var ext: String {
        switch self {
        case .sooth: "sooth"
        case .png: "png"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        case .bmp: "bmp"
        case .heic: "heic"
        }
    }
    var utType: UTType {
        switch self {
        case .sooth: UTType(filenameExtension: "sooth", conformingTo: .data) ?? .data
        case .png: .png
        case .jpeg: .jpeg
        case .tiff: .tiff
        case .bmp: .bmp
        case .heic: .heic
        }
    }
    static func from(url: URL) -> SaveFormat? {
        switch url.pathExtension.lowercased() {
        case "sooth", "easel": .sooth   // .easel: the name before Sooth
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "bmp": .bmp
        case "heic": .heic
        default: nil
        }
    }
}

/// Largest image Sooth will make: about 1.6 GB per layer at the limit.
enum Limits {
    static let side = 32768
    static let pixels = 400_000_000
    static func ok(_ w: Int, _ h: Int) -> Bool { w >= 1 && h >= 1 && w <= side && h <= side && w * h <= pixels }
    static func tooBig() {
        let a = NSAlert()
        a.messageText = "That image would be too big."
        a.informativeText = "Sooth works with images up to \(side) pixels on a side and \(pixels / 1_000_000) megapixels in all."
        a.runModal()
    }
}

struct SoothError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class Document {
    private(set) var width: Int
    private(set) var height: Int
    var layers: [Layer]
    /// The selected layer. Choosing another one goes back to painting pixels, not a mask.
    var active: Int { didSet { if active != oldValue { editingMask = false } } }
    var selection: Selection?
    var history: [HistoryItem] = []
    var cursor = 0
    /// Bumped on every commit, undo and redo; tools use it to notice the document moved on.
    private(set) var revision = 0
    var fileURL: URL?
    var fileFormat: SaveFormat?
    var dirty = false
    var onPixels: ((CGRect?) -> Void)?
    var onStructure: (() -> Void)?

    private var comp: Layer?
    private var compImage: CGImage?
    /// Region of the composite that needs rebuilding; nil when it is current.
    private var compDirty: CGRect? = .infinite

    /// History keeps at most this many bytes of pixels; the oldest steps go first.
    static let historyBudget: Int = Int(min(2 << 30, ProcessInfo.processInfo.physicalMemory / 4))

    init(width: Int, height: Int, background: RGBA?) {
        self.width = width; self.height = height
        let bg = Layer(width: width, height: height, name: "Background")
        if let c = background { bg.fill(c) }
        layers = [bg]
        active = 0
        history = [HistoryItem(name: "New Image", symbol: "doc", state: snapshot())]
    }

    init(layers: [Layer], active: Int = 0) {
        width = layers[0].width; height = layers[0].height
        self.layers = layers
        self.active = max(0, min(active, layers.count - 1))
        history = [HistoryItem(name: "Open Image", symbol: "folder", state: snapshot())]
    }

    var activeLayer: Layer { layers[active] }
    /// Brushes and effects work on the active layer's mask instead of its pixels.
    var editingMask = false
    /// What painting tools and effects change: the active layer, or its mask while editing that.
    var paintTarget: Layer { editingMask ? activeLayer.mask ?? activeLayer : activeLayer }
    var fullRect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    /// Title for an image brought back after a crash.
    var recoveredName: String?
    var displayName: String { fileURL?.lastPathComponent ?? recoveredName ?? "Untitled" }

    // MARK: History

    func snapshot() -> DocState {
        DocState(width: width, height: height,
                 layers: layers.map { LayerState(name: $0.name, visible: $0.visible, opacity: $0.opacity,
                                                 blend: $0.blend, rev: $0.rev, bands: $0.bands(), text: $0.text, object: $0.object, shape: $0.shape,
                                                 adjustment: $0.adjustment, mask: $0.mask.map { ($0.rev, $0.bands()) }) },
                 active: active, selection: selection)
    }

    func restore(_ s: DocState) {
        let old = layers
        let oldMasks = layers.compactMap(\.mask)
        width = s.width; height = s.height
        func revive(_ rev: Int, _ bands: [Data], name: String, from pool: [Layer]) -> Layer {
            if let ex = pool.first(where: { $0.rev == rev && $0.width == s.width && $0.height == s.height }) { return ex }
            let l = Layer(width: s.width, height: s.height, name: name)
            l.load(bands: bands)
            l.rev = rev
            l.bandCache = (rev, bands)
            return l
        }
        layers = s.layers.map { ls in
            let l: Layer
            if let ex = old.first(where: { $0.rev == ls.rev && $0.width == s.width && $0.height == s.height }) {
                l = ex
            } else {
                l = Layer(width: s.width, height: s.height, name: ls.name)
                l.load(bands: ls.bands)
                l.rev = ls.rev
                l.bandCache = (ls.rev, ls.bands)
            }
            l.name = ls.name; l.visible = ls.visible; l.opacity = ls.opacity; l.blend = ls.blend; l.text = ls.text; l.object = ls.object; l.shape = ls.shape
            l.adjustment = ls.adjustment
            l.mask = ls.mask.map { revive($0.rev, $0.bands, name: "Mask", from: oldMasks) }
            return l
        }
        active = min(s.active, layers.count - 1)
        if editingMask && activeLayer.mask == nil { editingMask = false }
        selection = s.selection
        structureChanged()
    }

    /// Record a history step. `recomposite: false` is for edits that already reported exactly the
    /// pixels they changed (brush strokes, moving live layers), so the composite isn't rebuilt.
    func commit(_ name: String, symbol: String, touch: Touch = .active, recomposite: Bool = true) {
        switch touch {
        case .none: break
        case .active: paintTarget.touch()
        case .all: layers.forEach { $0.touch() }
        }
        if cursor < history.count - 1 { history.removeSubrange((cursor + 1)...) }
        history.append(HistoryItem(name: name, symbol: symbol, state: snapshot()))
        if history.count > 150 { history.removeFirst(history.count - 150) }
        while history.count > 2 && historyBytes() > Document.historyBudget { history.removeFirst() }
        cursor = history.count - 1
        revision += 1
        dirty = true
        if recomposite { structureChanged() } else { onStructure?() }
    }

    /// Bytes of pixel data history keeps alive (shared buffers counted once).
    func historyBytes() -> Int {
        var seen = Set<UnsafeRawPointer>(), objects = Set<ObjectIdentifier>(), total = 0
        for item in history {
            // Selection masks (plus the drawing copy each makes) and pasted images' sources count too.
            if let s = item.state.selection, objects.insert(ObjectIdentifier(s)).inserted { total += s.mask.count * 2 }
            for l in item.state.layers {
                if let src = l.object?.source, objects.insert(ObjectIdentifier(src)).inserted { total += src.bytesPerRow * src.height }
            }
            for l in item.state.layers {
                for band in l.bands + (l.mask?.bands ?? []) {
                    band.withUnsafeBytes { raw in
                        if let b = raw.baseAddress, seen.insert(b).inserted { total += raw.count }
                    }
                }
            }
        }
        return total
    }

    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < history.count - 1 }
    func undo() { if canUndo { jump(to: cursor - 1) } }
    func redo() { if canRedo { jump(to: cursor + 1) } }
    func jump(to i: Int) {
        guard i >= 0, i < history.count, i != cursor else { return }
        cursor = i
        revision += 1
        dirty = true
        restore(history[i].state)
    }

    // MARK: Change notification and compositing

    /// Pixels changed inside `r` (image coordinates), or everywhere when nil.
    func pixelsChanged(_ r: CGRect? = nil) {
        let area = r ?? .infinite
        compDirty = compDirty.map { $0.union(area) } ?? area
        onPixels?(r)
    }

    /// Only overlays (selection outline, previews) changed; the pixels did not.
    /// Only guides moved (handles, outlines): the pixels are as they were.
    var onOverlay: (() -> Void)?
    func overlayChanged() { if let onOverlay { onOverlay() } else { onPixels?(nil) } }

    func structureChanged() { compDirty = .infinite; onStructure?() }

    /// The flattened image. It reads live pixels: draw or encode it at once, don't keep it.
    @discardableResult
    func composite() -> CGImage {
        if let c = compImage, compDirty == nil { return c }
        if comp == nil || comp!.width != width || comp!.height != height {
            comp = Layer(width: width, height: height, name: "composite")
            compDirty = .infinite
        }
        let c = comp!
        let r = (compDirty ?? .infinite).intersection(fullRect).integral
        compDirty = nil
        if !r.isEmpty {
            // CGContext space is y-up; the dirty rect is in image (y-down) coordinates.
            let cr = CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height)
            c.ctx.saveGState()
            c.ctx.clip(to: cr)
            c.ctx.clear(cr)
            for l in layers where l.visible {
                // Only where the layer has content (empty layers cost nothing).
                let lb = l.contentBounds.intersection(r).integral
                if lb.isNull || lb.isEmpty { continue }
                if let adj = l.adjustment {
                    if let f = adj.filter { Document.apply(f, adj.values, of: l, to: c, in: lb) }
                    continue
                }
                c.ctx.saveGState()
                c.ctx.clip(to: CGRect(x: lb.minX, y: CGFloat(height) - lb.maxY, width: lb.width, height: lb.height))
                if let m = l.mask { c.ctx.clip(to: c.rect, mask: m.greyImage(refreshing: lb)) }
                c.ctx.setAlpha(l.opacity)
                c.ctx.setBlendMode(l.blend.cg)
                c.ctx.draw(l.liveImage(), in: c.rect)
                c.ctx.restoreGState()
            }
            c.ctx.restoreGState()
        }
        compImage = c.liveImage()
        return compImage!
    }

    /// An adjustment layer at work: run its adjustment on what's below (in `c`, inside `r`) and blend
    /// the result back by the layer's own pixels (white = all of it), its mask and its opacity.
    static func apply(_ f: Filter, _ values: [Double], of l: Layer, to c: Layer, in r: CGRect) {
        let x0 = Int(r.minX), y0 = Int(r.minY), rw = Int(r.width), rh = Int(r.height), w = c.width
        guard rw > 0, rh > 0 else { return }
        let src = UnsafeMutablePointer<UInt8>.allocate(capacity: rw * rh * 4)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: rw * rh * 4)
        defer { src.deallocate(); dst.deallocate() }
        for y in 0..<rh { memcpy(src + y * rw * 4, c.bytes + ((y0 + y) * w + x0) * 4, rw * 4) }
        memcpy(dst, src, rw * rh * 4)
        f.run(FilterIO(src: src, dst: dst, w: rw, h: rh, primary: .black, secondary: .white), values)
        let op = Int((l.opacity * 255).rounded()), m = l.mask
        parallelRows(rh) { y in
            for x in 0..<rw {
                let gi = (y0 + y) * w + x0 + x
                var k = l.greyValue(gi) * op / 255
                if let m { k = k * m.greyValue(gi) / 255 }
                if k == 0 { continue }
                let o = gi * 4, s = (y * rw + x) * 4
                for ch in 0..<4 {
                    let a = Int(c.bytes[o + ch])
                    c.bytes[o + ch] = UInt8(a + (Int(dst[s + ch]) - a) * k / 255)
                }
            }
        }
    }

    /// Composite pixels (premultiplied RGBA, stride width*4).
    func compositeBytes() -> UnsafePointer<UInt8> {
        composite()
        return UnsafePointer(comp!.bytes)
    }

    func compositePixel(_ x: Int, _ y: Int) -> RGBA {
        composite()
        return comp!.pixel(x, y)
    }

    func flattenedImage(onto bg: RGBA? = nil) -> CGImage {
        let img = composite()
        guard let bg else { return img }
        let l = Layer(width: width, height: height, name: "")
        l.fill(bg)
        l.ctx.draw(img, in: l.rect)
        return l.image()
    }

    // MARK: Image operations

    func transform(_ op: GeoOp) {
        layers = layers.map { $0.remapped(op) }
        selection = selection?.remapped(op)
        if op == .rotCW || op == .rotCCW { swap(&width, &height) }
    }

    func transformActiveLayer(_ op: GeoOp) {
        activeLayer.rasterize()
        let n = activeLayer.remapped(op)
        memcpy(activeLayer.bytes, n.bytes, n.count)
        // Both change, so both get new revisions (history matches layers by revision; commit may only touch the mask).
        activeLayer.touch()
        if let m = activeLayer.mask, let nm = n.mask { memcpy(m.bytes, nm.bytes, nm.count); m.touch() }
    }

    /// Redraw a text, shape or object layer into `n` from its recipe, mapped by p → p·k + d, so
    /// geometry changes keep it sharp and editable. Returns false for ordinary pixel layers.
    @discardableResult
    func carryLive(_ l: Layer, into n: Layer, kx: CGFloat, ky: CGFloat, dx: CGFloat, dy: CGFloat) -> Bool {
        let k = (kx + ky) / 2
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * kx + dx, y: p.y * ky + dy) }
        if var t = l.text {
            t.anchor = map(t.anchor)
            t.fontSize *= k; t.outlineWidth *= k; t.outline2Width *= k; t.shadowDistance *= k; t.shadowBlur *= k
            t.glowSize *= k; t.tracking *= k; t.boxPadding *= k; t.boxRadius *= k
            n.text = t
            TextEditor.render(t, into: n)
            return true
        }
        if var o = l.object {
            o.center = map(o.center); o.sx *= kx; o.sy *= ky
            n.object = o
            o.render(into: n)
            return true
        }
        if var sh = l.shape {
            let a = map(sh.frame.origin)
            sh.frame = CGRect(x: a.x, y: a.y, width: sh.frame.width * kx, height: sh.frame.height * ky)
            sh.width *= k
            n.shape = sh
            sh.render(into: n)
            return true
        }
        return false
    }

    func resize(width nw: Int, height nh: Int, smooth: Bool) {
        let kx = CGFloat(nw) / CGFloat(width), ky = CGFloat(nh) / CGFloat(height)
        layers = layers.map { l in
            let n = Layer(width: nw, height: nh, name: l.name)
            n.copyLook(from: l)
            if let m = l.mask {
                let nm = Layer(width: nw, height: nh, name: m.name)
                nm.ctx.draw(m.image(), in: nm.rect)
                n.mask = nm
            }
            if carryLive(l, into: n, kx: kx, ky: ky, dx: 0, dy: 0) { return n }
            n.ctx.interpolationQuality = smooth ? .high : .none
            n.ctx.draw(l.image(), in: n.rect)
            return n
        }
        width = nw; height = nh
        selection = nil
    }

    func canvasSize(width nw: Int, height nh: Int, anchorX: Double, anchorY: Double, fill: RGBA) {
        let ox = Int((Double(nw - width) * anchorX).rounded(.down))
        let oy = Int((Double(nh - height) * anchorY).rounded(.down))
        layers = layers.enumerated().map { i, l in
            let n = Layer(width: nw, height: nh, name: l.name)
            n.copyLook(from: l)
            if let m = l.mask {
                // New area of a mask shows the layer (white), as does new area of an adjustment layer.
                let nm = Layer(width: nw, height: nh, name: m.name)
                nm.fill(.white)
                nm.drawImage(m.image(), at: CGPoint(x: ox, y: oy), blend: .copy)
                n.mask = nm
            }
            if carryLive(l, into: n, kx: 1, ky: 1, dx: CGFloat(ox), dy: CGFloat(oy)) { return n }
            if i == 0 { n.fill(fill) }
            if l.adjustment != nil { n.fill(.white) }
            n.drawImage(l.image(), at: CGPoint(x: ox, y: oy), blend: .copy)
            return n
        }
        width = nw; height = nh
        selection = selection.map { s in
            var m = [UInt8](repeating: 0, count: nw * nh)
            for y in 0..<s.height {
                let ny = y + oy
                if ny < 0 || ny >= nh { continue }
                for x in 0..<s.width {
                    let nx = x + ox
                    if nx < 0 || nx >= nw { continue }
                    m[ny * nw + nx] = s.mask[y * s.width + x]
                }
            }
            return Selection(width: nw, height: nh, mask: m)
        }
    }

    func crop(to sel: Selection) {
        let b = sel.bounds
        guard !b.isEmpty else { return }
        let bx = Int(b.minX), by = Int(b.minY), bw = Int(b.width), bh = Int(b.height)
        let isRect = sel.mask.allSatisfy { $0 == 0 || $0 == 255 } && {
            for y in by..<(by + bh) { for x in bx..<(bx + bw) where sel.mask[y * width + x] != 255 { return false } }
            return true
        }()
        layers = layers.map { l in
            let n = Layer(width: bw, height: bh, name: l.name)
            n.copyLook(from: l)
            if let m = l.mask {
                let nm = Layer(width: bw, height: bh, name: m.name)
                nm.drawImage(m.image(), at: CGPoint(x: -bx, y: -by), blend: .copy)
                n.mask = nm
            }
            if isRect && carryLive(l, into: n, kx: 1, ky: 1, dx: CGFloat(-bx), dy: CGFloat(-by)) { return n }
            n.drawImage(l.image(), at: CGPoint(x: -bx, y: -by), blend: .copy)
            if !isRect {
                for y in 0..<bh {
                    for x in 0..<bw {
                        let m = Int(sel.mask[(y + by) * width + (x + bx)])
                        if m == 255 { continue }
                        let i = (y * bw + x) * 4
                        for k in 0..<4 { n.bytes[i + k] = UInt8(Int(n.bytes[i + k]) * m / 255) }
                    }
                }
            }
            return n
        }
        width = bw; height = bh
        selection = nil
    }

    func flatten() {
        let l = Layer.from(image: composite(), name: "Background")
        layers = [l]
        active = 0
    }

    // MARK: Layer operations

    func nextLayerName() -> String {
        var n = layers.count + 1
        while layers.contains(where: { $0.name == "Layer \(n)" }) { n += 1 }
        return "Layer \(n)"
    }

    func addLayer(_ l: Layer? = nil) {
        let layer = l ?? Layer(width: width, height: height, name: nextLayerName())
        layers.insert(layer, at: active + 1)
        active += 1
    }

    func deleteLayer() {
        guard layers.count > 1 else { return }
        layers.remove(at: active)
        active = max(0, active - 1)
    }

    func duplicateLayer() {
        let d = activeLayer.duplicate(name: activeLayer.name + " copy")
        layers.insert(d, at: active + 1)
        active += 1
    }

    func mergeDown() {
        guard active > 0 else { return }
        let top = layers[active], below = layers[active - 1]
        below.rasterize()
        if top.visible, let adj = top.adjustment {
            // An adjustment merged down is applied to that layer's pixels for good.
            if let f = adj.filter { Document.apply(f, adj.values, of: top, to: below, in: below.rect) }
        } else if top.visible {
            below.ctx.saveGState()
            below.ctx.setAlpha(top.opacity)
            below.ctx.setBlendMode(top.blend.cg)
            if let m = top.mask { below.ctx.clip(to: below.rect, mask: m.greyImage(refreshing: m.rect)) }
            below.ctx.draw(top.image(), in: below.rect)
            below.ctx.restoreGState()
        }
        below.touch()
        layers.remove(at: active)
        active -= 1
    }

    func moveLayer(up: Bool) {
        let to = active + (up ? 1 : -1)
        guard to >= 0, to < layers.count else { return }
        layers.swapAt(active, to)
        active = to
    }

    // MARK: File IO

    static func load(url: URL) throws -> Document {
        let d = try loadUnchecked(url: url)
        guard Limits.ok(d.width, d.height) else {
            throw SoothError(message: "“\(url.lastPathComponent)” is \(d.width) × \(d.height), larger than Sooth can edit.")
        }
        return d
    }

    private static func loadUnchecked(url: URL) throws -> Document {
        let ext = url.pathExtension.lowercased()
        if ext == "sooth" || ext == "easel" { return try loadLayered(url) }
        if ext == "pdn" { return try PDNReader.load(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw SoothError(message: "Sooth can't read “\(url.lastPathComponent)”.")
        }
        let pw = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let ph = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard pw > 0, ph > 0 else { throw SoothError(message: "Sooth can't read “\(url.lastPathComponent)”.") }
        guard Limits.ok(pw, ph) else { throw SoothError(message: "“\(url.lastPathComponent)” is \(pw) × \(ph), larger than Sooth can edit.") }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pw, ph, 1),
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SoothError(message: "Sooth can't decode “\(url.lastPathComponent)”.")
        }
        let d = Document(layers: [Layer.from(image: img, name: "Background")])
        d.fileURL = url
        d.fileFormat = SaveFormat.from(url: url)
        return d
    }

    private static func loadLayered(_ url: URL) throws -> Document {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let w = root["width"] as? Int, let h = root["height"] as? Int,
              let ls = root["layers"] as? [[String: Any]], !ls.isEmpty else {
            throw SoothError(message: "“\(url.lastPathComponent)” isn't a valid Sooth file.")
        }
        guard Limits.ok(w, h), ls.count <= 500 else { throw SoothError(message: "“\(url.lastPathComponent)” is too large to open.") }
        var layers: [Layer] = []
        for d in ls {
            let l = Layer(width: w, height: h, name: d["name"] as? String ?? "Layer")
            if let png = d["png"] as? Data, let src = CGImageSourceCreateWithData(png as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                l.ctx.setBlendMode(.copy)
                l.ctx.draw(img, in: l.rect)
                l.ctx.setBlendMode(.normal)
            }
            l.visible = d["visible"] as? Bool ?? true
            if let t = d["text"] as? [String: Any] { l.text = TextSpec(plist: t) }
            if let o = d["object"] as? [String: Any] { l.object = ObjectSpec(plist: o) }
            if let sh = d["shape"] as? [String: Any] { l.shape = ShapeSpec(plist: sh) }
            l.opacity = CGFloat(d["opacity"] as? Double ?? 1)
            l.blend = BlendMode(rawValue: d["blend"] as? Int ?? 0) ?? .normal
            if let a = d["adjustment"] as? [String: Any] { l.adjustment = AdjustmentSpec(plist: a) }
            if let png = d["mask"] as? Data, let src = CGImageSourceCreateWithData(png as CFData, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let m = Layer(width: w, height: h, name: "Mask")
                m.ctx.setBlendMode(.copy); m.ctx.draw(img, in: m.rect); m.ctx.setBlendMode(.normal)
                l.mask = m
            }
            layers.append(l)
        }
        let doc = Document(layers: layers, active: root["active"] as? Int ?? 0)
        doc.fileURL = url
        doc.fileFormat = .sooth
        return doc
    }

    /// Everything a .sooth file needs, captured on the main thread; encoding it is safe anywhere.
    struct Snapshot {
        struct L {
            let name: String, visible: Bool, opacity: CGFloat, blend: BlendMode, image: CGImage, text: TextSpec?, object: ObjectSpec?, shape: ShapeSpec?
            var adjustment: AdjustmentSpec? = nil
            var mask: CGImage? = nil
        }
        let width: Int, height: Int, active: Int, layers: [L]
        var extra: [String: Any] = [:]

        func encode() throws -> Data {
            let ls: [[String: Any]] = try layers.map { l in
                var d: [String: Any] = ["name": l.name, "visible": l.visible, "opacity": Double(l.opacity), "blend": l.blend.rawValue,
                                        "png": try Document.encode(l.image, as: .png)]
                if let t = l.text { d["text"] = t.plist }
                if let o = l.object { d["object"] = o.plist }
                if let sh = l.shape { d["shape"] = sh.plist }
                if let a = l.adjustment { d["adjustment"] = a.plist }
                if let m = l.mask { d["mask"] = try Document.encode(m, as: .png) }
                return d
            }
            var root: [String: Any] = ["format": "sooth", "version": 1, "width": width, "height": height, "active": active, "layers": ls]
            for (k, v) in extra { root[k] = v }
            return try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        }
    }

    func snapshotForSaving() -> Snapshot {
        Snapshot(width: width, height: height, active: active,
                 layers: layers.map { .init(name: $0.name, visible: $0.visible, opacity: $0.opacity, blend: $0.blend,
                                            image: $0.image(), text: $0.text, object: $0.object, shape: $0.shape,
                                            adjustment: $0.adjustment, mask: $0.mask?.image()) })
    }

    func save(to url: URL, format: SaveFormat) throws {
        if format == .sooth {
            try snapshotForSaving().encode().write(to: url, options: .atomic)
            return
        }
        let img = format == .jpeg || format == .bmp ? flattenedImage(onto: .white) : composite()
        try Document.encode(img, as: format).write(to: url, options: .atomic)
    }

    static func encode(_ img: CGImage, as format: SaveFormat) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil) else {
            throw SoothError(message: "This Mac can't write \(format.title) files.")
        }
        var props: [CFString: Any] = [:]
        if format == .jpeg || format == .heic { props[kCGImageDestinationLossyCompressionQuality] = Double(AppState.shared.exportQuality) }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw SoothError(message: "Couldn't encode the image.") }
        return out as Data
    }
}
