import Foundation
import Accelerate

struct Param {
    let name: String
    let min: Double
    let max: Double
    let def: Double
    var step: Double = 1
}

/// Source and destination are premultiplied RGBA8 with stride w*4.
struct FilterIO {
    let src: UnsafePointer<UInt8>
    let dst: UnsafeMutablePointer<UInt8>
    let w: Int
    let h: Int
    let primary: RGBA
    let secondary: RGBA
}

struct Filter {
    let name: String
    var params: [Param] = []
    var key: String = ""
    /// Settings are a free-form list the filter decodes itself (Curves), not slider values.
    var rawValues = false
    private let body: (FilterIO, [Double]) -> Void

    init(name: String, params: [Param] = [], key: String = "", rawValues: Bool = false, run: @escaping (FilterIO, [Double]) -> Void) {
        self.name = name; self.params = params; self.key = key; self.rawValues = rawValues; body = run
    }

    /// Run with `values`, filling any missing or extra ones from the defaults and clamping to range,
    /// so a filter can never be handed the wrong number of settings.
    func run(_ io: FilterIO, _ values: [Double]) {
        if rawValues { body(io, values); return }
        let v = params.enumerated().map { i, p in i < values.count ? min(p.max, max(p.min, values[i])) : p.def }
        body(io, v)
    }
}

// MARK: - Pixel helpers

/// Run `body` for every row in 0..<h, split across all cores.
func parallelRows(_ h: Int, _ body: (Int) -> Void) {
    let chunks = min(h, ProcessInfo.processInfo.activeProcessorCount * 4)
    guard chunks > 1 else { for y in 0..<h { body(y) }; return }
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        let y0 = h * c / chunks, y1 = h * (c + 1) / chunks
        for y in y0..<y1 { body(y) }
    }
}

extension RNG {
    /// A generator seeded by position, so noise is the same however the work is split.
    init(seed: UInt64, x: Int, y: Int) {
        self.init(seed ^ (UInt64(truncatingIfNeeded: x) &* 0x9E3779B97F4A7C15) ^ (UInt64(truncatingIfNeeded: y) &* 0xC2B2AE3D27D4EB4F))
        _ = next()
    }
}

/// Per-pixel map on straight (unpremultiplied) colour. Body gets r,g,b,a (0...255) and returns new values.
@inline(__always)
func mapStraight(_ io: FilterIO, _ f: (inout Double, inout Double, inout Double, inout Double) -> Void) {
    mapStraightIndexed(io) { _, r, g, b, a in f(&r, &g, &b, &a) }
}

/// Like `mapStraight`, also passing the pixel's (x, y). Rows run in parallel.
func mapStraightIndexed(_ io: FilterIO, _ f: (Int, inout Double, inout Double, inout Double, inout Double) -> Void) {
    parallelRows(io.h) { y in
      for x in 0..<io.w {
        let p = y * io.w + x
        let i = p * 4
        let a8 = io.src[i + 3]
        if a8 == 0 { io.dst[i] = 0; io.dst[i + 1] = 0; io.dst[i + 2] = 0; io.dst[i + 3] = 0; continue }
        var r = Double(unpremul(io.src[i], a8)), g = Double(unpremul(io.src[i + 1], a8))
        var b = Double(unpremul(io.src[i + 2], a8)), a = Double(a8)
        f(p, &r, &g, &b, &a)
        let na = Int(clamp8(a))
        io.dst[i] = premul(Int(clamp8(r)), na)
        io.dst[i + 1] = premul(Int(clamp8(g)), na)
        io.dst[i + 2] = premul(Int(clamp8(b)), na)
        io.dst[i + 3] = UInt8(na)
      }
    }
}

func applyLUT(_ io: FilterIO, _ lr: [UInt8], _ lg: [UInt8], _ lb: [UInt8]) {
    parallelRows(io.h) { y in
      for p in (y * io.w)..<((y + 1) * io.w) {
        let i = p * 4
        let a = io.src[i + 3]
        if a == 0 { io.dst[i] = 0; io.dst[i + 1] = 0; io.dst[i + 2] = 0; io.dst[i + 3] = 0; continue }
        io.dst[i] = premul(Int(lr[Int(unpremul(io.src[i], a))]), Int(a))
        io.dst[i + 1] = premul(Int(lg[Int(unpremul(io.src[i + 1], a))]), Int(a))
        io.dst[i + 2] = premul(Int(lb[Int(unpremul(io.src[i + 2], a))]), Int(a))
        io.dst[i + 3] = a
      }
    }
}

func lut(_ f: (Double) -> Double) -> [UInt8] { (0..<256).map { clamp8(f(Double($0))) } }

/// Approximate Gaussian via three box passes (vImage).
func gaussian(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, sigma: Double) {
    let n = w * h * 4
    if sigma < 0.3 { memcpy(dst, src, n); return }
    var k = Int((12 * sigma * sigma / 3 + 1).squareRoot())
    if k % 2 == 0 { k += 1 }
    k = max(3, k)
    let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
    defer { tmp.deallocate() }
    let hh = vImagePixelCount(h), ww = vImagePixelCount(w)
    var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: hh, width: ww, rowBytes: w * 4)
    var t = vImage_Buffer(data: tmp, height: hh, width: ww, rowBytes: w * 4)
    var d = vImage_Buffer(data: dst, height: hh, width: ww, rowBytes: w * 4)
    let flags = vImage_Flags(kvImageEdgeExtend)
    vImageBoxConvolve_ARGB8888(&s, &d, nil, 0, 0, UInt32(k), UInt32(k), nil, flags)
    vImageBoxConvolve_ARGB8888(&d, &t, nil, 0, 0, UInt32(k), UInt32(k), nil, flags)
    vImageBoxConvolve_ARGB8888(&t, &d, nil, 0, 0, UInt32(k), UInt32(k), nil, flags)
}

/// Bilinear sample of premultiplied pixels with edge clamping.
@inline(__always)
func sample(_ s: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ fx: Double, _ fy: Double, _ out: UnsafeMutablePointer<UInt8>) {
    let x = min(max(fx - 0.5, 0), Double(w - 1)), y = min(max(fy - 0.5, 0), Double(h - 1))
    let x0 = Int(x), y0 = Int(y)
    let x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
    let tx = x - Double(x0), ty = y - Double(y0)
    for c in 0..<4 {
        let a = Double(s[(y0 * w + x0) * 4 + c]), b = Double(s[(y0 * w + x1) * 4 + c])
        let cc = Double(s[(y1 * w + x0) * 4 + c]), d = Double(s[(y1 * w + x1) * 4 + c])
        out[c] = clamp8((a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + d * tx) * ty)
    }
}

/// Inverse-mapped distortion: `f` maps destination (x,y) to a source point.
func distort(_ io: FilterIO, _ f: (Double, Double) -> (Double, Double)) {
    parallelRows(io.h) { y in
        for x in 0..<io.w {
            let (sx, sy) = f(Double(x) + 0.5, Double(y) + 0.5)
            sample(io.src, io.w, io.h, sx, sy, io.dst + (y * io.w + x) * 4)
        }
    }
}

struct RNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u = max(unit(), 1e-12), v = unit()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

func rgbToHsl(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let r = r / 255, g = g / 255, b = b / 255
    let mx = max(r, g, b), mn = min(r, g, b)
    let l = (mx + mn) / 2
    if mx == mn { return (0, 0, l) }
    let d = mx - mn
    let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
    var h: Double
    if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
    h /= 6
    return (h, s, l)
}

func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
    if s == 0 { return (l * 255, l * 255, l * 255) }
    func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
        var t = t0
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 0.5 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    return (hue(p, q, h + 1.0 / 3) * 255, hue(p, q, h) * 255, hue(p, q, h - 1.0 / 3) * 255)
}

/// Directional 3×3 derivative used by Edge Detect / Emboss / Relief.
func directional(_ io: FilterIO, angle: Double, _ out: (_ i: Int, _ g: [Double]) -> Void) {
    let th = angle * .pi / 180
    var k = [Double](repeating: 0, count: 9)
    for dy in -1...1 { for dx in -1...1 { k[(dy + 1) * 3 + dx + 1] = Double(dx) * cos(th) - Double(dy) * sin(th) } }
    parallelRows(io.h) { y in
        var g = [0.0, 0.0, 0.0]
        for x in 0..<io.w {
            g[0] = 0; g[1] = 0; g[2] = 0
            for dy in -1...1 {
                let yy = min(max(y + dy, 0), io.h - 1)
                for dx in -1...1 {
                    let kk = k[(dy + 1) * 3 + dx + 1]
                    if kk == 0 { continue }
                    let xx = min(max(x + dx, 0), io.w - 1)
                    let j = (yy * io.w + xx) * 4
                    let a = io.src[j + 3]
                    g[0] += kk * Double(unpremul(io.src[j], a))
                    g[1] += kk * Double(unpremul(io.src[j + 1], a))
                    g[2] += kk * Double(unpremul(io.src[j + 2], a))
                }
            }
            out((y * io.w + x) * 4, g)
        }
    }
}

func writeStraight(_ io: FilterIO, _ i: Int, _ r: Double, _ g: Double, _ b: Double, _ a: UInt8) {
    io.dst[i] = premul(Int(clamp8(r)), Int(a))
    io.dst[i + 1] = premul(Int(clamp8(g)), Int(a))
    io.dst[i + 2] = premul(Int(clamp8(b)), Int(a))
    io.dst[i + 3] = a
}

// MARK: - Catalogue

enum Filters {
    static let baseAdjustments: [Filter] = [
        Filter(name: "Auto-Level", key: "L") { io, _ in
            var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
            var total = 0
            for p in 0..<(io.w * io.h) {
                let i = p * 4, a = io.src[i + 3]
                if a == 0 { continue }
                total += 1
                for c in 0..<3 { hist[c][Int(unpremul(io.src[i + c], a))] += 1 }
            }
            let cut = max(1, total / 200)
            var luts: [[UInt8]] = []
            for c in 0..<3 {
                var lo = 0, acc = 0
                while lo < 255 && acc + hist[c][lo] < cut { acc += hist[c][lo]; lo += 1 }
                var hi = 255; acc = 0
                while hi > 0 && acc + hist[c][hi] < cut { acc += hist[c][hi]; hi -= 1 }
                if hi <= lo { luts.append((0..<256).map { UInt8($0) }); continue }
                luts.append(lut { (($0 - Double(lo)) / Double(hi - lo)) * 255 })
            }
            applyLUT(io, luts[0], luts[1], luts[2])
        },
        Filter(name: "Black and White", key: "G") { io, _ in
            mapStraight(io) { r, g, b, _ in let y = 0.299 * r + 0.587 * g + 0.114 * b; r = y; g = y; b = y }
        },
        Filter(name: "Brightness / Contrast", params: [
            Param(name: "Brightness", min: -100, max: 100, def: 0),
            Param(name: "Contrast", min: -100, max: 100, def: 0),
        ]) { io, v in
            let c = v[1] * 2.55
            let f = (259 * (c + 255)) / (255 * (259 - c))
            let l = lut { (($0 - 127.5) * f + 127.5) + v[0] * 1.275 }
            applyLUT(io, l, l, l)
        },
        Filter(name: "Hue / Saturation", params: [
            Param(name: "Hue", min: -180, max: 180, def: 0),
            Param(name: "Saturation", min: 0, max: 200, def: 100),
            Param(name: "Lightness", min: -100, max: 100, def: 0),
        ], key: "U") { io, v in
            let dh = v[0] / 360, sat = v[1] / 100, light = v[2] / 100
            mapStraight(io) { r, g, b, _ in
                var (h, s, l) = rgbToHsl(r, g, b)
                h += dh; if h < 0 { h += 1 }; if h > 1 { h -= 1 }
                s = min(1, s * sat)
                (r, g, b) = hslToRgb(h, s, l)
                if light > 0 { r += (255 - r) * light; g += (255 - g) * light; b += (255 - b) * light }
                if light < 0 { r *= 1 + light; g *= 1 + light; b *= 1 + light }
                _ = l
            }
        },
        Filter(name: "Invert Colors", key: "I") { io, _ in
            let l = lut { 255 - $0 }
            applyLUT(io, l, l, l)
        },
        Filter(name: "Levels", params: [
            Param(name: "Input black", min: 0, max: 254, def: 0),
            Param(name: "Input white", min: 1, max: 255, def: 255),
            Param(name: "Gamma", min: 0.1, max: 5, def: 1, step: 0.01),
            Param(name: "Output black", min: 0, max: 255, def: 0),
            Param(name: "Output white", min: 0, max: 255, def: 255),
        ]) { io, v in
            let lo = v[0], hi = max(v[0] + 1, v[1]), gm = v[2], olo = v[3], ohi = v[4]
            let l = lut { x in
                let t = min(1, max(0, (x - lo) / (hi - lo)))
                return olo + pow(t, 1 / gm) * (ohi - olo)
            }
            applyLUT(io, l, l, l)
        },
        Filter(name: "Posterize", params: [Param(name: "Levels", min: 2, max: 64, def: 16)], key: "P") { io, v in
            let n = v[0] - 1
            let l = lut { ($0 / 255 * n).rounded() / n * 255 }
            applyLUT(io, l, l, l)
        },
        Filter(name: "Sepia", key: "E") { io, _ in
            mapStraight(io) { r, g, b, _ in
                let nr = 0.393 * r + 0.769 * g + 0.189 * b
                let ng = 0.349 * r + 0.686 * g + 0.168 * b
                let nb = 0.272 * r + 0.534 * g + 0.131 * b
                r = nr; g = ng; b = nb
            }
        },
        Filter(name: "Vibrance", params: [Param(name: "Amount", min: -100, max: 100, def: 40)]) { io, v in
            let amt = v[0] / 100
            mapStraight(io) { r, g, b, _ in
                let mx = max(r, g, b), avg = (r + g + b) / 3
                let k = amt * (1 - abs(mx - avg) * 2 / 255) * 1.5
                r += (r - avg) * k; g += (g - avg) * k; b += (b - avg) * k
            }
        },
    ]

    static let baseEffects: [(String, [Filter])] = [
        ("Artistic", [
            Filter(name: "Oil Painting", params: [
                Param(name: "Brush size", min: 1, max: 8, def: 3),
                Param(name: "Coarseness", min: 3, max: 255, def: 50),
            ]) { io, v in
                let r = Int(v[0]), levels = Int(v[1])
                var count = [Int](repeating: 0, count: levels)
                var sr = [Int](repeating: 0, count: levels), sg = sr, sb = sr, sa = sr
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        for i in 0..<levels { count[i] = 0; sr[i] = 0; sg[i] = 0; sb[i] = 0; sa[i] = 0 }
                        for yy in max(0, y - r)...min(io.h - 1, y + r) {
                            for xx in max(0, x - r)...min(io.w - 1, x + r) {
                                let j = (yy * io.w + xx) * 4
                                let cr = Int(io.src[j]), cg = Int(io.src[j + 1]), cb = Int(io.src[j + 2])
                                let bin = (cr + cg + cb) * (levels - 1) / 765
                                count[bin] += 1; sr[bin] += cr; sg[bin] += cg; sb[bin] += cb; sa[bin] += Int(io.src[j + 3])
                            }
                        }
                        var best = 0
                        for i in 1..<levels where count[i] > count[best] { best = i }
                        let n = max(1, count[best]), o = (y * io.w + x) * 4
                        io.dst[o] = UInt8(sr[best] / n); io.dst[o + 1] = UInt8(sg[best] / n)
                        io.dst[o + 2] = UInt8(sb[best] / n); io.dst[o + 3] = UInt8(sa[best] / n)
                    }
                }
            },
            Filter(name: "Pencil Sketch", params: [
                Param(name: "Pencil tip size", min: 1, max: 20, def: 3),
                Param(name: "Range", min: -20, max: 20, def: 0),
            ]) { io, v in
                let n = io.w * io.h
                let gray = UnsafeMutablePointer<UInt8>.allocate(capacity: n * 4)
                let blur = UnsafeMutablePointer<UInt8>.allocate(capacity: n * 4)
                defer { gray.deallocate(); blur.deallocate() }
                for p in 0..<n {
                    let i = p * 4, a = io.src[i + 3]
                    let y = 0.299 * Double(unpremul(io.src[i], a)) + 0.587 * Double(unpremul(io.src[i + 1], a)) + 0.114 * Double(unpremul(io.src[i + 2], a))
                    let inv = 255 - clamp8(y)
                    gray[i] = clamp8(y); gray[i + 1] = inv; gray[i + 2] = 0; gray[i + 3] = 255
                }
                gaussian(gray, blur, io.w, io.h, sigma: v[0])
                let contrast = 1 + v[1] / 20
                for p in 0..<n {
                    let i = p * 4
                    let base = Double(gray[i]), bl = Double(blur[i + 1])
                    var d = bl >= 255 ? 255 : min(255, base * 255 / (255 - bl))
                    d = (d - 128) * contrast + 128
                    writeStraight(io, i, d, d, d, io.src[i + 3])
                }
            },
        ]),
        ("Blurs", [
            Filter(name: "Gaussian Blur", params: [Param(name: "Radius", min: 0, max: 200, def: 2)]) { io, v in
                gaussian(io.src, io.dst, io.w, io.h, sigma: v[0] / 2)
            },
            Filter(name: "Motion Blur", params: [
                Param(name: "Angle", min: -180, max: 180, def: 25),
                Param(name: "Distance", min: 1, max: 200, def: 10),
            ]) { io, v in
                let ang = v[0] * .pi / 180, dist = v[1]
                let n = max(2, min(64, Int(dist)))
                let offs: [(Int, Int)] = (0..<n).map { i in
                    let t = Double(i) / Double(n - 1) - 0.5
                    return (Int((cos(ang) * dist * t).rounded()), Int((-sin(ang) * dist * t).rounded()))
                }
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        var s = (0, 0, 0, 0)
                        for (dx, dy) in offs {
                            let xx = min(max(x + dx, 0), io.w - 1), yy = min(max(y + dy, 0), io.h - 1)
                            let j = (yy * io.w + xx) * 4
                            s.0 += Int(io.src[j]); s.1 += Int(io.src[j + 1]); s.2 += Int(io.src[j + 2]); s.3 += Int(io.src[j + 3])
                        }
                        let o = (y * io.w + x) * 4
                        io.dst[o] = UInt8(s.0 / n); io.dst[o + 1] = UInt8(s.1 / n); io.dst[o + 2] = UInt8(s.2 / n); io.dst[o + 3] = UInt8(s.3 / n)
                    }
                }
            },
            Filter(name: "Zoom Blur", params: [Param(name: "Amount", min: 0, max: 100, def: 10)]) { io, v in
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, amt = v[0] / 100 * 0.5
                let n = 24
                let px = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
                defer { px.deallocate() }
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        var s = [0.0, 0, 0, 0]
                        let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                        for i in 0..<n {
                            let k = 1 - amt * Double(i) / Double(n)
                            sample(io.src, io.w, io.h, cx + dx * k, cy + dy * k, px)
                            for c in 0..<4 { s[c] += Double(px[c]) }
                        }
                        let o = (y * io.w + x) * 4
                        for c in 0..<4 { io.dst[o + c] = clamp8(s[c] / Double(n)) }
                    }
                }
            },
        ]),
        ("Distort", [
            Filter(name: "Bulge", params: [Param(name: "Amount", min: -200, max: 100, def: 45)]) { io, v in
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, R = min(cx, cy)
                let a = min(0.99, v[0] / 100)
                distort(io) { x, y in
                    let dx = x - cx, dy = y - cy, r = (dx * dx + dy * dy).squareRoot() / R
                    if r >= 1 { return (x, y) }
                    let k = 1 - a * (1 - r) * (1 - r)
                    return (cx + dx * k, cy + dy * k)
                }
            },
            Filter(name: "Frosted Glass", params: [Param(name: "Amount", min: 1, max: 20, def: 3)]) { io, v in
                let amt = v[0]
                distort(io) { x, y in
                    var rng = RNG(seed: 42, x: Int(x), y: Int(y))
                    return (x + (rng.unit() * 2 - 1) * amt, y + (rng.unit() * 2 - 1) * amt)
                }
            },
            Filter(name: "Pixelate", params: [Param(name: "Cell size", min: 1, max: 100, def: 4)]) { io, v in
                let c = Int(v[0])
                var by = 0
                while by < io.h {
                    var bx = 0
                    while bx < io.w {
                        let x1 = min(io.w, bx + c), y1 = min(io.h, by + c)
                        var s = (0, 0, 0, 0), n = 0
                        for y in by..<y1 { for x in bx..<x1 {
                            let j = (y * io.w + x) * 4
                            s.0 += Int(io.src[j]); s.1 += Int(io.src[j + 1]); s.2 += Int(io.src[j + 2]); s.3 += Int(io.src[j + 3]); n += 1
                        } }
                        for y in by..<y1 { for x in bx..<x1 {
                            let o = (y * io.w + x) * 4
                            io.dst[o] = UInt8(s.0 / n); io.dst[o + 1] = UInt8(s.1 / n); io.dst[o + 2] = UInt8(s.2 / n); io.dst[o + 3] = UInt8(s.3 / n)
                        } }
                        bx += c
                    }
                    by += c
                }
            },
            Filter(name: "Twist", params: [Param(name: "Amount", min: -100, max: 100, def: 30)]) { io, v in
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, R = min(cx, cy)
                let amt = v[0] / 100 * 2 * .pi
                distort(io) { x, y in
                    let dx = x - cx, dy = y - cy, r = (dx * dx + dy * dy).squareRoot() / R
                    if r >= 1 { return (x, y) }
                    let t = amt * (1 - r) * (1 - r)
                    return (cx + dx * cos(t) - dy * sin(t), cy + dx * sin(t) + dy * cos(t))
                }
            },
        ]),
        ("Noise", [
            Filter(name: "Add Noise", params: [
                Param(name: "Intensity", min: 0, max: 100, def: 64),
                Param(name: "Color saturation", min: 0, max: 400, def: 100),
                Param(name: "Coverage", min: 0, max: 100, def: 100),
            ]) { io, v in
                let inten = v[0] / 100 * 64, sat = v[1] / 100, cov = v[2] / 100
                let w = io.w
                mapStraightIndexed(io) { p, r, g, b, _ in
                    var rng = RNG(seed: 7, x: p % w, y: p / w)
                    if rng.unit() > cov { return }
                    let base = rng.gauss() * inten
                    r += base + rng.gauss() * inten * sat * 0.5
                    g += base + rng.gauss() * inten * sat * 0.5
                    b += base + rng.gauss() * inten * sat * 0.5
                }
            },
            Filter(name: "Median", params: [
                Param(name: "Radius", min: 1, max: 20, def: 2),
                Param(name: "Percentile", min: 0, max: 100, def: 50),
            ]) { io, v in
                let r = Int(v[0]), pct = v[1] / 100
                for c in 0..<4 {
                    for y in 0..<io.h {
                        var hist = [Int](repeating: 0, count: 256)
                        var cnt = 0
                        let y0 = max(0, y - r), y1 = min(io.h - 1, y + r)
                        for yy in y0...y1 { for xx in 0...min(io.w - 1, r) { hist[Int(io.src[(yy * io.w + xx) * 4 + c])] += 1; cnt += 1 } }
                        for x in 0..<io.w {
                            if x > 0 {
                                let out = x - r - 1, inn = x + r
                                if out >= 0 { for yy in y0...y1 { hist[Int(io.src[(yy * io.w + out) * 4 + c])] -= 1; cnt -= 1 } }
                                if inn < io.w { for yy in y0...y1 { hist[Int(io.src[(yy * io.w + inn) * 4 + c])] += 1; cnt += 1 } }
                            }
                            let k = Int(Double(cnt - 1) * pct)
                            var acc = 0, m = 0
                            while m < 255 && acc + hist[m] <= k { acc += hist[m]; m += 1 }
                            io.dst[(y * io.w + x) * 4 + c] = UInt8(m)
                        }
                    }
                }
                for p in 0..<(io.w * io.h) {
                    let i = p * 4
                    for c in 0..<3 where io.dst[i + c] > io.dst[i + 3] { io.dst[i + c] = io.dst[i + 3] }
                }
            },
        ]),
        ("Photo", [
            Filter(name: "Glow", params: [
                Param(name: "Radius", min: 1, max: 40, def: 6),
                Param(name: "Strength", min: 0, max: 100, def: 50),
            ]) { io, v in
                gaussian(io.src, io.dst, io.w, io.h, sigma: v[0])
                let k = v[1] / 100
                for i in stride(from: 0, to: io.w * io.h * 4, by: 4) {
                    for c in 0..<3 {
                        let a = Double(io.src[i + c]) / 255, b = Double(io.dst[i + c]) / 255 * k
                        io.dst[i + c] = clamp8((1 - (1 - a) * (1 - b)) * 255)
                    }
                    io.dst[i + 3] = io.src[i + 3]
                    for c in 0..<3 where io.dst[i + c] > io.dst[i + 3] { io.dst[i + c] = io.dst[i + 3] }
                }
            },
            Filter(name: "Sharpen", params: [Param(name: "Amount", min: 1, max: 20, def: 10)]) { io, v in
                gaussian(io.src, io.dst, io.w, io.h, sigma: 1.2)
                let k = v[0] / 8
                for i in stride(from: 0, to: io.w * io.h * 4, by: 4) {
                    let a = io.src[i + 3]
                    for c in 0..<3 {
                        let s = Double(io.src[i + c]), b = Double(io.dst[i + c])
                        io.dst[i + c] = min(a, clamp8(s + (s - b) * k))
                    }
                    io.dst[i + 3] = a
                }
            },
            Filter(name: "Vignette", params: [
                Param(name: "Radius", min: 10, max: 200, def: 70),
                Param(name: "Strength", min: 0, max: 100, def: 80),
            ]) { io, v in
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, md = (cx * cx + cy * cy).squareRoot()
                let r0 = v[0] / 100 * 0.5, r1 = r0 + 0.6, s = v[1] / 100
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        let d = ((Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)).squareRoot() / md
                        var t = min(1, max(0, (d - r0) / (r1 - r0)))
                        t = t * t * (3 - 2 * t)
                        let f = 1 - s * t
                        let i = (y * io.w + x) * 4
                        for c in 0..<3 { io.dst[i + c] = clamp8(Double(io.src[i + c]) * f) }
                        io.dst[i + 3] = io.src[i + 3]
                    }
                }
            },
        ]),
        ("Render", [
            Filter(name: "Clouds", params: [
                Param(name: "Scale", min: 2, max: 1000, def: 250),
                Param(name: "Roughness", min: 0, max: 100, def: 50),
                Param(name: "Seed", min: 0, max: 999, def: 0),
            ]) { io, v in
                let scale = v[0], rough = v[1] / 100, seed = UInt64(v[2])
                func hash(_ x: Int, _ y: Int, _ o: Int) -> Double {
                    var h = UInt64(bitPattern: Int64(x &* 374761393 &+ y &* 668265263 &+ o &* 2147483647)) &+ seed &* 0x9E3779B97F4A7C15
                    h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
                    h = (h ^ (h >> 33)) &* 0xc4ceb9fe1a85ec53
                    return Double((h ^ (h >> 33)) >> 11) / Double(1 << 53)
                }
                func noise(_ x: Double, _ y: Double, _ o: Int) -> Double {
                    let xi = Int(floor(x)), yi = Int(floor(y))
                    var tx = x - Double(xi), ty = y - Double(yi)
                    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
                    let a = hash(xi, yi, o), b = hash(xi + 1, yi, o), c = hash(xi, yi + 1, o), d = hash(xi + 1, yi + 1, o)
                    return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                }
                let p = io.primary, s = io.secondary
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        var amp = 1.0, freq = 1.0 / scale, sum = 0.0, norm = 0.0
                        for o in 0..<8 {
                            sum += noise(Double(x) * freq, Double(y) * freq, o) * amp
                            norm += amp; amp *= rough; freq *= 2
                        }
                        let t = min(1, max(0, (sum / norm - 0.5) * 1.6 + 0.5))
                        let a = Double(p.a) + (Double(s.a) - Double(p.a)) * t
                        let r = Double(p.r) + (Double(s.r) - Double(p.r)) * t
                        let g = Double(p.g) + (Double(s.g) - Double(p.g)) * t
                        let b = Double(p.b) + (Double(s.b) - Double(p.b)) * t
                        writeStraight(io, (y * io.w + x) * 4, r, g, b, clamp8(a))
                    }
                }
            },
            Filter(name: "Mandelbrot Fractal", params: [
                Param(name: "Zoom", min: 1, max: 100, def: 1),
                Param(name: "Hue shift", min: 0, max: 360, def: 200),
            ]) { io, v in
                let scale = 3.2 / v[0] / Double(min(io.w, io.h))
                let cx = -0.6, cy = 0.0
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        let c0 = cx + (Double(x) - Double(io.w) / 2) * scale
                        let c1 = cy + (Double(y) - Double(io.h) / 2) * scale
                        var zr = 0.0, zi = 0.0, n = 0
                        while n < 256 && zr * zr + zi * zi < 16 {
                            let t = zr * zr - zi * zi + c0
                            zi = 2 * zr * zi + c1; zr = t; n += 1
                        }
                        let i = (y * io.w + x) * 4
                        if n == 256 { writeStraight(io, i, 0, 0, 0, 255); continue }
                        let sm = Double(n) + 1 - log2(log2(zr * zr + zi * zi) / 2)
                        let h = (v[1] / 360 + sm / 64).truncatingRemainder(dividingBy: 1)
                        let (r, g, b) = hslToRgb(h, 0.85, min(0.6, 0.2 + sm / 80))
                        writeStraight(io, i, r, g, b, 255)
                    }
                }
            },
        ]),
        ("Stylize", [
            Filter(name: "Edge Detect", params: [Param(name: "Angle", min: -180, max: 180, def: 45)]) { io, v in
                directional(io, angle: v[0]) { i, g in writeStraight(io, i, 128 + g[0], 128 + g[1], 128 + g[2], io.src[i + 3]) }
            },
            Filter(name: "Emboss", params: [Param(name: "Angle", min: -180, max: 180, def: 0)]) { io, v in
                directional(io, angle: v[0]) { i, g in
                    let y = 128 + 0.299 * g[0] + 0.587 * g[1] + 0.114 * g[2]
                    writeStraight(io, i, y, y, y, io.src[i + 3])
                }
            },
            Filter(name: "Relief", params: [Param(name: "Angle", min: -180, max: 180, def: 45)]) { io, v in
                directional(io, angle: v[0]) { i, g in
                    let a = io.src[i + 3]
                    writeStraight(io, i, Double(unpremul(io.src[i], a)) + g[0] * 0.5,
                                  Double(unpremul(io.src[i + 1], a)) + g[1] * 0.5,
                                  Double(unpremul(io.src[i + 2], a)) + g[2] * 0.5, a)
                }
            },
            Filter(name: "Outline", params: [Param(name: "Thickness", min: 1, max: 20, def: 3)]) { io, v in
                // Dilate darker tones outward: min filter over a disc, on straight colour.
                let r = Int(v[0])
                for y in 0..<io.h {
                    for x in 0..<io.w {
                        var mn = (255, 255, 255)
                        for yy in max(0, y - r)...min(io.h - 1, y + r) {
                            for xx in max(0, x - r)...min(io.w - 1, x + r) where (xx - x) * (xx - x) + (yy - y) * (yy - y) <= r * r {
                                let j = (yy * io.w + xx) * 4, a = io.src[j + 3]
                                if a == 0 { continue }
                                mn.0 = min(mn.0, Int(unpremul(io.src[j], a)))
                                mn.1 = min(mn.1, Int(unpremul(io.src[j + 1], a)))
                                mn.2 = min(mn.2, Int(unpremul(io.src[j + 2], a)))
                            }
                        }
                        let i = (y * io.w + x) * 4
                        writeStraight(io, i, Double(mn.0), Double(mn.1), Double(mn.2), io.src[i + 3])
                    }
                }
            },
        ]),
    ]
}
