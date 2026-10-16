import AppKit

// MARK: - Color

let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let graySpace = CGColorSpaceCreateDeviceGray()

struct RGBA: Hashable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 255, g: 255, b: 255)
    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ ns: NSColor) {
        let c = ns.usingColorSpace(.sRGB) ?? NSColor.black
        func q(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        r = q(c.redComponent); g = q(c.greenComponent); b = q(c.blueComponent); a = q(c.alphaComponent)
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = UInt8(v >> 16 & 255); g = UInt8(v >> 8 & 255); b = UInt8(v & 255); a = 255
        } else {
            r = UInt8(v >> 24 & 255); g = UInt8(v >> 16 & 255); b = UInt8(v >> 8 & 255); a = UInt8(v & 255)
        }
    }

    var ns: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
    var cg: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
    var hex: String { String(format: "%02X%02X%02X", r, g, b) + (a == 255 ? "" : String(format: "%02X", a)) }
}

@inline(__always) func unpremul(_ c: UInt8, _ a: UInt8) -> UInt8 {
    a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a)))
}
@inline(__always) func premul(_ c: Int, _ a: Int) -> UInt8 { UInt8((c * a + 127) / 255) }
@inline(__always) func clamp8(_ v: Double) -> UInt8 { v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v + 0.5)) }
@inline(__always) func clamp8(_ v: Int) -> UInt8 { v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v)) }

// MARK: - Blend modes

enum BlendMode: Int, CaseIterable {
    case normal, multiply, additive, colorBurn, colorDodge, overlay, softLight, hardLight,
         difference, exclusion, lighten, darken, screen, hue, saturation, color, luminosity

    var title: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .additive: "Additive"
        case .colorBurn: "Color Burn"
        case .colorDodge: "Color Dodge"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        case .lighten: "Lighten"
        case .darken: "Darken"
        case .screen: "Screen"
        case .hue: "Hue"
        case .saturation: "Saturation"
        case .color: "Color"
        case .luminosity: "Luminosity"
        }
    }

    var cg: CGBlendMode {
        switch self {
        case .normal: .normal
        case .multiply: .multiply
        case .additive: .plusLighter
        case .colorBurn: .colorBurn
        case .colorDodge: .colorDodge
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .lighten: .lighten
        case .darken: .darken
        case .screen: .screen
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}

// MARK: - Layer

/// Revisions, unique across all layers. Background work (cut-outs, content-aware fill) makes layers
/// too, so the counter is locked: a lost update could hand two layers the same revision.
enum Rev {
    nonisolated(unsafe) private static var counter = 0
    private static let lock = NSLock()
    static func next() -> Int { lock.lock(); defer { lock.unlock() }; counter += 1; return counter }
}

/// One raster layer: premultiplied RGBA8, tightly packed (stride = width * 4),
/// row 0 is the top of the image.
final class Layer {
    var name: String
    var visible = true
    var opacity: CGFloat = 1
    var blend: BlendMode = .normal
    /// Set on text layers: the pixels are a rendering of this, and it stays editable until the
    /// layer is painted on, filtered, merged or flattened.
    var text: TextSpec?
    /// Set on object layers (pasted or imported images, cut-outs): moved and resized losslessly.
    var object: ObjectSpec?
    /// Set on shape layers: the shape stays editable.
    var shape: ShapeSpec?
    /// A layer mask: where it is white the layer shows, where black it's hidden (grey between).
    /// It is an ordinary layer, so every brush, fill and effect works on it.
    var mask: Layer?
    /// Set on adjustment layers: the adjustment is applied live to everything below. The layer's own
    /// pixels say where (white applies, black or clear doesn't); they are never drawn themselves.
    var adjustment: AdjustmentSpec?
    /// Luminance of the pixels, for using this layer as a mask (refreshed region by region).
    private var grey: UnsafeMutablePointer<UInt8>?
    let width: Int
    let height: Int
    let bytes: UnsafeMutablePointer<UInt8>
    let ctx: CGContext
    var rev = Rev.next()
    /// Last history snapshot, kept so the next one can share unchanged bands.
    var bandCache: (rev: Int, bands: [Data])?
    static let bandRows = 32

    init(width: Int, height: Int, name: String) {
        self.width = width; self.height = height; self.name = name
        bytes = .allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 0, count: width * height * 4)
        ctx = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: sRGBSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
    }

    deinit { bytes.deallocate(); grey?.deallocate() }

    /// Visibility, opacity, blend and adjustment from `l` (geometry operations rebuild layers).
    func copyLook(from l: Layer) {
        visible = l.visible; opacity = l.opacity; blend = l.blend; adjustment = l.adjustment
    }

    /// How much of a pixel shows through this layer used as a mask, 0…255 (luminance × alpha).
    @inline(__always) func greyValue(_ i: Int) -> Int {
        let p = i * 4
        return (77 * Int(bytes[p]) + 150 * Int(bytes[p + 1]) + 29 * Int(bytes[p + 2])) >> 8
    }

    /// This layer as a grey mask image (white shows, black hides), refreshed inside `r` first.
    /// Like `liveImage`, it reads live memory: draw or clip with it at once.
    func greyImage(refreshing r: CGRect) -> CGImage {
        if grey == nil {
            grey = .allocate(capacity: width * height)
            grey!.initialize(repeating: 0, count: width * height)
            refreshGrey(rect)
        } else {
            refreshGrey(r)
        }
        let info = Unmanaged.passRetained(self).toOpaque()
        let provider = CGDataProvider(dataInfo: info, data: grey!, size: width * height) { info, _, _ in
            Unmanaged<Layer>.fromOpaque(info!).release()
        }!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: graySpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func refreshGrey(_ r: CGRect) {
        let ir = r.integral.intersection(rect)
        guard let g = grey, !ir.isNull, !ir.isEmpty else { return }
        let x0 = Int(ir.minX), x1 = Int(ir.maxX)
        parallelRows(Int(ir.height)) { k in
            let y = Int(ir.minY) + k
            for x in x0..<x1 { g[y * self.width + x] = UInt8(self.greyValue(y * self.width + x)) }
        }
    }

    var count: Int { width * height * 4 }
    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// A copy-on-write snapshot image; safe to keep while the layer changes.
    func image() -> CGImage { ctx.makeImage()! }

    /// An image that reads the layer's live pixels without copying them. Draw it at once and
    /// don't keep it: it shows whatever the layer holds at the time it is drawn.
    func liveImage() -> CGImage {
        let info = Unmanaged.passRetained(self).toOpaque()
        let provider = CGDataProvider(dataInfo: info, data: bytes, size: count) { info, _, _ in
            Unmanaged<Layer>.fromOpaque(info!).release()
        }!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGBSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Full pixel copy, for in-progress tool and filter restores.
    func data() -> Data { Data(bytes: bytes, count: count) }

    /// History snapshot as row bands. A band equal to the previous snapshot's is shared rather
    /// than copied, so an edit costs only the rows it touched.
    func bands() -> [Data] {
        if let c = bandCache, c.rev == rev { return c.bands }
        let rowBytes = width * 4
        let prev = bandCache?.bands
        var out: [Data] = []
        out.reserveCapacity((height + Layer.bandRows - 1) / Layer.bandRows)
        var y = 0, i = 0
        while y < height {
            let off = y * rowBytes, len = min(Layer.bandRows, height - y) * rowBytes
            if let p = prev, i < p.count, p[i].count == len,
               p[i].withUnsafeBytes({ memcmp($0.baseAddress!, bytes + off, len) }) == 0 {
                out.append(p[i])
            } else {
                out.append(Data(bytes: bytes + off, count: len))
            }
            y += Layer.bandRows; i += 1
        }
        bandCache = (rev, out)
        return out
    }

    func load(bands: [Data]) {
        var off = 0
        for b in bands {
            _ = b.withUnsafeBytes { raw in memcpy(bytes + off, raw.baseAddress!, min(raw.count, count - off)) }
            off += b.count
        }
    }

    func load(_ d: Data) {
        _ = d.withUnsafeBytes { raw in memcpy(bytes, raw.baseAddress!, min(count, raw.count)) }
    }

    /// Restore only the rows/columns of `r` (image coords) from a snapshot.
    func load(_ d: Data, rect r: CGRect) {
        let ir = r.integral.intersection(rect)
        if ir.isNull || ir.isEmpty { return }
        let x0 = Int(ir.minX), x1 = Int(ir.maxX), y0 = Int(ir.minY), y1 = Int(ir.maxY)
        d.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in y0..<y1 {
                let o = (y * width + x0) * 4
                memcpy(bytes + o, src + o, (x1 - x0) * 4)
            }
        }
    }

    func touch() { rev = Rev.next() }

    private var boundsCache: (rev: Int, rect: CGRect)?
    /// Bounding box of the non-transparent pixels (image coordinates), cached until the layer changes.
    /// Live layers know theirs without scanning.
    var contentBounds: CGRect {
        if let c = boundsCache, c.rev == rev { return c.rect }
        var r: CGRect
        if let o = object { r = o.extent }
        else if let sh = shape { r = sh.extent }
        else if let t = text { r = TextEditor.frame(of: t).insetBy(dx: -4, dy: -4) }
        else {
            var x0 = width, y0 = height, x1 = -1, y1 = -1
            for y in 0..<height {
                let row = bytes + y * width * 4
                var first = -1, last = -1
                var x = 0
                while x < width { if row[x * 4 + 3] != 0 { first = x; break }; x += 1 }
                if first < 0 { continue }
                x = width - 1
                while x >= first { if row[x * 4 + 3] != 0 { last = x; break }; x -= 1 }
                x0 = min(x0, first); x1 = max(x1, last); y0 = min(y0, y); y1 = y
            }
            r = x1 < 0 ? .null : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
        }
        r = r.intersection(self.rect)
        boundsCache = (rev, r)
        return r
    }

    /// Pixels in `r` were just drawn without a new revision (a stroke in progress): widen the cached
    /// content bounds over them and forget the opacity check, so the composite shows them at once.
    func drew(in r: CGRect) {
        if let c = boundsCache, c.rev == rev {
            let grown = c.rect.isNull ? r : c.rect.union(r)
            boundsCache = (rev, grown.intersection(rect))
        }
        opaqueCache = nil
    }

    private var thumbCache: (rev: Int, image: NSImage)?
    /// Layers-panel thumbnail, cached until the layer changes.
    func thumbnail(_ make: (CGImage) -> NSImage) -> NSImage {
        if let c = thumbCache, c.rev == rev { return c.image }
        // Text, shapes and cut-outs show their own content, zoomed to fit; plain layers show the canvas.
        var img = image()
        if text != nil || shape != nil || object != nil {
            let b = contentBounds.insetBy(dx: -4, dy: -4).intersection(rect).integral
            if !b.isNull, b.width >= 2, b.height >= 2, let crop = img.cropping(to: b) { img = crop }
        }
        let t = make(img)
        thumbCache = (rev, t)
        return t
    }

    private var opaqueCache: (rev: Int, opaque: Bool)?
    /// Every pixel fully opaque (cached until the layer changes).
    var isFullyOpaque: Bool {
        if let c = opaqueCache, c.rev == rev { return c.opaque }
        var ok = true
        let n = width * height
        var i = 3
        while i < n * 4 { if bytes[i] != 255 { ok = false; break }; i += 4 }
        opaqueCache = (rev, ok)
        return ok
    }

    func fill(_ c: RGBA) {
        ctx.saveGState(); ctx.setBlendMode(.copy); ctx.setFillColor(c.cg); ctx.fill(rect); ctx.restoreGState()
    }

    func duplicate(name: String? = nil) -> Layer {
        let l = Layer(width: width, height: height, name: name ?? self.name)
        memcpy(l.bytes, bytes, count)
        l.visible = visible; l.opacity = opacity; l.blend = blend; l.text = text; l.object = object; l.shape = shape
        l.adjustment = adjustment
        l.mask = mask?.duplicate()
        return l
    }

    func pixel(_ x: Int, _ y: Int) -> RGBA {
        guard x >= 0, y >= 0, x < width, y < height else { return .clear }
        let i = (y * width + x) * 4
        let a = bytes[i + 3]
        return RGBA(r: unpremul(bytes[i], a), g: unpremul(bytes[i + 1], a), b: unpremul(bytes[i + 2], a), a: a)
    }

    /// Draw an image with its top-left at `origin` in image coordinates.
    func drawImage(_ img: CGImage, at origin: CGPoint, blend: CGBlendMode = .normal) {
        ctx.saveGState()
        ctx.setBlendMode(blend)
        ctx.draw(img, in: CGRect(x: origin.x, y: CGFloat(height) - origin.y - CGFloat(img.height),
                                 width: CGFloat(img.width), height: CGFloat(img.height)))
        ctx.restoreGState()
    }

    static func from(image: CGImage, name: String) -> Layer {
        let l = Layer(width: image.width, height: image.height, name: name)
        l.ctx.draw(image, in: l.rect)
        return l
    }
}

// MARK: - Geometry remaps

enum GeoOp { case flipH, flipV, rotCW, rotCCW, rot180 }

func remap<T>(_ src: UnsafePointer<T>, _ dst: UnsafeMutablePointer<T>, w: Int, h: Int, op: GeoOp) {
    switch op {
    case .flipH:
        for y in 0..<h { let r = y * w; for x in 0..<w { dst[r + (w - 1 - x)] = src[r + x] } }
    case .flipV:
        for y in 0..<h { let s = y * w, d = (h - 1 - y) * w; for x in 0..<w { dst[d + x] = src[s + x] } }
    case .rotCW:
        for y in 0..<h { for x in 0..<w { dst[x * h + (h - 1 - y)] = src[y * w + x] } }
    case .rotCCW:
        for y in 0..<h { for x in 0..<w { dst[(w - 1 - x) * h + y] = src[y * w + x] } }
    case .rot180:
        let n = w * h
        for i in 0..<n { dst[n - 1 - i] = src[i] }
    }
}

extension Layer {
    func remapped(_ op: GeoOp) -> Layer {
        let swap = op == .rotCW || op == .rotCCW
        let n = Layer(width: swap ? height : width, height: swap ? width : height, name: name)
        n.copyLook(from: self)
        n.mask = mask?.remapped(op)
        bytes.withMemoryRebound(to: UInt32.self, capacity: width * height) { s in
            n.bytes.withMemoryRebound(to: UInt32.self, capacity: width * height) { d in
                remap(UnsafePointer(s), d, w: width, h: height, op: op)
            }
        }
        return n
    }
}

// MARK: - Selection

enum SelectMode: Int, CaseIterable {
    case replace, union, exclude, intersect, xor
    var title: String {
        switch self {
        case .replace: "Replace"
        case .union: "Add (union)"
        case .exclude: "Subtract"
        case .intersect: "Intersect"
        case .xor: "Invert (xor)"
        }
    }
}

/// A selection is an 8-bit coverage mask the size of the image (row 0 = top).
final class Selection {
    let width: Int
    let height: Int
    let mask: [UInt8]
    let hint: CGPath?

    init(width: Int, height: Int, mask: [UInt8], hint: CGPath? = nil) {
        self.width = width; self.height = height; self.mask = mask; self.hint = hint
    }

    static func path(_ p: CGPath, width: Int, height: Int, antialias: Bool = true) -> Selection {
        var m = [UInt8](repeating: 0, count: width * height)
        m.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c.setShouldAntialias(antialias)
            c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
            c.addPath(p); c.setFillColor(gray: 1, alpha: 1); c.fillPath()
        }
        return Selection(width: width, height: height, mask: m, hint: p)
    }

    static func all(_ w: Int, _ h: Int) -> Selection {
        Selection(width: w, height: h, mask: [UInt8](repeating: 255, count: w * h),
                  hint: CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil))
    }

    lazy var image: CGImage = {
        let provider = CGDataProvider(data: Data(mask) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: graySpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }()

    lazy var outline: CGPath = hint ?? computeOutline()

    lazy var bounds: CGRect = {
        var x0 = width, y0 = height, x1 = -1, y1 = -1
        mask.withUnsafeBufferPointer { m in
            for y in 0..<height {
                let r = y * width
                var rowHas = false
                for x in 0..<width where m[r + x] != 0 {
                    if x < x0 { x0 = x }
                    if x > x1 { x1 = x }
                    rowHas = true
                }
                if rowHas { if y < y0 { y0 = y }; y1 = y }
            }
        }
        if x1 < 0 { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }()

    var isEmpty: Bool { bounds.isEmpty }

    private func computeOutline() -> CGPath {
        let p = CGMutablePath()
        let w = width, h = height
        mask.withUnsafeBufferPointer { m in
            @inline(__always) func inside(_ x: Int, _ y: Int) -> Bool {
                x >= 0 && y >= 0 && x < w && y < h && m[y * w + x] >= 128
            }
            for y in 0...h {
                var x = 0
                while x < w {
                    if inside(x, y - 1) != inside(x, y) {
                        let x0 = x
                        while x < w && inside(x, y - 1) != inside(x, y) { x += 1 }
                        p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x, y: y))
                    } else { x += 1 }
                }
            }
            for x in 0...w {
                var y = 0
                while y < h {
                    if inside(x - 1, y) != inside(x, y) {
                        let y0 = y
                        while y < h && inside(x - 1, y) != inside(x, y) { y += 1 }
                        p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y))
                    } else { y += 1 }
                }
            }
        }
        return p
    }

    func combine(_ o: Selection, _ mode: SelectMode) -> Selection {
        if mode == .replace { return o }
        var m = [UInt8](repeating: 0, count: mask.count)
        for i in 0..<m.count {
            let a = mask[i], b = o.mask[i]
            switch mode {
            case .replace: m[i] = b
            case .union: m[i] = max(a, b)
            case .exclude: m[i] = min(a, 255 - b)
            case .intersect: m[i] = min(a, b)
            case .xor: m[i] = max(a, b) - min(a, b)
            }
        }
        var hint: CGPath?
        if let h1 = self.hint, let h2 = o.hint {
            switch mode {
            case .union: hint = h1.union(h2)
            case .exclude: hint = h1.subtracting(h2)
            case .intersect: hint = h1.intersection(h2)
            case .xor: hint = h1.symmetricDifference(h2)
            case .replace: hint = h2
            }
        }
        return Selection(width: width, height: height, mask: m, hint: hint)
    }

    func inverted() -> Selection {
        Selection(width: width, height: height, mask: mask.map { 255 - $0 })
    }

    func offset(_ dx: Int, _ dy: Int) -> Selection {
        if dx == 0 && dy == 0 { return self }
        var m = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            let sy = y - dy
            if sy < 0 || sy >= height { continue }
            for x in 0..<width {
                let sx = x - dx
                if sx < 0 || sx >= width { continue }
                m[y * width + x] = mask[sy * width + sx]
            }
        }
        var t = CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))
        return Selection(width: width, height: height, mask: m, hint: hint?.copy(using: &t))
    }

    func remapped(_ op: GeoOp) -> Selection {
        let swap = op == .rotCW || op == .rotCCW
        var m = [UInt8](repeating: 0, count: mask.count)
        mask.withUnsafeBufferPointer { s in
            m.withUnsafeMutableBufferPointer { d in
                remap(s.baseAddress!, d.baseAddress!, w: width, h: height, op: op)
            }
        }
        return Selection(width: swap ? height : width, height: swap ? width : height, mask: m)
    }
}

// MARK: - Small helpers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
}

// MARK: - Adjustment layers

/// The adjustment an adjustment layer applies: which one, and its settings.
struct AdjustmentSpec: Equatable {
    var name: String
    var values: [Double]

    /// Adjustments that work pixel by pixel, so the picture can be redrawn a piece at a time.
    static let filters: [Filter] = Filters.adjustments.filter { !["Auto-Level", "Shadows / Highlights"].contains($0.name) }
    var filter: Filter? { AdjustmentSpec.filters.first { $0.name == name } }

    init(name: String, values: [Double]) { self.name = name; self.values = values }

    var plist: [String: Any] { ["name": name, "values": values] }
    init?(plist d: [String: Any]) {
        guard let n = d["name"] as? String, let v = d["values"] as? [Double] else { return nil }
        name = n; values = v
    }
}
