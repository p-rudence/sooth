import AppKit

// MARK: - Vector art

/// Vector art traced from pixels: filled regions in the art's own space (y down, 0…size).
///
/// Regions overlap slightly: each one reaches a couple of pixels under the opaque regions painted
/// above it, so plain antialiased fills meet without hairline seams at any scale, in `draw` and in
/// `svg` alike. Paths use the nonzero rule (outlines run one way, holes the other).
struct VectorArt: Equatable {
    struct Region: Equatable { var path: CGPath; var color: RGBA }
    var size: CGSize
    var regions: [Region]        // painted in order, first = bottom

    init(size: CGSize, regions: [Region]) { self.size = size; self.regions = regions }

    /// Fill every region into a y-down context whose user space is the art's own pixel space.
    func draw(in c: CGContext) {
        c.saveGState()
        for r in regions {
            c.addPath(r.path)
            c.setFillColor(r.color.cg)
            c.fillPath(using: .winding)
        }
        c.restoreGState()
    }

    /// For saving inside .sooth files (property-list types only); round-trips exactly enough to redraw identically.
    /// Points are stored as 32-bit floats, which is how the tracer makes them, so traced art comes back equal.
    var plist: [String: Any] {
        ["width": Double(size.width), "height": Double(size.height),
         "regions": regions.map { r -> [String: Any] in
             let (ops, points) = VectorArt.encode(r.path)
             return ["color": r.color.hex, "ops": ops, "points": points]
         }]
    }

    init?(plist: [String: Any]) {
        guard let w = (plist["width"] as? NSNumber)?.doubleValue, let h = (plist["height"] as? NSNumber)?.doubleValue,
              let list = plist["regions"] as? [[String: Any]] else { return nil }
        var regions: [Region] = []
        for r in list {
            guard let hex = r["color"] as? String, let color = RGBA(hex: hex),
                  let ops = r["ops"] as? Data, let points = r["points"] as? Data,
                  let path = VectorArt.decode(ops: ops, points: points) else { return nil }
            regions.append(Region(path: path, color: color))
        }
        self.init(size: CGSize(width: w, height: h), regions: regions)
    }

    /// A standalone SVG document (viewBox = 0 0 size), one <path> per region with fill colour and fill-opacity.
    func svg() -> String {
        var out: [UInt8] = []
        func put(_ s: String) { out.append(contentsOf: s.utf8) }
        func num(_ v: CGFloat) { VectorArt.appendNumber(Double(v), &out) }
        put("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"")
        num(size.width); put("\" height=\""); num(size.height)
        put("\" viewBox=\"0 0 "); num(size.width); put(" "); num(size.height); put("\">\n")
        for r in regions {
            put("<path fill=\"#" + r.color.hex.prefix(6) + "\"")
            if r.color.a < 255 { put(" fill-opacity=\"" + String(format: "%.3f", Double(r.color.a) / 255) + "\"") }
            put(" d=\"")
            r.path.applyWithBlock { e in
                let el = e.pointee
                func pts(_ letter: String, _ count: Int) {
                    put(letter)
                    for i in 0..<count {
                        if i > 0 { put(" ") }
                        num(el.points[i].x); put(" "); num(el.points[i].y)
                    }
                }
                switch el.type {
                case .moveToPoint: pts("M", 1)
                case .addLineToPoint: pts("L", 1)
                case .addQuadCurveToPoint: pts("Q", 2)
                case .addCurveToPoint: pts("C", 3)
                case .closeSubpath: put("Z")
                @unknown default: break
                }
            }
            put("\"/>\n")
        }
        put("</svg>\n")
        return String(decoding: out, as: UTF8.self)
    }

    /// Two decimals, no trailing zeros: plenty for pixel-space coordinates.
    private static func appendNumber(_ v: Double, _ out: inout [UInt8]) {
        var n = Int((v * 100).rounded())
        if n < 0 { out.append(45); n = -n }
        let whole = n / 100, frac = n % 100
        out.append(contentsOf: String(whole).utf8)
        if frac != 0 {
            out.append(46); out.append(48 + UInt8(frac / 10))
            if frac % 10 != 0 { out.append(48 + UInt8(frac % 10)) }
        }
    }

    /// Path elements as op bytes (0 move, 1 line, 2 quad, 3 cubic, 4 close) and Float32 x,y pairs.
    private static func encode(_ path: CGPath) -> (Data, Data) {
        var ops: [UInt8] = [], pts: [Float32] = []
        path.applyWithBlock { e in
            let el = e.pointee
            func add(_ op: UInt8, _ count: Int) {
                ops.append(op)
                for i in 0..<count { pts.append(Float32(el.points[i].x)); pts.append(Float32(el.points[i].y)) }
            }
            switch el.type {
            case .moveToPoint: add(0, 1)
            case .addLineToPoint: add(1, 1)
            case .addQuadCurveToPoint: add(2, 2)
            case .addCurveToPoint: add(3, 3)
            case .closeSubpath: add(4, 0)
            @unknown default: break
            }
        }
        return (Data(ops), pts.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    private static func decode(ops: Data, points: Data) -> CGPath? {
        var f = [Float32](repeating: 0, count: points.count / 4)
        _ = f.withUnsafeMutableBytes { points.copyBytes(to: $0) }
        let path = CGMutablePath()
        var i = 0
        func p() -> CGPoint { defer { i += 2 }; return CGPoint(x: CGFloat(f[i]), y: CGFloat(f[i + 1])) }
        for op in ops {
            let need = [2, 2, 4, 6, 0][Int(min(op, 4))]
            guard op <= 4, i + need <= f.count else { return nil }
            switch op {
            case 0: path.move(to: p())
            case 1: path.addLine(to: p())
            case 2: let c = p(); path.addQuadCurve(to: p(), control: c)
            case 3: let c1 = p(), c2 = p(); path.addCurve(to: p(), control1: c1, control2: c2)
            default: path.closeSubpath()
            }
        }
        return path.copy()
    }
}

// MARK: - Tracer

/// Bitmap-to-vector tracing: colour quantization, despeckling, pixel-edge outlines, then
/// Potrace-style optimal polygons and corner-aware Bézier smoothing (after Selinger, 2003).
enum Vectorizer {
    struct Options: Equatable {
        var colors: Int = 8          // palette size, 2…24
        var smoothness: Double = 1   // 0 = keep pixel-ish corners, 1 = smooth curves, up to 2 = very smooth
        var detail: Double = 0.5     // 0…1: higher keeps smaller specks/regions (despeckle threshold)
    }

    /// Bigger images are traced at a reduced scale (the paths are scaled back up).
    static let maxTracePixels = 8_000_000

    /// Trace an image (transparent pixels, alpha < 128, are left empty). Runs off the main thread safely.
    static func trace(_ image: CGImage, options: Options = Options()) -> VectorArt {
        let size = CGSize(width: image.width, height: image.height)
        guard image.width > 0, image.height > 0 else { return VectorArt(size: size, regions: []) }
        let k = min(24, max(2, options.colors))
        let smooth = min(2, max(0, options.smoothness.isFinite ? options.smoothness : 1))
        let detail = min(1, max(0, options.detail.isFinite ? options.detail : 0.5))

        // 1. Working pixels, un-premultiplied, scaled down when huge.
        let f = min(1, (Double(maxTracePixels) / (Double(image.width) * Double(image.height))).squareRoot())
        let w = max(1, Int((Double(image.width) * f).rounded())), h = max(1, Int((Double(image.height) * f).rounded()))
        let n = w * h
        let px = UnsafeMutablePointer<UInt8>.allocate(capacity: n * 4)
        defer { px.deallocate() }
        px.initialize(repeating: 0, count: n * 4)
        if let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        parallelRows(h) { y in
            var p = px + y * w * 4
            for _ in 0..<w {
                let a = Int(p[3])
                if a > 0 && a < 255 {
                    for c in 0..<3 { p[c] = UInt8(min(255, (Int(p[c]) * 255 + a / 2) / a)) }
                }
                p += 4
            }
        }

        // 2. Palette (OKLab), then every opaque pixel to its nearest colour; 255 = empty.
        let pal = palette(px, w: w, h: h, k: k)
        guard !pal.isEmpty else { return VectorArt(size: size, regions: []) }
        let labels = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        defer { labels.deallocate() }
        parallelRows(h) { y in
            for x in 0..<w {
                let i = y * w + x
                labels[i] = px[i * 4 + 3] < 128 ? 255 : UInt8(nearest(lab(px, i), pal))
            }
        }

        // 3. Despeckle: small patches join their most similar neighbour.
        let minArea = Int((1 - detail) * (1 - detail) * 0.00012 * Double(n)) + (detail < 1 ? max(2, Int(3 * f * f)) : 0)
        if minArea > 1 { despeckle(labels, w: w, h: h, minArea: minArea, palette: pal) }

        // 4. Colours with their area and mean alpha; biggest painted first (at the bottom).
        var area = [Int](repeating: 0, count: pal.count), alphaSum = [Int](repeating: 0, count: pal.count)
        for i in 0..<n where labels[i] != 255 {
            area[Int(labels[i])] += 1; alphaSum[Int(labels[i])] += Int(px[i * 4 + 3])
        }
        let order = pal.indices.filter { area[$0] > 0 }.sorted { area[$0] != area[$1] ? area[$0] > area[$1] : $0 < $1 }
        let colors: [RGBA] = order.map { j in
            let a = alphaSum[j] / area[j]
            var c = srgb(pal[j]); c.a = a >= 230 ? 255 : UInt8(a)
            return c
        }
        var rankOf = [UInt8](repeating: 255, count: 256)
        for (r, j) in order.enumerated() { rankOf[j] = UInt8(r) }
        let rank = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        defer { rank.deallocate() }
        for i in 0..<n { rank[i] = rankOf[Int(labels[i])] }

        // 5. Trace each colour, reaching a little under the opaque colours painted above it so
        // antialiased edges never let the background through, but never under colours below it.
        // The bottom colour reaches under everything opaque, so nothing can ever show through.
        let alphaMax = smooth <= 1 ? smooth : 1 + (smooth - 1) * 0.2   // big corners stay sharp even at 2
        let sx = Double(image.width) / Double(w), sy = Double(image.height) / Double(h)
        var paths = [CGPath?](repeating: nil, count: order.count)
        paths.withUnsafeMutableBufferPointer { out in
            let out = out
            DispatchQueue.concurrentPerform(iterations: order.count) { layer in
                var under = [Bool](repeating: false, count: 256)
                for r in layer + 1..<order.count where colors[r].a == 255 { under[r] = true }
                out[layer] = traceLayer(rank, w: w, h: h, layer: UInt8(layer), under: under, alphaMax: alphaMax,
                                        pixelExact: smooth <= 0.1, sx: sx, sy: sy)
            }
        }
        var regions: [VectorArt.Region] = []
        for (r, p) in paths.enumerated() { if let p { regions.append(.init(path: p, color: colors[r])) } }
        return VectorArt(size: size, regions: regions)
    }

    // MARK: Colour

    private static let linear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// OKLab of an un-premultiplied pixel.
    @inline(__always) private static func lab(_ px: UnsafePointer<UInt8>, _ i: Int) -> SIMD3<Float> {
        linear.withUnsafeBufferPointer { t in
            let r = t[Int(px[i * 4])], g = t[Int(px[i * 4 + 1])], b = t[Int(px[i * 4 + 2])]
            let l = cbrtf(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrtf(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrtf(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                         1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                         0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
    }

    private static func srgb(_ c: SIMD3<Float>) -> RGBA {
        let l = c.x + 0.3963377774 * c.y + 0.2158037573 * c.z
        let m = c.x - 0.1055613458 * c.y - 0.0638541728 * c.z
        let s = c.x - 0.0894841775 * c.y - 1.2914855480 * c.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        func enc(_ v: Float) -> UInt8 {
            let v = max(0, min(1, v))
            return clamp8(Double(v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055) * 255)
        }
        return RGBA(r: enc(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                    g: enc(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                    b: enc(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }

    @inline(__always) private static func dist2(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b; return (d * d).sum()
    }

    @inline(__always) private static func nearest(_ c: SIMD3<Float>, _ pal: [SIMD3<Float>]) -> Int {
        var best = 0, bd = Float.infinity
        for (j, p) in pal.enumerated() { let d = dist2(c, p); if d < bd { bd = d; best = j } }
        return best
    }

    /// Up to `k` colours: median cut then k-means over a fixed grid of samples. Samples that are
    /// blends between neighbours (antialiasing, fringes) are left out when enough others remain,
    /// so in-between edge shades don't take palette slots. Near-duplicates are merged.
    private static func palette(_ px: UnsafePointer<UInt8>, w: Int, h: Int, k: Int) -> [SIMD3<Float>] {
        let step = max(1, Int((Double(w * h) / 90_000).squareRoot()))
        var all: [SIMD3<Float>] = [], flat: [SIMD3<Float>] = []
        var y = step / 2
        while y < h {
            var x = step / 2
            while x < w {
                let i = y * w + x
                if px[i * 4 + 3] >= 128 {
                    let c = lab(px, i)
                    // A blend: next to empty pixels, or lying between two clearly different
                    // opposite neighbours (texture, unlike antialiasing, rarely does).
                    var blend = false
                    for (dx, dy) in [(1, 0), (0, 1)] where !blend {
                        let ax = x - dx, ay = y - dy, bx = x + dx, by = y + dy
                        guard ax >= 0, ay >= 0, bx < w, by < h else { continue }
                        let ia = ay * w + ax, ib = by * w + bx
                        if px[ia * 4 + 3] < 128 || px[ib * 4 + 3] < 128 { blend = true; break }
                        let a = lab(px, ia), b = lab(px, ib), ab = b - a, len2 = (ab * ab).sum()
                        guard len2 > 0.0064 else { continue }
                        let t = ((c - a) * ab).sum() / len2
                        blend = t > 0.15 && t < 0.85 && dist2(c, a + t * ab) < 0.04 * len2
                    }
                    all.append(c)
                    if !blend { flat.append(c) }
                }
                x += step
            }
            y += step
        }
        guard !all.isEmpty else { return [] }
        let train = flat.count >= max(32, all.count / 5) ? flat : all

        func mean(_ s: ArraySlice<SIMD3<Float>>) -> SIMD3<Float> { s.reduce(.zero, +) / Float(s.count) }
        func spread(_ s: ArraySlice<SIMD3<Float>>) -> SIMD3<Float> {
            let m = mean(s); return s.reduce(.zero) { $0 + ($1 - m) * ($1 - m) }
        }
        var boxes: [ArraySlice<SIMD3<Float>>] = [train[...]]
        var sse = [spread(train[...])]
        while boxes.count < k {
            guard let b = sse.indices.filter({ boxes[$0].count >= 2 && sse[$0].sum() > 1e-6 }).max(by: { sse[$0].sum() < sse[$1].sum() }) else { break }
            let v = sse[b], axis = v.x >= v.y && v.x >= v.z ? 0 : (v.y >= v.z ? 1 : 2)
            let sorted = boxes[b].sorted { $0[axis] < $1[axis] }
            let lo = Array(sorted[..<(sorted.count / 2)]), hi = Array(sorted[(sorted.count / 2)...])
            boxes[b] = lo[...]; sse[b] = spread(lo[...])
            boxes.append(hi[...]); sse.append(spread(hi[...]))
        }
        var centers = boxes.map(mean)
        var count = [Int](repeating: 0, count: centers.count)
        for iteration in 0..<10 {
            var sum = [SIMD3<Float>](repeating: .zero, count: centers.count)
            count = [Int](repeating: 0, count: centers.count)
            for c in train { let j = nearest(c, centers); sum[j] += c; count[j] += 1 }
            var moved = false
            for j in centers.indices where count[j] > 0 {
                let c = sum[j] / Float(count[j])
                if dist2(c, centers[j]) > 1e-9 { moved = true }
                centers[j] = c
            }
            if !moved || iteration == 9 { break }
        }
        // Small clusters that sit between two bigger ones are leftover edge blends: drop them.
        let total = count.reduce(0, +)
        for j in centers.indices where count[j] > 0 && count[j] * 100 < total {
            var between = false
            for a in centers.indices where a != j && count[a] > count[j] && !between {
                for b in centers.indices where b > a && b != j && count[b] > count[j] {
                    let ab = centers[b] - centers[a], len2 = (ab * ab).sum()
                    guard len2 > 0.0064 else { continue }
                    let t = ((centers[j] - centers[a]) * ab).sum() / len2
                    if t > 0.08 && t < 0.92 && dist2(centers[j], centers[a] + t * ab) < 0.02 * len2 { between = true; break }
                }
            }
            if between { count[j] = 0 }
        }
        var kept: [(c: SIMD3<Float>, n: Int)] = []
        for j in centers.indices.sorted(by: { count[$0] > count[$1] }) where count[j] > 0 {
            if let m = kept.firstIndex(where: { dist2($0.c, centers[j]) < 0.0004 }) {
                let t = kept[m].n + count[j]
                kept[m].c = (kept[m].c * Float(kept[m].n) + centers[j] * Float(count[j])) / Float(t)
                kept[m].n = t
            } else {
                kept.append((centers[j], count[j]))
            }
        }
        return kept.map(\.c)
    }

    // MARK: Despeckle

    /// Merge 4-connected patches smaller than `minArea` (empty ones included), and thin slivers up
    /// to eight times that (edge fringes: no pixel with all four neighbours inside), into the
    /// neighbour with the closest colour, smallest patches first.
    private static func despeckle(_ labels: UnsafeMutablePointer<UInt8>, w: Int, h: Int, minArea: Int, palette: [SIMD3<Float>]) {
        let n = w * h
        let comp = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        defer { comp.deallocate() }
        comp.initialize(repeating: -1, count: n)
        var compLabel: [UInt8] = [], compSize: [Int] = []
        var stack: [Int32] = []
        for s in 0..<n where comp[s] < 0 {
            let id = Int32(compLabel.count), l = labels[s]
            comp[s] = id; stack.append(Int32(s))
            var size = 0
            while let q = stack.popLast() {
                size += 1
                let p = Int(q), x = p % w
                if x > 0, comp[p - 1] < 0, labels[p - 1] == l { comp[p - 1] = id; stack.append(Int32(p - 1)) }
                if x < w - 1, comp[p + 1] < 0, labels[p + 1] == l { comp[p + 1] = id; stack.append(Int32(p + 1)) }
                if p >= w, comp[p - w] < 0, labels[p - w] == l { comp[p - w] = id; stack.append(Int32(p - w)) }
                if p + w < n, comp[p + w] < 0, labels[p + w] == l { comp[p + w] = id; stack.append(Int32(p + w)) }
            }
            compLabel.append(l); compSize.append(size)
        }
        let limit = minArea * 8
        let small = compSize.indices.filter { compSize[$0] < limit }
        guard !small.isEmpty else { return }

        // Pixel lists of the small patches.
        var slot = [Int32](repeating: -1, count: compSize.count)
        var start = [Int](repeating: 0, count: small.count + 1)
        for (s, c) in small.enumerated() { slot[c] = Int32(s); start[s + 1] = start[s] + compSize[c] }
        var fill = start, pixels = [Int32](repeating: 0, count: start[small.count])
        for p in 0..<n {
            let s = slot[Int(comp[p])]
            if s >= 0 { pixels[fill[Int(s)]] = Int32(p); fill[Int(s)] += 1 }
        }

        var parent = Array(0..<Int32(compSize.count)), size = compSize
        func find(_ c: Int32) -> Int32 {
            var c = c
            while parent[Int(c)] != c { parent[Int(c)] = parent[Int(parent[Int(c)])]; c = parent[Int(c)] }
            return c
        }
        func distance(_ a: UInt8, _ b: UInt8) -> Float {
            a == 255 || b == 255 ? 1e6 : dist2(palette[Int(a)], palette[Int(b)])
        }
        var nb: [Int32] = [], border: [Int] = []
        for (s, c) in small.enumerated().sorted(by: { compSize[$0.1] != compSize[$1.1] ? compSize[$0.1] < compSize[$1.1] : $0.1 < $1.1 }) {
            let c32 = Int32(c)
            guard parent[c] == c32, size[c] < limit else { continue }
            if size[c] >= minArea {
                var thin = true
                for t in start[s]..<start[s + 1] where thin {
                    let p = Int(pixels[t]), x = p % w
                    thin = !(x > 0 && x < w - 1 && p >= w && p + w < n &&
                             comp[p - 1] == c32 && comp[p + 1] == c32 && comp[p - w] == c32 && comp[p + w] == c32)
                }
                if !thin { continue }
            }
            nb.removeAll(keepingCapacity: true); border.removeAll(keepingCapacity: true)
            for t in start[s]..<start[s + 1] {
                let p = Int(pixels[t]), x = p % w
                for q in [x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, p - w, p + w] where q >= 0 && q < n {
                    let r = find(comp[q])
                    if r == c32 { continue }
                    if let e = nb.firstIndex(of: r) { border[e] += 1 } else { nb.append(r); border.append(1) }
                }
            }
            guard !nb.isEmpty else { continue }
            var best = 0
            for e in 1..<nb.count {
                let d = distance(compLabel[c], compLabel[Int(nb[e])]), bd = distance(compLabel[c], compLabel[Int(nb[best])])
                if d < bd || (d == bd && border[e] > border[best]) { best = e }
            }
            parent[c] = nb[best]; size[Int(nb[best])] += size[c]
        }
        for p in 0..<n { labels[p] = compLabel[Int(find(comp[p]))] }
    }

    // MARK: Outlines

    /// All outlines of one stacked layer as one path, or nil if it is empty.
    /// All outlines of one colour as one path, or nil if it is empty. The shape is the colour's
    /// own pixels plus those of `under` colours within a few pixels of them (the overlap that
    /// hides seams; smoothed curves stray from the pixel edges, so one pixel would not be enough),
    /// or all of them for the bottom colour.
    private static func traceLayer(_ rank: UnsafePointer<UInt8>, w: Int, h: Int, layer: UInt8, under: [Bool], alphaMax: Double,
                                   pixelExact: Bool, sx: Double, sy: Double) -> CGPath? {
        let reach = pixelExact ? 1 : (alphaMax > 1 ? 3 : 2), everything = layer == 0
        // Rows dilated sideways: true where a matching pixel lies within `reach` along the row.
        func widen(_ match: (UInt8) -> Bool) -> (rows: [Bool], any: Bool) {
            var rows = [Bool](repeating: false, count: w * h), any = false
            for y in 0..<h {
                let row = y * w
                var last = -reach - 1
                for x in 0..<(w + reach) {
                    if x < w && match(rank[row + x]) { last = x; any = true }
                    let t = x - reach
                    if t >= 0 && x - last <= 2 * reach { rows[row + t] = true }
                }
            }
            return (rows, any)
        }
        func near(_ rows: [Bool], _ x: Int, _ y: Int) -> Bool {
            for yy in max(0, y - reach)...min(h - 1, y + reach) where rows[yy * w + x] { return true }
            return false
        }
        let own = widen { $0 == layer }
        guard own.any else { return nil }
        // The bottom colour fills under everything, except along empty areas, where it keeps to
        // its own edges so it can't fringe other colours' outlines.
        let clear = everything ? widen { $0 == 255 } : (rows: [], any: false)
        // Two cells of padding: the inner ring repeats the edge pixels, so colours that touch the
        // border run a pixel past it and their curves can't pull away from it; the outer ring stays empty.
        let pw = w + 4
        var mask = [Bool](repeating: false, count: pw * (h + 4))
        for y in 0..<h {
            for x in 0..<w {
                let r = rank[y * w + x]
                guard r == layer || under[Int(r)] else { continue }
                var hit = r == layer || near(own.rows, x, y)
                if !hit && everything { hit = !clear.any || !near(clear.rows, x, y) }
                if hit { mask[(y + 2) * pw + x + 2] = true }
            }
        }
        for y in 1..<(h + 3) {
            mask[y * pw + 1] = mask[min(h + 1, max(2, y)) * pw + 2]
            mask[y * pw + w + 2] = mask[min(h + 1, max(2, y)) * pw + w + 1]
        }
        for x in 1..<(w + 3) {
            mask[pw + x] = mask[2 * pw + x]
            mask[(h + 2) * pw + x] = mask[(h + 1) * pw + x]
        }
        let sw = w + 2
        var seen = [Bool](repeating: false, count: sw * (h + 2))
        let path = CGMutablePath()
        var xs: [Int] = [], ys: [Int] = []
        mask.withUnsafeBufferPointer { m in
            @inline(__always) func at(_ x: Int, _ y: Int) -> Bool { m[(y + 2) * pw + x + 2] }
            for y in -1...h {
                for x in -1...w where at(x, y) && !at(x, y - 1) && !seen[(y + 1) * sw + x + 1] {
                    // Walk the pixel edges with the inside on the right; diagonal touches connect.
                    xs.removeAll(keepingCapacity: true); ys.removeAll(keepingCapacity: true)
                    var vx = x, vy = y, dx = 1, dy = 0
                    repeat {
                        xs.append(vx); ys.append(vy)
                        if dx == 1 { seen[(vy + 1) * sw + vx + 1] = true }
                        vx += dx; vy += dy
                        let rx = -dy, ry = dx
                        let aheadRight = at(vx + (dx + rx - 1) / 2, vy + (dy + ry - 1) / 2)
                        let aheadLeft = at(vx + (dx - rx - 1) / 2, vy + (dy - ry - 1) / 2)
                        if aheadLeft { (dx, dy) = (dy, -dx) }             // turn left
                        else if !aheadRight { (dx, dy) = (-dy, dx) }      // turn right
                    } while !(vx == x && vy == y && dx == 1)
                    if pixelExact { addPolygon(xs, ys, to: path, sx: sx, sy: sy) }
                    else { addSmoothed(xs, ys, alphaMax: alphaMax, to: path, sx: sx, sy: sy) }
                }
            }
        }
        return path.isEmpty ? nil : path.copy()
    }

    @inline(__always) private static func point(_ x: Double, _ y: Double, _ sx: Double, _ sy: Double) -> CGPoint {
        CGPoint(x: CGFloat(Float(x * sx)), y: CGFloat(Float(y * sy)))
    }

    /// The exact pixel outline, one vertex per change of direction.
    private static func addPolygon(_ X: [Int], _ Y: [Int], to path: CGMutablePath, sx: Double, sy: Double) {
        let n = X.count
        var first = true
        for i in 0..<n {
            let a = (i + n - 1) % n, b = (i + 1) % n
            if (X[i] - X[a]) * (Y[b] - Y[i]) == (Y[i] - Y[a]) * (X[b] - X[i]) { continue }
            let p = point(Double(X[i]), Double(Y[i]), sx, sy)
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        }
        if !first { path.closeSubpath() }
    }

    /// Potrace's stages for one closed lattice outline: longest straight runs, the optimal polygon,
    /// vertices nudged onto best-fit lines, then corners or Béziers chosen by `alphaMax`.
    private static func addSmoothed(_ X: [Int], _ Y: [Int], alphaMax: Double, to path: CGMutablePath, sx: Double, sy: Double) {
        let n = X.count
        guard n >= 8 else { addPolygon(X, Y, to: path, sx: sx, sy: sy); return }
        @inline(__always) func md(_ a: Int) -> Int { let r = a % n; return r < 0 ? r + n : r }
        @inline(__always) func cyclic(_ a: Int, _ b: Int, _ c: Int) -> Bool { a <= c ? (a <= b && b < c) : (a <= b || b < c) }
        @inline(__always) func sgn(_ v: Int) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }
        @inline(__always) func floordiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -1 - (-1 - a) / b }
        @inline(__always) func xprod(_ a: (Int, Int), _ b: (Int, Int)) -> Int { a.0 * b.1 - a.1 * b.0 }

        // Prefix sums of x, y, x², xy, y² relative to the first point.
        let x0 = X[0], y0 = Y[0]
        var sX = [Double](repeating: 0, count: n + 1), sY = sX, sXX = sX, sXY = sX, sYY = sX
        for i in 0..<n {
            let x = Double(X[i] - x0), y = Double(Y[i] - y0)
            sX[i + 1] = sX[i] + x; sY[i + 1] = sY[i] + y
            sXX[i + 1] = sXX[i] + x * x; sXY[i + 1] = sXY[i] + x * y; sYY[i + 1] = sYY[i] + y * y
        }

        // lon[i]: the furthest point a straight segment from i may reach.
        var nc = [Int](repeating: 0, count: n), pivk = nc, lon = nc
        var k = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            if X[i] != X[k] && Y[i] != Y[k] { k = i + 1 }
            nc[i] = k
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var ct = SIMD4<Int>(repeating: 0)
            let i1 = md(i + 1)
            ct[(3 + 3 * (X[i1] - X[i]) + (Y[i1] - Y[i])) / 2] += 1
            var c0 = (0, 0), c1 = (0, 0)
            var kk = nc[i], k1 = i, found = false
            while true {
                ct[(3 + 3 * sgn(X[kk] - X[k1]) + sgn(Y[kk] - Y[k1])) / 2] += 1
                if ct[0] > 0 && ct[1] > 0 && ct[2] > 0 && ct[3] > 0 { pivk[i] = k1; found = true; break }
                let cur = (X[kk] - X[i], Y[kk] - Y[i])
                if xprod(c0, cur) < 0 || xprod(c1, cur) > 0 { break }
                if abs(cur.0) > 1 || abs(cur.1) > 1 {
                    var off = (cur.0 + ((cur.1 >= 0 && (cur.1 > 0 || cur.0 < 0)) ? 1 : -1),
                               cur.1 + ((cur.0 <= 0 && (cur.0 < 0 || cur.1 < 0)) ? 1 : -1))
                    if xprod(c0, off) >= 0 { c0 = off }
                    off = (cur.0 + ((cur.1 <= 0 && (cur.1 < 0 || cur.0 < 0)) ? 1 : -1),
                           cur.1 + ((cur.0 >= 0 && (cur.0 > 0 || cur.1 < 0)) ? 1 : -1))
                    if xprod(c1, off) <= 0 { c1 = off }
                }
                k1 = kk; kk = nc[k1]
                if !cyclic(kk, i, k1) { break }
            }
            if found { continue }
            let dk = (sgn(X[kk] - X[k1]), sgn(Y[kk] - Y[k1]))
            let cur = (X[k1] - X[i], Y[k1] - Y[i])
            let a = xprod(c0, cur), b = xprod(c0, dk), c = xprod(c1, cur), d = xprod(c1, dk)
            var j = 10_000_000
            if b < 0 { j = floordiv(a, -b) }
            if d > 0 { j = min(j, floordiv(-c, d)) }
            pivk[i] = md(k1 + j)
        }
        var j = pivk[n - 1]
        lon[n - 1] = j
        for i in stride(from: n - 2, through: 0, by: -1) {
            if cyclic(i + 1, pivk[i], j) { j = pivk[i] }
            lon[i] = j
        }
        var t = n - 1
        while t >= 0 && cyclic(md(t + 1), j, lon[t]) { lon[t] = j; t -= 1 }

        // Optimal polygon: fewest segments, then least deviation.
        func penalty(_ i: Int, _ j: Int) -> Double {
            var j = j, r = 0.0
            if j >= n { j -= n; r = 1 }
            let x = sX[j + 1] - sX[i] + r * sX[n], y = sY[j + 1] - sY[i] + r * sY[n]
            let x2 = sXX[j + 1] - sXX[i] + r * sXX[n], xy = sXY[j + 1] - sXY[i] + r * sXY[n]
            let y2 = sYY[j + 1] - sYY[i] + r * sYY[n]
            let kk = Double(j + 1 - i) + r * Double(n)
            let px = Double(X[i] + X[j]) / 2 - Double(x0), py = Double(Y[i] + Y[j]) / 2 - Double(y0)
            let ey = Double(X[j] - X[i]), ex = -Double(Y[j] - Y[i])
            let a = (x2 - 2 * x * px) / kk + px * px, b = (xy - x * py - y * px) / kk + px * py
            let c = (y2 - 2 * y * py) / kk + py * py
            return max(0, ex * ex * a + 2 * ex * ey * b + ey * ey * c).squareRoot()
        }
        var clip0 = [Int](repeating: 0, count: n), clip1 = [Int](repeating: 0, count: n + 1)
        var seg0 = [Int](repeating: 0, count: n + 1), seg1 = seg0
        for i in 0..<n {
            var c = md(lon[md(i - 1)] - 1)
            if c == i { c = md(i + 1) }
            clip0[i] = c < i ? n : c
        }
        j = 1
        for i in 0..<n { while j <= clip0[i] { clip1[j] = i; j += 1 } }
        var i = 0, m = 0
        while i < n { seg0[m] = i; i = clip0[i]; m += 1 }
        seg0[m] = n
        i = n
        for s in stride(from: m, to: 0, by: -1) { seg1[s] = i; i = clip1[i] }
        seg1[0] = 0
        var pen = [Double](repeating: 0, count: n + 1), prev = [Int](repeating: 0, count: n + 1)
        for s in 1...m {
            for i in stride(from: seg1[s], through: seg0[s], by: 1) {
                var best = -1.0, kk = seg0[s - 1]
                while kk >= clip1[i] {
                    let p = penalty(kk, i) + pen[kk]
                    if best < 0 || p < best { prev[i] = kk; best = p }
                    kk -= 1
                }
                pen[i] = best
            }
        }
        guard m >= 3 else { addPolygon(X, Y, to: path, sx: sx, sy: sy); return }
        var po = [Int](repeating: 0, count: m)
        i = n; j = m - 1
        while i > 0 && j >= 0 { i = prev[i]; po[j] = i; j -= 1 }

        // Each side as a best-fit line (a quadratic form); vertices move to the point nearest both
        // neighbouring lines within their pixel square.
        var q = [[Double]](repeating: [Double](repeating: 0, count: 9), count: m)
        for s in 0..<m {
            var a = po[s], b = md(po[(s + 1) % m] - po[s]) + po[s], r = 0
            while b >= n { b -= n; r += 1 }
            while a >= n { a -= n; r -= 1 }
            let rr = Double(r)
            let x = sX[b + 1] - sX[a] + rr * sX[n], y = sY[b + 1] - sY[a] + rr * sY[n]
            let x2 = sXX[b + 1] - sXX[a] + rr * sXX[n], xy = sXY[b + 1] - sXY[a] + rr * sXY[n]
            let y2 = sYY[b + 1] - sYY[a] + rr * sYY[n]
            let kk = Double(b + 1 - a) + rr * Double(n)
            let cx = x / kk, cy = y / kk
            var e = (x2 - x * x / kk) / kk, f = (xy - x * y / kk) / kk, g = (y2 - y * y / kk) / kk
            let lambda = (e + g + ((e - g) * (e - g) + 4 * f * f).squareRoot()) / 2
            e -= lambda; g -= lambda
            var dirX = 0.0, dirY = 0.0
            if abs(e) >= abs(g) {
                let l = (e * e + f * f).squareRoot()
                if l != 0 { dirX = -f / l; dirY = e / l }
            } else {
                let l = (g * g + f * f).squareRoot()
                if l != 0 { dirX = -g / l; dirY = f / l }
            }
            let d = dirX * dirX + dirY * dirY
            if d != 0 {
                let v = [dirY, -dirX, dirX * cy - dirY * cx]
                for u in 0..<3 { for w in 0..<3 { q[s][u * 3 + w] = v[u] * v[w] / d } }
            }
        }
        func form(_ Q: [Double], _ x: Double, _ y: Double) -> Double {
            let v = [x, y, 1.0]
            var s = 0.0
            for u in 0..<3 { for w in 0..<3 { s += v[u] * Q[u * 3 + w] * v[w] } }
            return s
        }
        var vx = [Double](repeating: 0, count: m), vy = vx
        for s in 0..<m {
            let px = Double(X[po[s]] - x0), py = Double(Y[po[s]] - y0)
            var Q = (0..<9).map { q[(s + m - 1) % m][$0] + q[s][$0] }
            var wx = px, wy = py
            while true {
                let det = Q[0] * Q[4] - Q[1] * Q[3]
                if det != 0 {
                    wx = (-Q[2] * Q[4] + Q[5] * Q[1]) / det
                    wy = (Q[2] * Q[3] - Q[5] * Q[0]) / det
                    break
                }
                // Parallel lines: add an orthogonal one through the vertex.
                var v0 = 1.0, v1 = 0.0
                if Q[0] > Q[4] { v0 = -Q[1]; v1 = Q[0] } else if Q[4] != 0 { v0 = -Q[4]; v1 = Q[3] }
                let d = v0 * v0 + v1 * v1, v = [v0, v1, -v1 * py - v0 * px]
                for u in 0..<3 { for w in 0..<3 { Q[u * 3 + w] += v[u] * v[w] / d } }
            }
            if abs(wx - px) <= 0.5 && abs(wy - py) <= 0.5 { vx[s] = wx + Double(x0); vy[s] = wy + Double(y0); continue }
            var best = form(Q, px, py), bx = px, by = py
            if Q[0] != 0 {
                for z in 0..<2 {
                    let yy = py - 0.5 + Double(z), xx = -(Q[1] * yy + Q[2]) / Q[0]
                    let c = form(Q, xx, yy)
                    if abs(xx - px) <= 0.5 && c < best { best = c; bx = xx; by = yy }
                }
            }
            if Q[4] != 0 {
                for z in 0..<2 {
                    let xx = px - 0.5 + Double(z), yy = -(Q[3] * xx + Q[5]) / Q[4]
                    let c = form(Q, xx, yy)
                    if abs(yy - py) <= 0.5 && c < best { best = c; bx = xx; by = yy }
                }
            }
            for l in 0..<2 {
                for z in 0..<2 {
                    let xx = px - 0.5 + Double(l), yy = py - 0.5 + Double(z), c = form(Q, xx, yy)
                    if c < best { best = c; bx = xx; by = yy }
                }
            }
            vx[s] = bx + Double(x0); vy[s] = by + Double(y0)
        }

        // A sharp corner the polygon split in two (a short side between two much longer ones)
        // becomes one vertex where the long sides meet, so it can stay sharp.
        if m > 4 {
            var gone = [Bool](repeating: false, count: m), alive = m
            var next = (0..<m).map { ($0 + 1) % m }, prev = (0..<m).map { ($0 + m - 1) % m }
            for s in 0..<m where !gone[s] && alive > 4 {
                let p = prev[s], t = next[s], q = next[t]
                let short = hypot(vx[t] - vx[s], vy[t] - vy[s])
                let ax = vx[s] - vx[p], ay = vy[s] - vy[p], bx = vx[q] - vx[t], by = vy[q] - vy[t]
                let la = hypot(ax, ay), lb = hypot(bx, by), cross = ax * by - ay * bx
                guard short < 3, la > 3 * short, lb > 3 * short, abs(cross) > 1e-9 else { continue }
                guard (ax * bx + ay * by) / (la * lb) < 0.64 else { continue }  // turns more than 50°
                let u = ((vx[t] - vx[s]) * by - (vy[t] - vy[s]) * bx) / cross
                let ix = vx[s] + u * ax, iy = vy[s] + u * ay, reach = 1.5 * short + 0.5
                guard hypot(ix - vx[s], iy - vy[s]) < reach, hypot(ix - vx[t], iy - vy[t]) < reach else { continue }
                vx[s] = ix; vy[s] = iy; gone[t] = true; alive -= 1
                next[s] = q; prev[q] = s
            }
            if gone.contains(true) {
                vx = vx.indices.filter { !gone[$0] }.map { vx[$0] }
                vy = vy.indices.filter { !gone[$0] }.map { vy[$0] }
                m = vx.count
            }
        }

        // Smooth: each corner of the polygon becomes a sharp corner or a curve through the
        // midpoints of its two sides, judged by how far the vertex juts out.
        let v = (0..<m).map { V2(vx[$0], vy[$0]) }
        var segs: [Seg] = []
        segs.reserveCapacity(m)
        for s in 0..<m {
            let a = v[(s + m - 1) % m], b = v[s], c = v[(s + 1) % m]
            let denom = abs(c.x - a.x) + abs(c.y - a.y)
            var alpha = 4.0 / 3
            if denom != 0 {
                let dd = abs(dpara(a, b, c)) / denom
                alpha = (dd > 1 ? 1 - 1 / dd : 0) / 0.75
            }
            if alpha >= alphaMax {
                segs.append(Seg(corner: true, c0: b, c1: b, end: (b + c) / 2, alpha: alpha))
            } else {
                let al = min(1, max(0.55, alpha)), t = 0.5 + 0.5 * al
                segs.append(Seg(corner: false, c0: a + t * (b - a), c1: c + t * (b - c), end: (b + c) / 2, alpha: al))
            }
        }
        segs = optimize(segs, v)
        func P(_ p: V2) -> CGPoint { point(p.x, p.y, sx, sy) }
        path.move(to: P(segs[segs.count - 1].end))
        for g in segs {
            if g.corner { path.addLine(to: P(g.c1)); path.addLine(to: P(g.end)) }
            else { path.addCurve(to: P(g.end), control1: P(g.c0), control2: P(g.c1)) }
        }
        path.closeSubpath()
    }

    // MARK: Curve optimization

    private typealias V2 = SIMD2<Double>

    /// One piece of a smoothed outline: a sharp corner (lines through `c1` to `end`) or a cubic.
    private struct Seg { var corner: Bool; var c0: V2; var c1: V2; var end: V2; var alpha: Double }

    @inline(__always) private static func cross(_ a: V2, _ b: V2) -> Double { a.x * b.y - a.y * b.x }
    @inline(__always) private static func dpara(_ p0: V2, _ p1: V2, _ p2: V2) -> Double { cross(p1 - p0, p2 - p0) }
    @inline(__always) private static func dist(_ a: V2, _ b: V2) -> Double { ((a - b) * (a - b)).sum().squareRoot() }

    private static func bezier(_ t: Double, _ p0: V2, _ p1: V2, _ p2: V2, _ p3: V2) -> V2 {
        let s = 1 - t
        return s * s * s * p0 + 3 * (s * s * t) * p1 + 3 * (t * t * s) * p2 + t * t * t * p3
    }

    /// Where on the cubic the tangent is parallel to q0→q1, or -1.
    private static func tangent(_ p0: V2, _ p1: V2, _ p2: V2, _ p3: V2, _ q0: V2, _ q1: V2) -> Double {
        let q = q1 - q0
        let A = cross(p1 - p0, q), B = cross(p2 - p1, q), C = cross(p3 - p2, q)
        let a = A - 2 * B + C, b = -2 * A + 2 * B, c = A
        let d = b * b - 4 * a * c
        guard a != 0, d >= 0 else { return -1 }
        let s = d.squareRoot(), r1 = (-b + s) / (2 * a), r2 = (-b - s) / (2 * a)
        if r1 >= 0 && r1 <= 1 { return r1 }
        if r2 >= 0 && r2 <= 1 { return r2 }
        return -1
    }

    /// Potrace's curve optimization: runs of gentle same-direction curves are joined into single
    /// cubics where that stays within a fifth of a pixel, which evens out the bumps between them.
    private static func optimize(_ segs: [Seg], _ v: [V2]) -> [Seg] {
        let m = segs.count, tolerance = 0.2, cos179 = -0.99984769515639
        guard m >= 3 else { return segs }
        var conv = [Int](repeating: 0, count: m)
        for i in 0..<m where !segs[i].corner {
            let d = dpara(v[(i + m - 1) % m], v[i], v[(i + 1) % m])
            conv[i] = d > 0 ? 1 : (d < 0 ? -1 : 0)
        }
        var areac = [Double](repeating: 0, count: m + 1), area = 0.0
        for i in 0..<m {
            let i1 = (i + 1) % m
            if !segs[i1].corner {
                let al = segs[i1].alpha
                area += 0.3 * al * (4 - al) * dpara(segs[i].end, v[i1], segs[i1].end) / 2
                area += dpara(v[0], segs[i].end, segs[i1].end) / 2
            }
            areac[i + 1] = area
        }

        /// The single cubic from the end of segment i to the end of segment j, with its penalty.
        func join(_ i: Int, _ j: Int) -> (pen: Double, c0: V2, c1: V2, alpha: Double)? {
            guard i != j else { return nil }
            let i1 = (i + 1) % m, cv = conv[i1]
            guard cv != 0 else { return nil }
            let d = dist(v[i], v[i1])
            var k = i1
            while k != j {
                let k1 = (k + 1) % m, k2 = (k + 2) % m
                if conv[k1] != cv { return nil }
                let c = cross(v[i1] - v[i], v[k2] - v[k1])
                if (c > 0 ? 1 : (c < 0 ? -1 : 0)) != cv { return nil }
                let dot = ((v[i1] - v[i]) * (v[k2] - v[k1])).sum()
                if dot < d * dist(v[k1], v[k2]) * cos179 { return nil }
                k = k1
            }
            let p0 = segs[i].end, p1 = v[i1], p2 = v[j], p3 = segs[j].end
            var area = areac[j] - areac[i] - dpara(v[0], segs[i].end, segs[j].end) / 2
            if i >= j { area += areac[m] }
            let A1 = dpara(p0, p1, p2), A2 = dpara(p0, p1, p3), A3 = dpara(p0, p2, p3), A4 = A1 + A3 - A2
            guard A2 != A1, A3 != A4 else { return nil }
            let t = A3 / (A3 - A4), s = A2 / (A2 - A1), A = A2 * t / 2
            guard A != 0 else { return nil }
            let alpha = 2 - (4 - area / A / 0.3).squareRoot()
            guard alpha.isFinite else { return nil }
            let c0 = p0 + t * alpha * (p1 - p0), c1 = p3 + s * alpha * (p2 - p3)
            var pen = 0.0
            k = i1
            while k != j {
                let k1 = (k + 1) % m
                let tt = tangent(p0, c0, c1, p3, v[k], v[k1])
                if tt < -0.5 { return nil }
                let pt = bezier(tt, p0, c0, c1, p3), dk = dist(v[k], v[k1])
                if dk == 0 { return nil }
                let d1 = dpara(v[k], v[k1], pt) / dk
                if abs(d1) > tolerance { return nil }
                if ((v[k1] - v[k]) * (pt - v[k])).sum() < 0 || ((v[k] - v[k1]) * (pt - v[k1])).sum() < 0 { return nil }
                pen += d1 * d1
                k = k1
            }
            k = i
            while k != j {
                let k1 = (k + 1) % m
                let a = segs[k].end, b = segs[k1].end
                let tt = tangent(p0, c0, c1, p3, a, b)
                if tt < -0.5 { return nil }
                let pt = bezier(tt, p0, c0, c1, p3), dk = dist(a, b)
                if dk == 0 { return nil }
                var d1 = dpara(a, b, pt) / dk, d2 = dpara(a, b, v[k1]) / dk * 0.75 * segs[k1].alpha
                if d2 < 0 { d1 = -d1; d2 = -d2 }
                if d1 < d2 - tolerance { return nil }
                if d1 < d2 { pen += (d1 - d2) * (d1 - d2) }
                k = k1
            }
            return (pen, c0, c1, alpha)
        }

        var back = [Int](repeating: -1, count: m + 1), pen = [Double](repeating: 0, count: m + 1)
        var len = [Int](repeating: 0, count: m + 1)
        var best = [(c0: V2, c1: V2, alpha: Double)?](repeating: nil, count: m + 1)
        for j in 1...m {
            back[j] = j - 1; pen[j] = pen[j - 1]; len[j] = len[j - 1] + 1
            var i = j - 2
            while i >= 0, let o = join(i, j % m) {
                if len[j] > len[i] + 1 || (len[j] == len[i] + 1 && pen[j] > pen[i] + o.pen) {
                    back[j] = i; pen[j] = pen[i] + o.pen; len[j] = len[i] + 1; best[j] = (o.c0, o.c1, o.alpha)
                }
                i -= 1
            }
        }
        var out: [Seg] = []
        out.reserveCapacity(len[m])
        var j = m
        while j > 0 {
            if back[j] == j - 1 || best[j] == nil { out.append(segs[j % m]) }
            else { let o = best[j]!; out.append(Seg(corner: false, c0: o.c0, c1: o.c1, end: segs[j % m].end, alpha: o.alpha)) }
            j = back[j]
        }
        return out.reversed()
    }
}
