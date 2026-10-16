import AppKit

/// Which part of a transform box the pointer is over.
enum Handle: Equatable {
    case move, rotate
    /// Scale handle: (-1, 0, 1) on each axis says which corner or edge.
    case scale(Int, Int)
}

/// A move / scale / rotate session for Move Selected Pixels (pixels) or Move Selection (outline).
/// Everything is resampled from the originals each time, so repeated drags never soften the image.
final class TransformSession {
    let pixels: Bool
    let layer: Int
    /// Original bounds of what is being transformed (image coordinates, y down).
    let bounds: CGRect
    /// Layer pixels before the session; replaced when ⌥ stamps a copy.
    var base: Data?
    /// Original selected pixels, cropped to `bounds`.
    let floating: CGImage?
    let selection: Selection?
    let outline: CGPath
    /// Whether the original area is cleared (false after ⌥ leaves a copy behind).
    var clearOriginal = true
    /// Whether it moves the layer's mask rather than its pixels (switching ends the session).
    var onMask = false
    /// Document revision this session last committed at; anything else means it is stale.
    var revision = -1
    var lastExtent: CGRect

    var center: CGPoint
    var sx: CGFloat = 1, sy: CGFloat = 1, angle: CGFloat = 0

    init(pixels: Bool, layer: Int, bounds: CGRect, base: Data?, floating: CGImage?, selection: Selection?, outline: CGPath) {
        self.pixels = pixels; self.layer = layer; self.bounds = bounds
        self.base = base; self.floating = floating; self.selection = selection; self.outline = outline
        center = CGPoint(x: bounds.midX, y: bounds.midY)
        lastExtent = bounds
    }

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle).scaledBy(x: sx, y: sy)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
    }

    /// Pure whole-pixel translation: drawn and offset exactly, with no resampling.
    var isPureMove: Bool {
        sx == 1 && sy == 1 && angle == 0
            && (center.x - bounds.midX).rounded() == center.x - bounds.midX
            && (center.y - bounds.midY).rounded() == center.y - bounds.midY
    }

    var offset: (Int, Int) { (Int((center.x - bounds.midX).rounded()), Int((center.y - bounds.midY).rounded())) }

    func point(_ ux: Int, _ uy: Int) -> CGPoint {
        CGPoint(x: bounds.midX + CGFloat(ux) * bounds.width / 2, y: bounds.midY + CGFloat(uy) * bounds.height / 2).applying(transform)
    }

    var quad: CGPath {
        let p = CGMutablePath()
        p.addLines(between: [point(-1, -1), point(1, -1), point(1, 1), point(-1, 1)])
        p.closeSubpath()
        return p
    }

    /// Axis-aligned box around the transformed area.
    var extent: CGRect { bounds.applying(transform).integral.insetBy(dx: -2, dy: -2) }

    static let handles: [(Int, Int)] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]

    /// Handles first, then inside the box (move), then a ring just outside it (rotate); farther out moves.
    func hit(_ p: CGPoint, radius r0: CGFloat, ring: CGFloat) -> Handle {
        // On a small box (or far zoomed out) the handles would cover all of it; keep the middle grabbable.
        let r = min(r0, max(1, min(abs(sx * bounds.width), abs(sy * bounds.height)) / 4))
        for (ux, uy) in Self.handles where (point(ux, uy) - p).length <= r { return .scale(ux, uy) }
        let local = p.applying(transform.inverted())
        if bounds.insetBy(dx: -1, dy: -1).contains(local) { return .move }
        let dx = max(bounds.minX - local.x, 0, local.x - bounds.maxX) * abs(sx)
        let dy = max(bounds.minY - local.y, 0, local.y - bounds.maxY) * abs(sy)
        return hypot(dx, dy) <= ring ? .rotate : .move
    }

    /// The selection after this transform, rasterised from the original mask.
    func transformedSelection(width w: Int, height h: Int) -> Selection? {
        guard let sel = selection else { return nil }
        if isPureMove { let (dx, dy) = offset; return sel.offset(dx, dy) }
        var m = [UInt8](repeating: 0, count: w * h)
        m.withUnsafeMutableBytes { raw in
            let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c.interpolationQuality = .high
            c.translateBy(x: 0, y: CGFloat(h)); c.scaleBy(x: 1, y: -1)
            c.concatenate(transform)
            c.translateBy(x: 0, y: CGFloat(sel.height)); c.scaleBy(x: 1, y: -1)
            c.draw(sel.image, in: CGRect(x: 0, y: 0, width: sel.width, height: sel.height))
        }
        var t = transform
        return Selection(width: w, height: h, mask: m, hint: outline.copy(using: &t))
    }
}

/// Live state of a handle drag.
struct TransformDrag {
    let handle: Handle
    let start: CGPoint
    let center: CGPoint, sx: CGFloat, sy: CGFloat, angle: CGFloat

    func apply(to s: TransformSession, at p: CGPoint, shift: Bool) {
        switch handle {
        case .move:
            let d = p - start
            s.center = CGPoint(x: center.x + d.x.rounded(), y: center.y + d.y.rounded())
        case .rotate:
            var a = angle + atan2(p.y - center.y, p.x - center.x) - atan2(start.y - center.y, start.x - center.x)
            if shift { let k = CGFloat.pi / 12; a = (a / k).rounded() * k }
            s.angle = a
        case .scale(let ux, let uy):
            let (c, sn) = (cos(angle), sin(angle))
            let v = p - center
            let m = CGPoint(x: v.x * c + v.y * sn, y: -v.x * sn + v.y * c)   // pointer in the box's own frame
            let bw = s.bounds.width, bh = s.bounds.height
            let ox = -CGFloat(ux) * bw * sx / 2, oy = -CGFloat(uy) * bh * sy / 2   // the opposite, fixed edge
            var nsx = sx, nsy = sy
            if ux != 0 { nsx = max(1 / bw, (m.x - ox) * CGFloat(ux) / bw) }
            if uy != 0 { nsy = max(1 / bh, (m.y - oy) * CGFloat(uy) / bh) }
            if shift && ux != 0 && uy != 0 { let k = max(nsx / sx, nsy / sy); nsx = sx * k; nsy = sy * k }
            let lx = ux == 0 ? 0 : ox + CGFloat(ux) * nsx * bw / 2
            let ly = uy == 0 ? 0 : oy + CGFloat(uy) * nsy * bh / 2
            s.center = CGPoint(x: center.x + lx * c - ly * sn, y: center.y + lx * sn + ly * c)
            s.sx = nsx; s.sy = nsy
        }
    }
}

// MARK: - Cursors

enum Cursors {
    private static func make(_ draw: @escaping (CGContext) -> Void, hot: NSPoint) -> NSCursor {
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { _ in
            if let c = NSGraphicsContext.current?.cgContext { draw(c) }
            return true
        }
        return NSCursor(image: img, hotSpot: hot)
    }

    private static func arrow(_ c: CGContext) {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 3, y: 2), CGPoint(x: 3, y: 19), CGPoint(x: 7.5, y: 15), CGPoint(x: 10.5, y: 21.5),
                             CGPoint(x: 13, y: 20.5), CGPoint(x: 10.2, y: 14), CGPoint(x: 16, y: 14)])
        p.closeSubpath()
        c.addPath(p); c.setFillColor(.black); c.fillPath()
        c.addPath(p); c.setStrokeColor(.white); c.setLineWidth(1.4); c.setLineJoin(.round); c.strokePath()
    }

    /// Arrow with a small checkered square: moves the pixels.
    static let movePixels: NSCursor = make({ c in
        arrow(c)
        let r = CGRect(x: 15.5, y: 18.5, width: 11, height: 11)
        c.setFillColor(.white); c.fill(r.insetBy(dx: -1.5, dy: -1.5))
        for i in 0..<3 { for j in 0..<3 where (i + j) % 2 == 0 {
            c.setFillColor(CGColor(gray: 0.15, alpha: 1))
            c.fill(CGRect(x: r.minX + CGFloat(i) * 11 / 3, y: r.minY + CGFloat(j) * 11 / 3, width: 11 / 3, height: 11 / 3))
        } }
        c.setStrokeColor(.black); c.setLineWidth(1); c.stroke(r)
    }, hot: NSPoint(x: 3, y: 2))

    /// Arrow with a dashed square: moves only the selection outline.
    static let moveSelection: NSCursor = make({ c in
        arrow(c)
        let r = CGRect(x: 15.5, y: 18.5, width: 11, height: 11)
        c.setFillColor(.white); c.fill(r.insetBy(dx: -1.5, dy: -1.5))
        c.setStrokeColor(.black); c.setLineWidth(1.2); c.setLineDash(phase: 0, lengths: [2.2, 1.8]); c.stroke(r)
    }, hot: NSPoint(x: 3, y: 2))

    static let rotate: NSCursor = make({ c in
        func shape() {
            c.addArc(center: CGPoint(x: 16, y: 16), radius: 8, startAngle: .pi * 0.15, endAngle: .pi * 1.6, clockwise: false)
        }
        for (w, col) in [(4.5, CGColor.white), (2.0, CGColor.black)] {
            shape(); c.setStrokeColor(col); c.setLineWidth(w); c.setLineCap(.round); c.strokePath()
        }
        let tip = CGMutablePath()
        tip.addLines(between: [CGPoint(x: 15, y: 3.5), CGPoint(x: 22.5, y: 7.5), CGPoint(x: 15.5, y: 11.5)])
        tip.closeSubpath()
        c.addPath(tip); c.setFillColor(.black); c.fillPath()
        c.addPath(tip); c.setStrokeColor(.white); c.setLineWidth(1); c.strokePath()
    }, hot: NSPoint(x: 16, y: 16))

    /// Palette icon: a pointer with a pixel badge (Move Selected Pixels) or a dashed box (Move Selection).
    static func toolIcon(pixels: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 2, y: 1), CGPoint(x: 2, y: 13.5), CGPoint(x: 5.2, y: 10.6), CGPoint(x: 7.4, y: 15.2),
                                 CGPoint(x: 9.2, y: 14.4), CGPoint(x: 7.2, y: 9.9), CGPoint(x: 11.4, y: 9.9)])
            p.closeSubpath()
            c.addPath(p); c.setFillColor(.black); c.fillPath()
            let r = CGRect(x: 10.5, y: 11.5, width: 8, height: 8)
            if pixels {
                for i in 0..<2 { for j in 0..<2 where (i + j) % 2 == 0 {
                    c.fill(CGRect(x: r.minX + CGFloat(i) * 4, y: r.minY + CGFloat(j) * 4, width: 4, height: 4))
                } }
                c.setStrokeColor(.black); c.setLineWidth(1); c.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            } else {
                c.setStrokeColor(.black); c.setLineWidth(1.2); c.setLineDash(phase: 0, lengths: [2, 1.5])
                c.stroke(r.insetBy(dx: 0.6, dy: 0.6))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Two-headed resize arrow along `angle` (radians, image space).
    static func resize(angle: CGFloat) -> NSCursor {
        make({ c in
            c.translateBy(x: 16, y: 16); c.rotate(by: angle)
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: -11, y: 0), CGPoint(x: -5, y: -5.5), CGPoint(x: -5, y: -2), CGPoint(x: 5, y: -2),
                                 CGPoint(x: 5, y: -5.5), CGPoint(x: 11, y: 0), CGPoint(x: 5, y: 5.5), CGPoint(x: 5, y: 2),
                                 CGPoint(x: -5, y: 2), CGPoint(x: -5, y: 5.5)])
            p.closeSubpath()
            c.addPath(p); c.setFillColor(.black); c.fillPath()
            c.addPath(p); c.setStrokeColor(.white); c.setLineWidth(1.3); c.setLineJoin(.round); c.strokePath()
        }, hot: NSPoint(x: 16, y: 16))
    }
}
