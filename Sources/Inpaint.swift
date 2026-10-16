import Foundation
import Accelerate

/// Content-aware fill: fills a hole with texture found elsewhere in the picture, using multi-scale
/// PatchMatch (Barnes et al. 2009) with the expectation-maximisation reconstruction of Wexler et
/// al. (2007). Native, on-device, all cores.
enum Inpaint {
    private static let r = 3                 // patch radius (7×7 patches)

    /// Planar float image with a hole mask (true = unknown).
    private struct Img {
        let w: Int, h: Int
        var c: [Float]                       // RGBA straight, 0...255, interleaved
        var hole: [Bool]
        func idx(_ x: Int, _ y: Int) -> Int { y * w + x }
    }

    /// Fill `mask` (> 127 = fill) in premultiplied RGBA pixels `px` (w × h), in place.
    static func fill(_ px: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int, mask: [UInt8]) {
        // Work on the hole's neighbourhood only.
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where mask[y * w + x] > 127 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= 0 else { return }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        let margin = max(48, Int(Double(max(bw, bh)) * 0.6))
        let rx0 = max(0, x0 - margin), ry0 = max(0, y0 - margin)
        let rx1 = min(w - 1, x1 + margin), ry1 = min(h - 1, y1 + margin)
        let RW = rx1 - rx0 + 1, RH = ry1 - ry0 + 1
        var base = Img(w: RW, h: RH, c: [Float](repeating: 0, count: RW * RH * 4), hole: [Bool](repeating: false, count: RW * RH))
        for y in 0..<RH { for x in 0..<RW {
            let sx = x + rx0, sy = y + ry0, i = (sy * w + sx) * 4, a = px[i + 3]
            let o = (y * RW + x) * 4
            base.c[o] = Float(unpremul(px[i], a)); base.c[o + 1] = Float(unpremul(px[i + 1], a))
            base.c[o + 2] = Float(unpremul(px[i + 2], a)); base.c[o + 3] = Float(a)
            base.hole[y * RW + x] = mask[sy * w + sx] > 127
        } }
        // Too little known texture to borrow from: fall back to a smooth fill.
        let known = base.hole.filter { !$0 }.count
        let result: Img
        if known < 200 { result = diffuse(base) } else { result = solve(base) }
        // Write the filled pixels back, blending soft mask edges.
        for y in 0..<RH { for x in 0..<RW {
            let sx = x + rx0, sy = y + ry0, m = Int(mask[sy * w + sx])
            guard m > 0 else { continue }
            let o = (y * RW + x) * 4, i = (sy * w + sx) * 4
            let a = Int(clamp8(Double(result.c[o + 3])))
            let nr = premul(Int(clamp8(Double(result.c[o]))), a), ng = premul(Int(clamp8(Double(result.c[o + 1]))), a)
            let nb = premul(Int(clamp8(Double(result.c[o + 2]))), a)
            px[i] = UInt8((Int(px[i]) * (255 - m) + Int(nr) * m) / 255)
            px[i + 1] = UInt8((Int(px[i + 1]) * (255 - m) + Int(ng) * m) / 255)
            px[i + 2] = UInt8((Int(px[i + 2]) * (255 - m) + Int(nb) * m) / 255)
            px[i + 3] = UInt8((Int(px[i + 3]) * (255 - m) + a * m) / 255)
        } }
    }

    /// Grow a mask by `n` pixels (max filter).
    static func dilate(_ m: [UInt8], width w: Int, height h: Int, by n: Int) -> [UInt8] {
        var src = m, out = m
        let k = vImagePixelCount(n * 2 + 1)
        src.withUnsafeMutableBytes { s in out.withUnsafeMutableBytes { d in
            var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            vImageMax_Planar8(&sb, &db, nil, 0, 0, k, k, vImage_Flags(kvImageEdgeExtend))
        } }
        return out
    }

    // MARK: Pyramid

    private static func down(_ im: Img) -> Img {
        let w = (im.w + 1) / 2, h = (im.h + 1) / 2
        var o = Img(w: w, h: h, c: [Float](repeating: 0, count: w * h * 4), hole: [Bool](repeating: false, count: w * h))
        for y in 0..<h { for x in 0..<w {
            var s: (Float, Float, Float, Float) = (0, 0, 0, 0), n: Float = 0, anyHole = false
            for dy in 0..<2 { for dx in 0..<2 {
                let sx = min(im.w - 1, x * 2 + dx), sy = min(im.h - 1, y * 2 + dy), j = im.idx(sx, sy)
                if im.hole[j] { anyHole = true; continue }
                s.0 += im.c[j * 4]; s.1 += im.c[j * 4 + 1]; s.2 += im.c[j * 4 + 2]; s.3 += im.c[j * 4 + 3]; n += 1
            } }
            let i = y * w + x
            o.hole[i] = anyHole
            if n > 0 { o.c[i * 4] = s.0 / n; o.c[i * 4 + 1] = s.1 / n; o.c[i * 4 + 2] = s.2 / n; o.c[i * 4 + 3] = s.3 / n }
        } }
        return o
    }

    /// Fill holes by repeatedly averaging known neighbours (onion peel).
    private static func diffuse(_ im0: Img) -> Img {
        var im = im0
        var unknown = im.hole
        var remaining = unknown.filter { $0 }.count
        while remaining > 0 {
            var next = unknown, filled = 0
            for y in 0..<im.h { for x in 0..<im.w where unknown[im.idx(x, y)] {
                var s: (Float, Float, Float, Float) = (0, 0, 0, 0), n: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < im.w, yy < im.h, !unknown[im.idx(xx, yy)] else { continue }
                    let j = im.idx(xx, yy) * 4
                    s.0 += im.c[j]; s.1 += im.c[j + 1]; s.2 += im.c[j + 2]; s.3 += im.c[j + 3]; n += 1
                }
                if n > 0 {
                    let i = im.idx(x, y) * 4
                    im.c[i] = s.0 / n; im.c[i + 1] = s.1 / n; im.c[i + 2] = s.2 / n; im.c[i + 3] = s.3 / n
                    next[im.idx(x, y)] = false; filled += 1
                }
            } }
            unknown = next
            remaining -= filled
            if filled == 0 { break }
        }
        return im
    }

    // MARK: PatchMatch

    /// Size of the hole's bounding box at a level.
    private static func holeSize(_ im: Img) -> Int {
        var x0 = im.w, y0 = im.h, x1 = -1, y1 = -1
        for y in 0..<im.h { for x in 0..<im.w where im.hole[im.idx(x, y)] {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return x1 < 0 ? 0 : max(x1 - x0 + 1, y1 - y0 + 1)
    }

    private static func solve(_ fine: Img) -> Img {
        var levels = [fine]
        // Go coarse until the hole is only a few patches across.
        while let last = levels.last, holeSize(last) > 4 * r, max(last.w, last.h) > 32, levels.count < 10 {
            let d = down(last)
            // keep enough room around the hole for whole patches of real texture
            if d.hole.filter({ !$0 }).count < 300 || min(d.w, d.h) < 6 * r + 6 || !validSources(d).contains(true) { break }
            levels.append(d)
        }
        var nnf: [Int32] = []   // per pixel: source pixel index (into the same level)
        var cur = onionPeel(levels.last!, nnf: &nnf)
        for li in stride(from: levels.count - 1, through: 0, by: -1) {
            let L = levels[li]
            if li != levels.count - 1 {
                // upsample the previous result into the hole, keep known pixels
                var up = L
                for y in 0..<L.h { for x in 0..<L.w where L.hole[L.idx(x, y)] {
                    let px = min(cur.w - 1, x / 2), py = min(cur.h - 1, y / 2), j = cur.idx(px, py) * 4, i = L.idx(x, y) * 4
                    for k in 0..<4 { up.c[i + k] = cur.c[j + k] }
                } }
                let pw = cur.w, ph = cur.h
                let prev = nnf.count == pw * ph ? nnf : [Int32](repeating: -1, count: pw * ph)
                nnf = [Int32](repeating: -1, count: L.w * L.h)
                for y in 0..<L.h { for x in 0..<L.w {
                    let px = min(pw - 1, x / 2), py = min(ph - 1, y / 2), s = Int(prev[py * pw + px])
                    if s >= 0 {
                        let sx = min(L.w - 1, (s % pw) * 2 + (x & 1)), sy = min(L.h - 1, (s / pw) * 2 + (y & 1))
                        nnf[y * L.w + x] = Int32(sy * L.w + sx)
                    }
                } }
                cur = up
            }
            cur = em(L, start: cur, nnf: &nnf, iterations: li == 0 ? 4 : 5, sharpen: li == 0)
            if let d = ProcessInfo.processInfo.environment["EASEL_INPAINT_DEBUG"] { dump(cur, "\(d)/level\(li).png") }   // developer aid
        }
        return cur
    }

    private static func dump(_ im: Img, _ path: String) {
        let l = Layer(width: im.w, height: im.h, name: "")
        for p in 0..<(im.w * im.h) {
            let a = Int(clamp8(Double(im.c[p * 4 + 3])))
            l.bytes[p * 4] = premul(Int(clamp8(Double(im.c[p * 4]))), a); l.bytes[p * 4 + 1] = premul(Int(clamp8(Double(im.c[p * 4 + 1]))), a)
            l.bytes[p * 4 + 2] = premul(Int(clamp8(Double(im.c[p * 4 + 2]))), a); l.bytes[p * 4 + 3] = UInt8(a)
        }
        try? Document.encode(l.image(), as: .png).write(to: URL(fileURLWithPath: path))
    }

    /// Coarsest level: fill the hole ring by ring from its edge inward, each pixel copied from the
    /// source patch that best matches its already-known neighbourhood (only known pixels count).
    private static func onionPeel(_ L: Img, nnf: inout [Int32]) -> Img {
        let w = L.w, h = L.h
        let valid = validSources(L)
        let sources = (0..<(w * h)).filter { valid[$0] }
        guard !sources.isEmpty else { return diffuse(L) }
        var img = L
        var known = L.hole.map { !$0 }
        nnf = [Int32](repeating: -1, count: w * h)
        var remaining = L.hole.filter { $0 }.count
        while remaining > 0 {
            var ring: [Int] = []
            for y in 0..<h { for x in 0..<w where !known[y * w + x] {
                var edge = false
                for dy in -1...1 { for dx in -1...1 {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < w, yy < h, known[yy * w + xx] { edge = true }
                } }
                if edge { ring.append(y * w + x) }
            } }
            if ring.isEmpty { break }
            var fills: [(Int, Int)] = []
            for t in ring {
                let tx = t % w, ty = t / w
                var best = sources[0], bd = Float.infinity
                for s in sources {
                    let sx = s % w, sy = s / w
                    var d: Float = 0, n: Float = 0
                    for dy in -r...r {
                        let yy = ty + dy
                        if yy < 0 || yy >= h { continue }
                        for dx in -r...r {
                            let xx = tx + dx
                            if xx < 0 || xx >= w || !known[yy * w + xx] { continue }
                            let a = (yy * w + xx) * 4, b = ((sy + dy) * w + sx + dx) * 4
                            let e0 = img.c[a] - L.c[b], e1 = img.c[a + 1] - L.c[b + 1], e2 = img.c[a + 2] - L.c[b + 2]
                            d += e0 * e0 + e1 * e1 + e2 * e2; n += 1
                        }
                        if d > bd * 49 { break }
                    }
                    let ddx = Float(tx - sx), ddy = Float(ty - sy)
                    let score = d / max(1, n) + Float(1800) * (ddx * ddx + ddy * ddy) / Float(w * w + h * h)
                    if score < bd { bd = score; best = s }
                }
                fills.append((t, best))
            }
            for (t, s) in fills {
                for k in 0..<4 { img.c[t * 4 + k] = L.c[s * 4 + k] }
                known[t] = true
                nnf[t] = Int32(s)
            }
            remaining -= ring.count
        }
        return img
    }

    /// Valid patch centres: the whole patch is known and inside the image.
    private static func validSources(_ L: Img) -> [Bool] {
        var v = [Bool](repeating: false, count: L.w * L.h)
        for y in r..<max(r, L.h - r) { for x in r..<max(r, L.w - r) {
            var ok = true
            outer: for dy in -r...r { for dx in -r...r where L.hole[L.idx(x + dx, y + dy)] { ok = false; break outer } }
            v[L.idx(x, y)] = ok
        } }
        return v
    }

    private static func em(_ L: Img, start: Img, nnf: inout [Int32], iterations: Int, sharpen: Bool = false) -> Img {
        let w = L.w, h = L.h
        let valid = validSources(L)
        let sources = (0..<(w * h)).filter { valid[$0] }
        guard !sources.isEmpty else { return diffuse(L) }
        // Targets: patch centres whose patch touches the hole.
        var touches = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where L.hole[L.idx(x, y)] {
            for dy in -r...r { for dx in -r...r {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < w, yy < h { touches[yy * w + xx] = true }
            } }
        } }
        if nnf.count != w * h { nnf = [Int32](repeating: -1, count: w * h) }
        var rng = RNG(12345)
        for i in 0..<(w * h) where touches[i] {
            let s = Int(nnf[i])
            if s < 0 || !valid[s] { nnf[i] = Int32(sources[Int(rng.next() % UInt64(sources.count))]) }
        }
        var img = start
        var dist = [Float](repeating: .infinity, count: w * h)
        let spatial = Float(1800) / Float(w * w + h * h)

        func patchDist(_ t: Int, _ s: Int, _ best: Float) -> Float {
            let tx = t % w, ty = t / w, sx = s % w, sy = s / w
            var d: Float = 0, n: Float = 0
            for dy in -r...r {
                let ty2 = ty + dy, sy2 = sy + dy
                if ty2 < 0 || ty2 >= h { continue }
                for dx in -r...r {
                    let tx2 = tx + dx
                    if tx2 < 0 || tx2 >= w { continue }
                    let a = (ty2 * w + tx2) * 4, b = (sy2 * w + sx + dx) * 4
                    let e0 = img.c[a] - L.c[b], e1 = img.c[a + 1] - L.c[b + 1], e2 = img.c[a + 2] - L.c[b + 2], e3 = img.c[a + 3] - L.c[b + 3]
                    d += e0 * e0 + e1 * e1 + e2 * e2 + e3 * e3 * 0.5
                    n += 1
                }
                if d > best * n * 1.2 && best.isFinite { return .infinity }
            }
            // Prefer nearby texture: a far source has to match clearly better to win.
            let ddx = Float(tx - sx), ddy = Float(ty - sy)
            return d / max(1, n) + spatial * (ddx * ddx + ddy * ddy)
        }

        for it in 0..<iterations {
            for i in 0..<(w * h) where touches[i] { dist[i] = patchDist(i, Int(nnf[i]), .infinity) }
            // PatchMatch: propagation and random search, alternating scan direction.
            for pass in 0..<2 {
                let forward = (it + pass) % 2 == 0
                let ys = forward ? Array(0..<h) : Array((0..<h).reversed())
                let xs = forward ? Array(0..<w) : Array((0..<w).reversed())
                let step = forward ? -1 : 1
                for y in ys { for x in xs {
                    let i = y * w + x
                    guard touches[i] else { continue }
                    var best = Int(nnf[i]), bd = dist[i]
                    func tryCand(_ s: Int) {
                        guard s >= 0, s < w * h, valid[s], s != best else { return }
                        let d = patchDist(i, s, bd)
                        if d < bd { bd = d; best = s }
                    }
                    // neighbours' matches, shifted back
                    let nx = x + step, ny = y + step
                    if nx >= 0, nx < w, touches[y * w + nx] { tryCand(Int(nnf[y * w + nx]) - step) }
                    if ny >= 0, ny < h, touches[ny * w + x] { tryCand(Int(nnf[ny * w + x]) - step * w) }
                    // random search around the current best, shrinking
                    var rad = max(w, h)
                    while rad >= 1 {
                        let bx = best % w, by = best / w
                        let cx = bx + Int(rng.next() % UInt64(2 * rad + 1)) - rad
                        let cy = by + Int(rng.next() % UInt64(2 * rad + 1)) - rad
                        if cx >= 0, cy >= 0, cx < w, cy < h { tryCand(cy * w + cx) }
                        rad /= 2
                    }
                    nnf[i] = Int32(best); dist[i] = bd
                } }
            }
            // Vote: every hole pixel takes the weighted mean of what overlapping patches say.
            var finite = dist.enumerated().filter { touches[$0.offset] && $0.element.isFinite }.map(\.element)
            finite.sort()
            let sigma2 = max(1, finite.isEmpty ? 1 : finite[finite.count * 3 / 4]) * 2
            var acc = [Float](repeating: 0, count: w * h * 4), wsum = [Float](repeating: 0, count: w * h)
            for t in 0..<(w * h) where touches[t] {
                let s = Int(nnf[t]), tx = t % w, ty = t / w, sx = s % w, sy = s / w
                let wt = exp(-dist[t] / sigma2)
                for dy in -r...r {
                    let yy = ty + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -r...r {
                        let xx = tx + dx
                        if xx < 0 || xx >= w { continue }
                        let p = yy * w + xx
                        guard L.hole[p] else { continue }
                        let b = ((sy + dy) * w + sx + dx) * 4
                        acc[p * 4] += L.c[b] * wt; acc[p * 4 + 1] += L.c[b + 1] * wt
                        acc[p * 4 + 2] += L.c[b + 2] * wt; acc[p * 4 + 3] += L.c[b + 3] * wt
                        wsum[p] += wt
                    }
                }
            }
            for p in 0..<(w * h) where L.hole[p] && wsum[p] > 0 {
                for k in 0..<4 { img.c[p * 4 + k] = acc[p * 4 + k] / wsum[p] }
            }
        }
        if sharpen {
            // Last pass at full size: each pixel takes the colour its best-matching patch says,
            // instead of an average, so real texture (grain, waves, foliage) comes back.
            var bestD = [Float](repeating: .infinity, count: w * h)
            var out = img
            for t in 0..<(w * h) where touches[t] {
                let s = Int(nnf[t]), tx = t % w, ty = t / w, sx = s % w, sy = s / w, d = dist[t]
                for dy in -1...1 {
                    let yy = ty + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = tx + dx
                        if xx < 0 || xx >= w { continue }
                        let p = yy * w + xx
                        guard L.hole[p], d < bestD[p] else { continue }
                        bestD[p] = d
                        let b = ((sy + dy) * w + sx + dx) * 4
                        for k in 0..<4 { out.c[p * 4 + k] = L.c[b + k] }
                    }
                }
            }
            // keep a little of the smooth estimate to soften seams between copied pieces
            for p in 0..<(w * h) where L.hole[p] {
                for k in 0..<4 { out.c[p * 4 + k] = out.c[p * 4 + k] * 0.8 + img.c[p * 4 + k] * 0.2 }
            }
            return out
        }
        return img
    }
}
