import Foundation
import Accelerate
import ImageIO
import UniformTypeIdentifiers

// MARK: - Helpers for the photo effects

/// Rec. 601 luma of straight colour, 0...255.
@inline(__always) func luma(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.299 * r + 0.587 * g + 0.114 * b }

/// Straight (unpremultiplied) RGB of pixel `p`.
@inline(__always) func straight(_ s: UnsafePointer<UInt8>, _ p: Int) -> (Double, Double, Double, UInt8) {
    let i = p * 4, a = s[i + 3]
    return (Double(unpremul(s[i], a)), Double(unpremul(s[i + 1], a)), Double(unpremul(s[i + 2], a)), a)
}

/// Scratch buffer the size of the image.
final class Scratch {
    let p: UnsafeMutablePointer<UInt8>
    init(_ n: Int) { p = .allocate(capacity: n); p.initialize(repeating: 0, count: n) }
    deinit { p.deallocate() }
}

/// Edge-preserving blur run as a horizontal then a vertical pass: neighbours count less the more
/// their colour differs, so edges stay sharp while flat areas smooth out.
func bilateral(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, radius: Int, threshold: Double) {
    let tmp = Scratch(w * h * 4)
    let inv = 1 / max(1, threshold * threshold * 2)
    let spatial = (0...radius).map { exp(-Double($0 * $0) / Double(2 * max(1, radius * radius) / 2 + 1)) }
    func pass(_ s: UnsafePointer<UInt8>, _ d: UnsafeMutablePointer<UInt8>, horizontal: Bool) {
        parallelRows(h) { y in
            for x in 0..<w {
                let c = (y * w + x) * 4
                let cr = Double(s[c]), cg = Double(s[c + 1]), cb = Double(s[c + 2])
                var sum = (0.0, 0.0, 0.0, 0.0), wt = 0.0
                for k in -radius...radius {
                    let xx = horizontal ? min(max(x + k, 0), w - 1) : x
                    let yy = horizontal ? y : min(max(y + k, 0), h - 1)
                    let j = (yy * w + xx) * 4
                    let dr = Double(s[j]) - cr, dg = Double(s[j + 1]) - cg, db = Double(s[j + 2]) - cb
                    let f = spatial[abs(k)] * exp(-(dr * dr + dg * dg + db * db) * inv)
                    sum.0 += Double(s[j]) * f; sum.1 += Double(s[j + 1]) * f; sum.2 += Double(s[j + 2]) * f
                    sum.3 += Double(s[j + 3]) * f; wt += f
                }
                d[c] = clamp8(sum.0 / wt); d[c + 1] = clamp8(sum.1 / wt); d[c + 2] = clamp8(sum.2 / wt); d[c + 3] = clamp8(sum.3 / wt)
                // keep premultiplied validity
                let a = d[c + 3]
                if d[c] > a { d[c] = a }; if d[c + 1] > a { d[c + 1] = a }; if d[c + 2] > a { d[c + 2] = a }
            }
        }
    }
    pass(src, tmp.p, horizontal: true)
    pass(UnsafePointer(tmp.p), dst, horizontal: false)
}

/// Smooth value noise in 0...1 (for Dents).
@inline(__always) func valueNoise(_ x: Double, _ y: Double, seed: UInt64) -> Double {
    let x0 = floor(x), y0 = floor(y), tx = x - x0, ty = y - y0
    func h(_ i: Double, _ j: Double) -> Double {
        var r = RNG(seed: seed, x: Int(i), y: Int(j)); return r.unit()
    }
    let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
    let a = h(x0, y0), b = h(x0 + 1, y0), c = h(x0, y0 + 1), d = h(x0 + 1, y0 + 1)
    return (a * (1 - sx) + b * sx) * (1 - sy) + (c * (1 - sx) + d * sx) * sy
}

/// Composite `top` (premultiplied) over `bottom` into `out`, all w*h*4.
func over(_ top: UnsafePointer<UInt8>, _ bottom: UnsafePointer<UInt8>, _ out: UnsafeMutablePointer<UInt8>, _ n: Int) {
    for i in stride(from: 0, to: n * 4, by: 4) {
        let ia = 255 - Int(top[i + 3])
        for c in 0..<4 { out[i + c] = UInt8(min(255, Int(top[i + c]) + (Int(bottom[i + c]) * ia + 127) / 255)) }
    }
}

// MARK: - The extra catalogue

extension Filters {
    static let adjustments: [Filter] = (baseAdjustments + moreAdjustments + [Curves.filter]).sorted { $0.name < $1.name }

    static let effects: [(String, [Filter])] = {
        var groups = baseEffects
        for (name, list) in moreEffects {
            if let i = groups.firstIndex(where: { $0.0 == name }) {
                groups[i].1 = (groups[i].1 + list).sorted { $0.name < $1.name }
            } else {
                groups.append((name, list))
            }
        }
        return groups.sorted { $0.0 < $1.0 }
    }()

    static let moreAdjustments: [Filter] = [
        Filter(name: "Exposure", params: [Param(name: "Stops", min: -4, max: 4, def: 0.5, step: 0.05)]) { io, v in
            let k = pow(2, v[0])
            let l = lut { c in pow(min(1, pow(c / 255, 2.2) * k), 1 / 2.2) * 255 }
            applyLUT(io, l, l, l)
        },
        Filter(name: "Temperature / Tint", params: [
            Param(name: "Temperature", min: -100, max: 100, def: 20),
            Param(name: "Tint", min: -100, max: 100, def: 0),
        ]) { io, v in
            let t = v[0] / 100, tint = v[1] / 100
            let lr = lut { $0 + t * 40 * (1 - $0 / 510) }
            let lg = lut { $0 - tint * 30 * (1 - $0 / 510) }
            let lb = lut { $0 - t * 40 * (1 - $0 / 510) }
            applyLUT(io, lr, lg, lb)
        },
        Filter(name: "Shadows / Highlights", params: [
            Param(name: "Shadows", min: 0, max: 100, def: 35),
            Param(name: "Highlights", min: 0, max: 100, def: 0),
            Param(name: "Radius", min: 1, max: 200, def: 30),
        ]) { io, v in
            // Local brightness from a wide blur decides how much each pixel is lifted or pulled.
            let n = io.w * io.h
            let lum = Scratch(n * 4), blur = Scratch(n * 4)
            parallelRows(io.h) { y in
                for p in (y * io.w)..<((y + 1) * io.w) {
                    let (r, g, b, _) = straight(io.src, p)
                    let l = clamp8(luma(r, g, b))
                    lum.p[p * 4] = l; lum.p[p * 4 + 1] = l; lum.p[p * 4 + 2] = l; lum.p[p * 4 + 3] = 255
                }
            }
            gaussian(lum.p, blur.p, io.w, io.h, sigma: v[2])
            let sh = v[0] / 100, hi = v[1] / 100
            mapStraightIndexed(io) { p, r, g, b, _ in
                let L = Double(blur.p[p * 4]) / 255
                let lift = sh * pow(1 - L, 2) * 1.6, pull = hi * pow(L, 2) * 0.8
                for c in [0, 1, 2] {
                    var x = c == 0 ? r : c == 1 ? g : b
                    x += (255 - x) * lift * (x / 255 + 0.15)
                    x -= x * pull * (1 - x / 400)
                    if c == 0 { r = x } else if c == 1 { g = x } else { b = x }
                }
            }
        },
    ]

    static let moreEffects: [(String, [Filter])] = [
        ("Artistic", [
            Filter(name: "Ink Sketch", params: [
                Param(name: "Ink outline", min: 0, max: 99, def: 50),
                Param(name: "Coloring", min: 0, max: 100, def: 50),
            ]) { io, v in
                let n = io.w * io.h
                let soft = Scratch(n * 4)
                gaussian(io.src, soft.p, io.w, io.h, sigma: 1.2)
                let ink = v[0] / 100, col = v[1] / 100
                let w = io.w, h = io.h
                parallelRows(h) { y in
                    for x in 0..<w {
                        var gx = 0.0, gy = 0.0
                        for dy in -1...1 { for dx in -1...1 {
                            let j = (min(max(y + dy, 0), h - 1) * w + min(max(x + dx, 0), w - 1))
                            let (r, g, b, _) = straight(UnsafePointer(soft.p), j)
                            let l = luma(r, g, b)
                            gx += l * Double(dx) * (dy == 0 ? 2 : 1); gy += l * Double(dy) * (dx == 0 ? 2 : 1)
                        } }
                        let edge = min(1, (gx * gx + gy * gy).squareRoot() / (40 + 200 * (1 - ink)))
                        let p = y * w + x
                        let (r, g, b, a) = straight(io.src, p)
                        let gray = luma(r, g, b)
                        let k = (1 - edge * 1.2)
                        let cr = (gray + (r - gray) * col) * 0.35 + 255 * 0.65, cg = (gray + (g - gray) * col) * 0.35 + 255 * 0.65
                        let cb = (gray + (b - gray) * col) * 0.35 + 255 * 0.65
                        writeStraight(io, p * 4, cr * k, cg * k, cb * k, a)
                    }
                }
            },
        ]),
        ("Blurs", [
            Filter(name: "Surface Blur", params: [
                Param(name: "Radius", min: 1, max: 30, def: 6),
                Param(name: "Threshold", min: 1, max: 100, def: 25),
            ]) { io, v in
                bilateral(io.src, io.dst, io.w, io.h, radius: Int(v[0]), threshold: v[1] * 1.2)
            },
            Filter(name: "Radial Blur", params: [
                Param(name: "Angle", min: 0, max: 90, def: 6),
                Param(name: "Center X %", min: 0, max: 100, def: 50),
                Param(name: "Center Y %", min: 0, max: 100, def: 50),
            ]) { io, v in
                let cx = Double(io.w) * v[1] / 100, cy = Double(io.h) * v[2] / 100
                let ang = v[0] * .pi / 180
                let w = io.w, h = io.h
                parallelRows(h) { y in
                    var px = [UInt8](repeating: 0, count: 4)
                    for x in 0..<w {
                        let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                        let r = (dx * dx + dy * dy).squareRoot()
                        let n = max(1, min(48, Int(r * ang / 1.5)))
                        var s = (0.0, 0.0, 0.0, 0.0)
                        for i in 0..<n {
                            let t = n == 1 ? 0 : (Double(i) / Double(n - 1) - 0.5) * ang
                            let sx = cx + dx * cos(t) - dy * sin(t), sy = cy + dx * sin(t) + dy * cos(t)
                            px.withUnsafeMutableBufferPointer { sample(io.src, w, h, sx, sy, $0.baseAddress!) }
                            s.0 += Double(px[0]); s.1 += Double(px[1]); s.2 += Double(px[2]); s.3 += Double(px[3])
                        }
                        let o = (y * w + x) * 4, k = Double(n)
                        io.dst[o] = clamp8(s.0 / k); io.dst[o + 1] = clamp8(s.1 / k); io.dst[o + 2] = clamp8(s.2 / k); io.dst[o + 3] = clamp8(s.3 / k)
                    }
                }
            },
            Filter(name: "Fragment", params: [
                Param(name: "Fragments", min: 2, max: 50, def: 4),
                Param(name: "Distance", min: 0, max: 100, def: 8),
                Param(name: "Rotation", min: 0, max: 360, def: 0),
            ]) { io, v in
                let n = Int(v[0]), d = v[1], rot = v[2] * .pi / 180
                let offs = (0..<n).map { i -> (Int, Int) in
                    let a = rot + Double(i) * 2 * .pi / Double(n)
                    return (Int((cos(a) * d).rounded()), Int((sin(a) * d).rounded()))
                }
                let w = io.w, h = io.h
                parallelRows(h) { y in
                    for x in 0..<w {
                        var s = (0, 0, 0, 0)
                        for (ox, oy) in offs {
                            let j = (min(max(y + oy, 0), h - 1) * w + min(max(x + ox, 0), w - 1)) * 4
                            s.0 += Int(io.src[j]); s.1 += Int(io.src[j + 1]); s.2 += Int(io.src[j + 2]); s.3 += Int(io.src[j + 3])
                        }
                        let o = (y * w + x) * 4
                        io.dst[o] = UInt8(s.0 / n); io.dst[o + 1] = UInt8(s.1 / n); io.dst[o + 2] = UInt8(s.2 / n); io.dst[o + 3] = UInt8(s.3 / n)
                    }
                }
            },
        ]),
        ("Distort", [
            Filter(name: "Dents", params: [
                Param(name: "Scale", min: 1, max: 200, def: 25),
                Param(name: "Refraction", min: 0, max: 100, def: 20),
                Param(name: "Seed", min: 0, max: 999, def: 0),
            ]) { io, v in
                let sc = v[0], amt = v[1], seed = UInt64(v[2])
                distort(io) { x, y in
                    let nx = valueNoise(x / sc, y / sc, seed: seed) * 2 - 1
                    let ny = valueNoise(x / sc + 31.7, y / sc + 17.3, seed: seed &+ 1) * 2 - 1
                    return (x + nx * amt, y + ny * amt)
                }
            },
            Filter(name: "Polar Inversion", params: [Param(name: "Amount", min: 0.1, max: 4, def: 1, step: 0.05)]) { io, v in
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, R = min(cx, cy) * v[0]
                distort(io) { x, y in
                    let dx = x - cx, dy = y - cy, d2 = max(1, dx * dx + dy * dy)
                    var sx = cx + dx * R * R / d2, sy = cy + dy * R * R / d2
                    // wrap (reflect) so the far field tiles instead of smearing
                    let w = Double(io.w), h = Double(io.h)
                    sx = abs(sx.truncatingRemainder(dividingBy: 2 * w)); if sx > w { sx = 2 * w - sx }
                    sy = abs(sy.truncatingRemainder(dividingBy: 2 * h)); if sy > h { sy = 2 * h - sy }
                    return (sx, sy)
                }
            },
            Filter(name: "Tile Reflection", params: [
                Param(name: "Tile size", min: 2, max: 200, def: 40),
                Param(name: "Angle", min: -90, max: 90, def: 30),
                Param(name: "Curvature", min: -100, max: 100, def: 8),
            ]) { io, v in
                let size = v[0], a = v[1] * .pi / 180, curv = v[2] / 100
                distort(io) { x, y in
                    let u = x * cos(a) + y * sin(a), w = -x * sin(a) + y * cos(a)
                    let fu = (u / size).truncatingRemainder(dividingBy: 1), fw = (w / size).truncatingRemainder(dividingBy: 1)
                    let tu = (fu < 0 ? fu + 1 : fu) * 2 - 1, tw = (fw < 0 ? fw + 1 : fw) * 2 - 1
                    let k = curv * size * 0.5
                    return (x + tu * abs(tu) * k, y + tw * abs(tw) * k)
                }
            },
        ]),
        ("Fun", [
            Filter(name: "Deep Fry", params: [Param(name: "Intensity", min: 0, max: 100, def: 60)]) { io, v in
                let k = v[0] / 100
                let n = io.w * io.h
                let tmp = Scratch(n * 4)
                // oversaturate, crush, warm, sharpen, then crunch through a terrible JPEG
                let w = io.w
                parallelRows(io.h) { y in
                    for x in 0..<w {
                        let p = y * w + x
                        var (r, g, b, a) = straight(io.src, p)
                        let l = luma(r, g, b)
                        r = l + (r - l) * (1 + 2.5 * k); g = l + (g - l) * (1 + 2.5 * k); b = l + (b - l) * (1 + 2.5 * k)
                        r = (r - 128) * (1 + 0.9 * k) + 128 + 30 * k; g = (g - 128) * (1 + 0.9 * k) + 128 + 8 * k
                        b = (b - 128) * (1 + 0.9 * k) + 128 - 25 * k
                        var rng = RNG(seed: 99, x: x, y: y)
                        let noise = (rng.unit() - 0.5) * 60 * k
                        writeStraight(FilterIO(src: io.src, dst: tmp.p, w: io.w, h: io.h, primary: io.primary, secondary: io.secondary),
                                      p * 4, r + noise, g + noise, b + noise, a)
                    }
                }
                let sharp = Scratch(n * 4)
                gaussian(tmp.p, sharp.p, io.w, io.h, sigma: 1)
                for i in 0..<(n * 4) where i % 4 != 3 {
                    let d = Double(tmp.p[i]) * (1 + 2 * k) - Double(sharp.p[i]) * 2 * k
                    tmp.p[i] = min(tmp.p[(i | 3)], clamp8(d))
                }
                jpegCrunch(tmp.p, io.dst, io.w, io.h, quality: max(0.02, 0.35 - 0.33 * k))
            },
            Filter(name: "Needs More JPEG", params: [Param(name: "Quality", min: 1, max: 100, def: 5)]) { io, v in
                jpegCrunch(UnsafeMutablePointer(mutating: io.src), io.dst, io.w, io.h, quality: v[0] / 100)
            },
            Filter(name: "Chromatic Aberration", params: [
                Param(name: "Shift", min: 0, max: 50, def: 6),
                Param(name: "Radial", min: 0, max: 1, def: 1),
            ]) { io, v in
                let d = v[0], radial = v[1] >= 0.5
                let cx = Double(io.w) / 2, cy = Double(io.h) / 2, R = (cx * cx + cy * cy).squareRoot()
                let w = io.w, h = io.h
                parallelRows(h) { y in
                    var px = [UInt8](repeating: 0, count: 4)
                    for x in 0..<w {
                        let fx = Double(x) + 0.5, fy = Double(y) + 0.5
                        var ox = d, oy = 0.0
                        if radial { let dx = fx - cx, dy = fy - cy; ox = dx / R * d; oy = dy / R * d }
                        let o = (y * w + x) * 4
                        px.withUnsafeMutableBufferPointer { sample(io.src, w, h, fx + ox, fy + oy, $0.baseAddress!) }
                        let (rr, ra) = (px[0], px[3])
                        px.withUnsafeMutableBufferPointer { sample(io.src, w, h, fx - ox, fy - oy, $0.baseAddress!) }
                        let (bb, ba) = (px[2], px[3])
                        let a = max(io.src[o + 3], max(ra, ba))
                        io.dst[o] = min(a, rr); io.dst[o + 1] = min(a, io.src[o + 1]); io.dst[o + 2] = min(a, bb); io.dst[o + 3] = a
                    }
                }
            },
        ]),
        ("Noise", [
            Filter(name: "Reduce Noise", params: [
                Param(name: "Radius", min: 1, max: 12, def: 3),
                Param(name: "Strength", min: 1, max: 100, def: 40),
            ]) { io, v in
                bilateral(io.src, io.dst, io.w, io.h, radius: Int(v[0]), threshold: v[1] * 0.6)
            },
        ]),
        ("Object", [
            Filter(name: "Drop Shadow", params: [
                Param(name: "Offset X", min: -100, max: 100, def: 8),
                Param(name: "Offset Y", min: -100, max: 100, def: 8),
                Param(name: "Blur", min: 0, max: 100, def: 10),
                Param(name: "Opacity", min: 0, max: 100, def: 60),
            ]) { io, v in
                // Shadow from the layer's own shape, in the primary colour, under the layer.
                let n = io.w * io.h, w = io.w, h = io.h
                let shape = Scratch(n * 4), soft = Scratch(n * 4)
                let ox = Int(v[0]), oy = Int(v[1]), op = v[3] / 100
                let pc = io.primary
                parallelRows(h) { y in
                    for x in 0..<w {
                        let sx = x - ox, sy = y - oy
                        let a = sx >= 0 && sy >= 0 && sx < w && sy < h ? Double(io.src[(sy * w + sx) * 4 + 3]) * op : 0
                        let o = (y * w + x) * 4
                        shape.p[o] = premul(Int(pc.r), Int(a)); shape.p[o + 1] = premul(Int(pc.g), Int(a))
                        shape.p[o + 2] = premul(Int(pc.b), Int(a)); shape.p[o + 3] = UInt8(a)
                    }
                }
                gaussian(shape.p, soft.p, w, h, sigma: v[2] / 2)
                over(io.src, UnsafePointer(soft.p), io.dst, n)
            },
            Filter(name: "Outline Object", params: [
                Param(name: "Thickness", min: 1, max: 100, def: 6),
                Param(name: "Softness", min: 0, max: 20, def: 1),
            ]) { io, v in
                // Grow the layer's shape (max filter on alpha), fill it with the primary colour, put the layer on top.
                let n = io.w * io.h, w = io.w, h = io.h
                let alpha = Scratch(n), grown = Scratch(n)
                for p in 0..<n { alpha.p[p] = io.src[p * 4 + 3] }
                let k = Int(v[0]) * 2 + 1
                var s = vImage_Buffer(data: alpha.p, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var d = vImage_Buffer(data: grown.p, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                // A disc via two passes of a square max at 45° offsets is close enough; use square then soften.
                vImageMax_Planar8(&s, &d, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageEdgeExtend))
                let ring = Scratch(n * 4), soft = Scratch(n * 4)
                let pc = io.primary
                for p in 0..<n {
                    let a = Int(grown.p[p])
                    ring.p[p * 4] = premul(Int(pc.r), a); ring.p[p * 4 + 1] = premul(Int(pc.g), a)
                    ring.p[p * 4 + 2] = premul(Int(pc.b), a); ring.p[p * 4 + 3] = UInt8(a)
                }
                gaussian(ring.p, soft.p, w, h, sigma: v[1])
                over(io.src, UnsafePointer(soft.p), io.dst, n)
            },
        ]),
        ("Photo", [
            Filter(name: "Unsharp Mask", params: [
                Param(name: "Amount %", min: 1, max: 500, def: 120),
                Param(name: "Radius", min: 0.3, max: 50, def: 1.5, step: 0.1),
                Param(name: "Threshold", min: 0, max: 255, def: 2),
            ]) { io, v in
                let n = io.w * io.h
                let blur = Scratch(n * 4)
                gaussian(io.src, blur.p, io.w, io.h, sigma: v[1])
                let amt = v[0] / 100, th = v[2]
                parallelRows(io.h) { y in
                    for p in (y * io.w)..<((y + 1) * io.w) {
                        let i = p * 4, a = io.src[i + 3]
                        for c in 0..<3 {
                            let o = Double(io.src[i + c]), b = Double(blur.p[i + c]), d = o - b
                            io.dst[i + c] = min(a, abs(d) < th ? io.src[i + c] : clamp8(o + d * amt))
                        }
                        io.dst[i + 3] = a
                    }
                }
            },
            Filter(name: "Red Eye Removal", params: [
                Param(name: "Tolerance", min: 0, max: 100, def: 70),
                Param(name: "Strength", min: 0, max: 100, def: 100),
            ]) { io, v in
                // Works on the selection when there is one (select the eyes first), like Paint.NET.
                let tol = 1 + (1 - v[0] / 100) * 1.2, str = v[1] / 100
                mapStraight(io) { r, g, b, _ in
                    let gb = (g + b) / 2
                    guard r > gb * tol && r > 60 else { return }
                    let k = min(1, (r - gb * tol) / 60) * str
                    r = r + (gb * 0.9 - r) * k
                }
            },
            Filter(name: "Soften Portrait", params: [
                Param(name: "Softness", min: 0, max: 10, def: 5),
                Param(name: "Lighting", min: -20, max: 20, def: 0),
                Param(name: "Warmth", min: 0, max: 20, def: 10),
            ]) { io, v in
                let n = io.w * io.h
                let soft = Scratch(n * 4)
                bilateral(io.src, soft.p, io.w, io.h, radius: max(1, Int(v[0] * 1.2)), threshold: 18 + v[0] * 3)
                let light = v[1] * 3, warm = v[2] * 1.5
                parallelRows(io.h) { y in
                    for p in (y * io.w)..<((y + 1) * io.w) {
                        let (r0, g0, b0, a) = straight(io.src, p), (r1, g1, b1, _) = straight(UnsafePointer(soft.p), p)
                        let r = r0 * 0.4 + r1 * 0.6 + light + warm, g = g0 * 0.4 + g1 * 0.6 + light + warm * 0.4
                        let b = b0 * 0.4 + b1 * 0.6 + light - warm * 0.5
                        writeStraight(io, p * 4, r, g, b, a)
                    }
                }
            },
        ]),
        ("Render", [
            Filter(name: "Julia Fractal", params: [
                Param(name: "Factor", min: 1, max: 10, def: 4),
                Param(name: "Zoom", min: 0.2, max: 50, def: 1, step: 0.1),
                Param(name: "Angle", min: -180, max: 180, def: 0),
            ]) { io, v in
                let w = Double(io.w), h = Double(io.h), z = v[1], th = v[2] * .pi / 180
                let cre = -0.8 + v[0] * 0.01, cim = 0.156
                let p1 = io.primary, p2 = io.secondary
                parallelRows(io.h) { y in
                    for x in 0..<io.w {
                        var zx = (Double(x) - w / 2) / (min(w, h) / 3) / z, zy = (Double(y) - h / 2) / (min(w, h) / 3) / z
                        (zx, zy) = (zx * cos(th) - zy * sin(th), zx * sin(th) + zy * cos(th))
                        var i = 0
                        while i < 256 && zx * zx + zy * zy < 4 {
                            (zx, zy) = (zx * zx - zy * zy + cre, 2 * zx * zy + cim); i += 1
                        }
                        let t = i >= 256 ? 0 : pow(Double(i) / 256, 0.45)
                        let o = (y * io.w + x) * 4
                        io.dst[o] = clamp8(Double(p2.r) + (Double(p1.r) - Double(p2.r)) * t)
                        io.dst[o + 1] = clamp8(Double(p2.g) + (Double(p1.g) - Double(p2.g)) * t)
                        io.dst[o + 2] = clamp8(Double(p2.b) + (Double(p1.b) - Double(p2.b)) * t)
                        io.dst[o + 3] = 255
                    }
                }
            },
        ]),
    ]
}

/// Round-trip premultiplied pixels through a JPEG at `quality` (0...1), keeping the alpha.
func jpegCrunch(_ src: UnsafeMutablePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>, _ w: Int, _ h: Int, quality: Double) {
    let n = w * h * 4
    guard let ctx = CGContext(data: src, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let img = ctx.makeImage() else { memcpy(dst, src, n); return }
    let data = NSMutableData()
    guard let d = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { memcpy(dst, src, n); return }
    CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(d), let s = CGImageSourceCreateWithData(data, nil),
          let back = CGImageSourceCreateImageAtIndex(s, 0, nil) else { memcpy(dst, src, n); return }
    let out = CGContext(data: dst, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.setBlendMode(.copy)
    out.draw(back, in: CGRect(x: 0, y: 0, width: w, height: h))
    // JPEG has no alpha. The encoder saw premultiplied colour (as if over black), so the decoded
    // colour is already premultiplied: restore the original alpha and keep colour within it.
    for i in stride(from: 0, to: n, by: 4) {
        let a = src[i + 3]
        dst[i + 3] = a
        dst[i] = min(dst[i], a); dst[i + 1] = min(dst[i + 1], a); dst[i + 2] = min(dst[i + 2], a)
    }
}
