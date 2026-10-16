import Foundation
import CoreGraphics

/// A dab-based stroke for the Paintbrush and Eraser. Round dabs with a hardness falloff are
/// stamped along the pointer path into a coverage mask (max-combined, so a stroke never builds
/// up past its opacity), and the mask is composited over the pixels as they were before the
/// stroke. Each pointer event only touches the area of its new dabs.
final class BrushStroke {
    let w: Int, h: Int
    let snap: Data
    private var mask: [UInt8]
    private let color: RGBA
    private let erase: Bool
    private let opacity: Int          // 0...255
    private let hardness: CGFloat
    private let antialias: Bool
    private let selection: [UInt8]?
    private var last: CGPoint?
    private var lastSize: CGFloat = 1
    private var carry: CGFloat = 0

    init(layer L: Layer, color: RGBA, erase: Bool, opacity: CGFloat, hardness: CGFloat, antialias: Bool, selection: Selection?) {
        w = L.width; h = L.height
        snap = L.data()
        if erase { L.touch() }   // the layer may stop being opaque: let the canvas know at once
        mask = [UInt8](repeating: 0, count: w * h)
        self.color = color; self.erase = erase
        self.opacity = Int((max(0, min(1, opacity)) * 255).rounded())
        self.hardness = max(0, min(1, hardness))
        self.antialias = antialias
        self.selection = selection?.mask
    }

    /// Extend the stroke to `p` with brush diameter `size`. Returns the image rect that changed.
    @discardableResult
    func add(_ p: CGPoint, size: CGFloat, into L: Layer) -> CGRect {
        // The stroke's saved pixels are for a layer of this size; never write a resized one with them.
        guard L.width == w, L.height == h else { return .zero }
        var dirty = CGRect.null
        guard let a = last else {
            dirty = dab(p, size)
            last = p; lastSize = size
            composite(into: L, dirty)
            return dirty
        }
        let d = p - a
        let len = d.length
        // Close spacing keeps max-combined edges smooth; small brushes step at most a pixel.
        let step = max(0.35, min(1, lastSize * 0.08), min(size, lastSize) * (hardness > 0.9 ? 0.07 : 0.12))
        var t = step - carry
        while t <= len {
            let f = len == 0 ? 1 : t / len
            dirty = dirty.union(dab(a + d * f, lastSize + (size - lastSize) * f))
            t += step
        }
        carry = len - (t - step)
        last = p; lastSize = size
        if !dirty.isNull { composite(into: L, dirty) }
        return dirty
    }

    private func dab(_ c: CGPoint, _ diameter: CGFloat) -> CGRect {
        let r = max(0.5, diameter / 2)
        let x0 = max(0, Int(floor(c.x - r - 1))), x1 = min(w - 1, Int(ceil(c.x + r + 1)))
        let y0 = max(0, Int(floor(c.y - r - 1))), y1 = min(h - 1, Int(ceil(c.y + r + 1)))
        guard x0 <= x1, y0 <= y1 else { return .null }
        let inner = r * hardness
        let soft = max(1, r - inner)
        let hard = hardness >= 0.99
        mask.withUnsafeMutableBufferPointer { m in
            for y in y0...y1 {
                let dy = CGFloat(y) + 0.5 - c.y
                let row = y * w
                for x in x0...x1 {
                    let dx = CGFloat(x) + 0.5 - c.x
                    let dist = (dx * dx + dy * dy).squareRoot()
                    var cov: CGFloat
                    if !antialias {
                        cov = dist <= r ? 1 : 0
                    } else {
                        cov = min(1, max(0, r + 0.5 - dist))
                        if !hard && dist > inner {
                            let t = min(1, (dist - inner) / soft)
                            cov *= 1 - t * t * (3 - 2 * t)
                        }
                    }
                    if cov <= 0 { continue }
                    let v = UInt8(cov * 255 + 0.5)
                    if v > m[row + x] { m[row + x] = v }
                }
            }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// Recompute `r` of the layer from the pre-stroke pixels and the mask.
    private func composite(into L: Layer, _ r: CGRect) {
        let x0 = Int(r.minX), x1 = Int(r.maxX), y0 = Int(r.minY), y1 = Int(r.maxY)
        let cr = Int(color.r), cg = Int(color.g), cb = Int(color.b), ca = Int(color.a)
        let dst = L.bytes
        snap.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            mask.withUnsafeBufferPointer { m in
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let p = y * w + x
                        let i = p * 4
                        var k = Int(m[p]) * opacity / 255
                        if let s = selection { k = k * Int(s[p]) / 255 }
                        if k == 0 {
                            dst[i] = src[i]; dst[i + 1] = src[i + 1]; dst[i + 2] = src[i + 2]; dst[i + 3] = src[i + 3]
                            continue
                        }
                        if erase {
                            let keep = 255 - k
                            for c in 0..<4 { dst[i + c] = UInt8((Int(src[i + c]) * keep + 127) / 255) }
                        } else {
                            let a = ca * k / 255           // source alpha
                            let inv = 255 - a
                            dst[i] = UInt8((cr * a + Int(src[i]) * inv + 127) / 255)
                            dst[i + 1] = UInt8((cg * a + Int(src[i + 1]) * inv + 127) / 255)
                            dst[i + 2] = UInt8((cb * a + Int(src[i + 2]) * inv + 127) / 255)
                            dst[i + 3] = UInt8(a + (Int(src[i + 3]) * inv + 127) / 255)
                        }
                    }
                }
            }
        }
    }
}
