import AppKit
import Accelerate
import ImageIO

/// Background-removal settings kept on an object layer, so the cut-out can be re-tuned later.
struct Cutout {
    /// The subject mask as found (8-bit, source size).
    var raw: Data
    /// 0...100: higher keeps less (raises the cut-off of the soft mask).
    var strength: CGFloat = 50
    /// Edge feather radius in source pixels.
    var softness: CGFloat = 1
    /// Grow (+) or shrink (−) the mask by this many source pixels.
    var grow: CGFloat = 0
    /// Hand edits from the Eraser (source size): 128 = untouched, toward 0 = erased, toward 255 = restored.
    var edit: Data?
    /// Bumped whenever the mask or settings change.
    var rev = Rev.next()
}

/// A layer that remembers its original pixels and where they sit, so it can be moved, resized
/// and rotated any number of times without losing quality. Painting on it, filtering it or
/// merging it turns it into ordinary pixels.
struct ObjectSpec {
    let source: CGImage
    /// `source` with the cut-out applied (what is drawn).
    private(set) var display: CGImage
    var cutout: Cutout? {
        didSet { display = ObjectSpec.masked(source, cutout) }
    }
    var center: CGPoint
    var sx: CGFloat = 1, sy: CGFloat = 1, angle: CGFloat = 0
    /// Set on vector art: drawn from its paths, so it stays sharp at any size. `source` is the art
    /// rendered at its own size (for thumbnails and picking).
    var vector: VectorArt?

    init(source: CGImage, center: CGPoint, cutout: Cutout? = nil) {
        self.source = source
        self.cutout = cutout
        self.center = center
        display = ObjectSpec.masked(source, cutout)
    }

    /// Vector art as a picture layer: moved, resized and rotated by the same handles, redrawn sharp.
    init(vector v: VectorArt, center: CGPoint) {
        let w = max(1, Int(v.size.width.rounded())), h = max(1, Int(v.size.height.rounded()))
        let l = Layer(width: w, height: h, name: "")
        l.ctx.translateBy(x: 0, y: CGFloat(h)); l.ctx.scaleBy(x: 1, y: -1)
        v.draw(in: l.ctx)
        self.init(source: l.image(), center: center)
        vector = v
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }

    /// Source pixels (y down) → image coordinates.
    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle).scaledBy(x: sx, y: sy)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
    }

    var isPureMove: Bool {
        sx == 1 && sy == 1 && angle == 0
            && (center.x - bounds.midX).rounded() == center.x - bounds.midX
            && (center.y - bounds.midY).rounded() == center.y - bounds.midY
    }

    /// Axis-aligned box the drawn pixels can touch.
    var extent: CGRect { bounds.applying(transform).integral.insetBy(dx: -2, dy: -2) }

    /// A transform session that shares the Move tool's handle maths.
    var session: TransformSession {
        let s = TransformSession(pixels: false, layer: 0, bounds: bounds, base: nil, floating: nil, selection: nil,
                                 outline: CGPath(rect: bounds, transform: nil))
        s.center = center; s.sx = sx; s.sy = sy; s.angle = angle
        return s
    }

    mutating func take(_ s: TransformSession) { center = s.center; sx = s.sx; sy = s.sy; angle = s.angle }

    /// Draw into a layer, clearing `area` first (or the whole layer).
    func render(into L: Layer, clearing area: CGRect? = nil) {
        let c = L.ctx, H = CGFloat(L.height)
        c.saveGState()
        if let r = area?.integral.intersection(L.rect), !r.isNull {
            let cr = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            c.clip(to: cr)
            c.clear(cr)
        } else {
            L.fill(.clear)
        }
        c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
        draw(imageSpace: c)
        c.restoreGState()
        L.touch()
    }

    /// Draw into a y-down context in image coordinates, unclipped (also what shows past the canvas edge).
    func draw(imageSpace c: CGContext) {
        c.saveGState()
        c.concatenate(transform)
        if let v = vector, v.size.width > 0, v.size.height > 0 {
            c.scaleBy(x: bounds.width / v.size.width, y: bounds.height / v.size.height)
            c.setShouldAntialias(true)
            v.draw(in: c)
        } else {
            c.interpolationQuality = isPureMove ? .none : .high
            c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
            c.draw(display, in: bounds)
        }
        c.restoreGState()
    }

    // MARK: Cut-out

    /// The effective mask from a cut-out's raw mask and settings.
    static func mask(_ cut: Cutout, width w: Int, height h: Int) -> [UInt8] {
        var m = automatic(cut, width: w, height: h)
        if let e = cut.edit, e.count == m.count {
            e.withUnsafeBytes { eb in
                let ep = eb.bindMemory(to: UInt8.self)
                for i in 0..<m.count { m[i] = applyEdit(m[i], ep[i]) }
            }
        }
        return m
    }

    @inline(__always) static func applyEdit(_ m: UInt8, _ e: UInt8) -> UInt8 {
        if e == 128 { return m }
        if e < 128 { return UInt8(Int(m) * Int(e) / 128) }
        return UInt8(Int(m) + (255 - Int(m)) * (Int(e) - 128) / 127)
    }

    /// The mask from the detection and the sliders, before hand edits.
    static func automatic(_ cut: Cutout, width w: Int, height h: Int) -> [UInt8] {
        var m = [UInt8](cut.raw)
        if m.count != w * h { return [UInt8](repeating: 255, count: w * h) }
        // Grow / shrink with a max / min filter.
        let g = Int(cut.grow.rounded())
        if g != 0 {
            var out = m
            let k = vImagePixelCount(abs(g) * 2 + 1)
            m.withUnsafeMutableBytes { s in out.withUnsafeMutableBytes { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                if g > 0 { vImageMax_Planar8(&sb, &db, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend)) }
                else { vImageMin_Planar8(&sb, &db, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend)) }
            } }
            m = out
        }
        // Strength moves the cut-off along the soft mask; the transition band stays smooth.
        let mid = 0.15 + Double(cut.strength) / 100 * 0.7, band = 0.22
        let table: [UInt8] = (0..<256).map { v in
            let t = (Double(v) / 255 - (mid - band / 2)) / band
            let x = min(1, max(0, t))
            return UInt8((x * x * (3 - 2 * x) * 255).rounded())
        }
        for i in 0..<m.count { m[i] = table[Int(m[i])] }
        // Feather.
        let r = Double(cut.softness)
        if r >= 0.3 {
            var rgba = [UInt8](repeating: 0, count: w * h * 4), out = rgba
            for i in 0..<m.count { rgba[i * 4 + 3] = m[i] }
            rgba.withUnsafeBufferPointer { s in out.withUnsafeMutableBufferPointer { d in
                gaussian(s.baseAddress!, d.baseAddress!, w, h, sigma: r)
            } }
            for i in 0..<m.count { m[i] = out[i * 4 + 3] }
        }
        return m
    }

    static func masked(_ src: CGImage, _ cut: Cutout?) -> CGImage {
        guard let cut else { return src }
        let w = src.width, h = src.height
        let m = mask(cut, width: w, height: h)
        let l = Layer(width: w, height: h, name: "")
        l.ctx.draw(src, in: l.rect)
        for p in 0..<(w * h) {
            let k = Int(m[p])
            if k == 255 { continue }
            let i = p * 4
            for c in 0..<4 { l.bytes[i + c] = UInt8((Int(l.bytes[i + c]) * k + 127) / 255) }
        }
        return l.image()
    }

    // MARK: Files

    var plist: [String: Any] {
        var d: [String: Any] = ["cx": Double(center.x), "cy": Double(center.y), "sx": Double(sx), "sy": Double(sy),
                                "angle": Double(angle)]
        if let png = try? Document.encode(source, as: .png) { d["source"] = png }
        if let v = vector { d["vector"] = v.plist }
        if let c = cutout {
            d["cutRaw"] = (try? (c.raw as NSData).compressed(using: .zlib) as Data) ?? c.raw
            d["cutW"] = source.width
            d["cutStrength"] = Double(c.strength); d["cutSoftness"] = Double(c.softness); d["cutGrow"] = Double(c.grow)
            // The Eraser's hand edits, or they'd come back the next time the layer is redrawn.
            if let e = c.edit { d["cutEdit"] = (try? (e as NSData).compressed(using: .zlib) as Data) ?? e }
        }
        return d
    }

    init?(plist d: [String: Any]) {
        guard let png = d["source"] as? Data, let s = CGImageSourceCreateWithData(png as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else { return nil }
        var cut: Cutout?
        if let z = d["cutRaw"] as? Data {
            let raw = (try? (z as NSData).decompressed(using: .zlib) as Data) ?? z
            cut = Cutout(raw: raw, strength: CGFloat(d["cutStrength"] as? Double ?? 50),
                         softness: CGFloat(d["cutSoftness"] as? Double ?? 1), grow: CGFloat(d["cutGrow"] as? Double ?? 0))
            if let z = d["cutEdit"] as? Data {
                let e = (try? (z as NSData).decompressed(using: .zlib) as Data) ?? z
                if e.count == raw.count { cut?.edit = e }
            }
        }
        self.init(source: img, center: CGPoint(x: d["cx"] as? Double ?? 0, y: d["cy"] as? Double ?? 0), cutout: cut)
        sx = CGFloat(d["sx"] as? Double ?? 1); sy = CGFloat(d["sy"] as? Double ?? 1); angle = CGFloat(d["angle"] as? Double ?? 0)
        if let v = d["vector"] as? [String: Any] { vector = VectorArt(plist: v) }
    }
}

/// The Eraser on an object layer: edits its mask (left = erase, right = restore) instead of its
/// pixels, so nothing is lost and a cut-out's fringes can be fixed by hand.
final class MaskBrush {
    private var spec: ObjectSpec
    private let w: Int, h: Int
    private let base: [UInt8]          // automatic mask (before hand edits)
    private let edit0: [UInt8]
    private var edit: [UInt8]
    private var stroke: [UInt8]
    private let src: Layer             // original pixels
    private let shown: Layer           // what is drawn, updated as you paint
    private let restore: Bool
    private let opacity: Int
    private let hardness: CGFloat
    private var last: CGPoint?
    private var carry: CGFloat = 0

    init(spec: ObjectSpec, restore: Bool, opacity: CGFloat, hardness: CGFloat) {
        self.spec = spec
        w = spec.source.width; h = spec.source.height
        let cut = spec.cutout ?? Cutout(raw: Data(repeating: 255, count: spec.source.width * spec.source.height))
        base = ObjectSpec.automatic(cut, width: w, height: h)
        edit0 = cut.edit.map { [UInt8]($0) } ?? [UInt8](repeating: 128, count: w * h)
        edit = edit0
        stroke = [UInt8](repeating: 0, count: w * h)
        src = Layer.from(image: spec.source, name: "")
        shown = Layer.from(image: spec.display, name: "")
        self.restore = restore
        self.opacity = Int((max(0, min(1, opacity)) * 255).rounded())
        self.hardness = hardness
        self.spec.cutout = cut
    }

    /// Paint to image point `p` with brush diameter `size`; redraw into `L`. Returns the image rect changed.
    func add(_ p: CGPoint, size: CGFloat, into L: Layer) -> CGRect {
        let inv = spec.transform.inverted()
        let scale = max(0.01, (abs(spec.sx) + abs(spec.sy)) / 2)
        let q = p.applying(inv), d = size / scale
        var dirty = CGRect.null
        if let a = last {
            let v = q - a, len = v.length, step = max(0.5, d * 0.1)
            var t = step - carry
            while t <= len { dirty = dirty.union(dab(a + v * (len == 0 ? 1 : t / len), d)); t += step }
            carry = len - (t - step)
        } else {
            dirty = dab(q, d)
        }
        last = q
        guard !dirty.isNull else { return .null }
        // Draw just the changed part, through the object's transform.
        let area = dirty.applying(spec.transform).integral.insetBy(dx: -2, dy: -2).intersection(L.rect)
        let c = L.ctx, H = CGFloat(L.height)
        c.saveGState()
        let cr = CGRect(x: area.minX, y: H - area.maxY, width: area.width, height: area.height)
        c.clip(to: cr); c.clear(cr)
        c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
        c.concatenate(spec.transform)
        c.interpolationQuality = spec.isPureMove ? .none : .high
        c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
        c.draw(shown.liveImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        c.restoreGState()
        return area
    }

    private func dab(_ c: CGPoint, _ diameter: CGFloat) -> CGRect {
        let r = max(0.5, diameter / 2)
        let x0 = max(0, Int(floor(c.x - r - 1))), x1 = min(w - 1, Int(ceil(c.x + r + 1)))
        let y0 = max(0, Int(floor(c.y - r - 1))), y1 = min(h - 1, Int(ceil(c.y + r + 1)))
        guard x0 <= x1, y0 <= y1 else { return .null }
        let inner = r * hardness, soft = max(1, r - inner)
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = CGFloat(x) + 0.5 - c.x, dy = CGFloat(y) + 0.5 - c.y
                let dist = (dx * dx + dy * dy).squareRoot()
                var cov = min(1, max(0, r + 0.5 - dist))
                if hardness < 0.99 && dist > inner { let t = min(1, (dist - inner) / soft); cov *= 1 - t * t * (3 - 2 * t) }
                guard cov > 0 else { continue }
                let p = y * w + x
                let v = UInt8(cov * 255 + 0.5)
                if v <= stroke[p] { continue }
                stroke[p] = v
                let k = Int(v) * opacity / 255
                let e0 = Int(edit0[p])
                edit[p] = UInt8(restore ? e0 + (255 - e0) * k / 255 : e0 * (255 - k) / 255)
                let m = Int(ObjectSpec.applyEdit(base[p], edit[p]))
                let i = p * 4
                for ch in 0..<4 { shown.bytes[i + ch] = UInt8((Int(src.bytes[i + ch]) * m + 127) / 255) }
            }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// The object with this stroke's edits kept.
    func finish() -> ObjectSpec {
        var cut = spec.cutout!
        cut.edit = Data(edit)
        cut.rev = Rev.next()
        var s = spec
        s.cutout = cut
        return s
    }
}

extension Layer {
    /// Turn a text or object layer into ordinary pixels (they are already drawn; just forget the recipe).
    func rasterize() { text = nil; object = nil; shape = nil }
    var isLive: Bool { text != nil || object != nil || shape != nil }
}
