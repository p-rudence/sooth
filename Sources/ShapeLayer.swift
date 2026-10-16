import AppKit

/// A shape that stays editable: shape layers keep this, so the shape can be moved, resized,
/// rotated and restyled until it is painted on, filtered, merged or flattened.
struct ShapeSpec: Equatable {
    var kind: ShapeKind
    /// The shape's box before rotation (image coordinates, y down).
    var frame: CGRect
    var angle: CGFloat = 0
    var style: FillStyle
    var width: CGFloat
    var stroke: RGBA
    var fill: RGBA
    var antialias = true

    /// Colours as Paint.NET uses them: outline and plain fill in the primary colour; "filled with
    /// outline" fills with the secondary.
    init(kind: ShapeKind, frame: CGRect, style: FillStyle, width: CGFloat, primary: RGBA, secondary: RGBA, antialias: Bool) {
        self.kind = kind; self.frame = frame; self.style = style; self.width = width
        stroke = primary
        fill = style == .both ? secondary : primary
        self.antialias = antialias
    }

    var rotation: CGAffineTransform {
        CGAffineTransform(translationX: frame.midX, y: frame.midY).rotated(by: angle).translatedBy(x: -frame.midX, y: -frame.midY)
    }

    /// Box the drawn pixels can touch.
    var extent: CGRect {
        var t = rotation
        return CGPath(rect: frame.insetBy(dx: -width, dy: -width), transform: &t).boundingBoxOfPath.integral.insetBy(dx: -2, dy: -2)
    }

    func contains(_ p: CGPoint) -> Bool { frame.insetBy(dx: -width / 2, dy: -width / 2).contains(p.applying(rotation.inverted())) }

    var session: TransformSession {
        let s = TransformSession(pixels: false, layer: 0, bounds: frame, base: nil, floating: nil, selection: nil,
                                 outline: CGPath(rect: frame, transform: nil))
        s.angle = angle
        return s
    }

    mutating func take(_ s: TransformSession) {
        let w = max(1, frame.width * abs(s.sx)), h = max(1, frame.height * abs(s.sy))
        frame = CGRect(x: s.center.x - w / 2, y: s.center.y - h / 2, width: w, height: h)
        angle = s.angle
    }

    var path: CGPath { ShapeSpec.path(kind, frame) }

    func render(into L: Layer, clearing area: CGRect? = nil) {
        let c = L.ctx, H = CGFloat(L.height)
        c.saveGState()
        if let r = area?.integral.intersection(L.rect), !r.isNull {
            let cr = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            c.clip(to: cr); c.clear(cr)
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
        c.concatenate(rotation)
        c.setShouldAntialias(antialias)
        let p = path
        if style != .outline { c.setFillColor(fill.cg); c.addPath(p); c.fillPath() }
        if style != .fill {
            c.setStrokeColor(stroke.cg); c.setLineWidth(width); c.setLineJoin(.round); c.setLineCap(.round)
            c.addPath(p); c.strokePath()
        }
        c.restoreGState()
    }

    // MARK: Paths (y down)

    static func path(_ kind: ShapeKind, _ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let (x0, y0, x1, y1, w, h) = (r.minX, r.minY, r.maxX, r.maxY, r.width, r.height)
        switch kind {
        case .rectangle:
            p.addRect(r)
        case .roundedRectangle:
            let rad = min(max(6, min(w, h) * 0.18), w / 2, h / 2)
            p.addRoundedRect(in: r, cornerWidth: rad, cornerHeight: rad)
        case .ellipse:
            p.addEllipse(in: r)
        case .triangle:
            p.addLines(between: [CGPoint(x: r.midX, y: y0), CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1)]); p.closeSubpath()
        case .diamond:
            p.addLines(between: [CGPoint(x: r.midX, y: y0), CGPoint(x: x1, y: r.midY), CGPoint(x: r.midX, y: y1), CGPoint(x: x0, y: r.midY)])
            p.closeSubpath()
        case .star:
            var pts: [CGPoint] = []
            for i in 0..<10 {
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, k: CGFloat = i % 2 == 0 ? 1 : 0.42
                pts.append(CGPoint(x: r.midX + cos(a) * w / 2 * k, y: r.midY + 0.06 * h + sin(a) * h / 2 * k * 1.05))
            }
            p.addLines(between: pts); p.closeSubpath()
        case .heart:
            let top = y0 + h * 0.3
            p.move(to: CGPoint(x: r.midX, y: y1))
            p.addCurve(to: CGPoint(x: x0, y: top), control1: CGPoint(x: r.midX - w * 0.1, y: y1 - h * 0.15), control2: CGPoint(x: x0, y: y0 + h * 0.6))
            p.addCurve(to: CGPoint(x: r.midX, y: y0 + h * 0.22), control1: CGPoint(x: x0, y: y0 - h * 0.05), control2: CGPoint(x: r.midX - w * 0.05, y: y0))
            p.addCurve(to: CGPoint(x: x1, y: top), control1: CGPoint(x: r.midX + w * 0.05, y: y0), control2: CGPoint(x: x1, y: y0 - h * 0.05))
            p.addCurve(to: CGPoint(x: r.midX, y: y1), control1: CGPoint(x: x1, y: y0 + h * 0.6), control2: CGPoint(x: r.midX + w * 0.1, y: y1 - h * 0.15))
            p.closeSubpath()
        case .arrow:
            let head = min(w * 0.45, h * 1.1), shaft = h * 0.22
            p.addLines(between: [CGPoint(x: x0, y: r.midY - shaft), CGPoint(x: x1 - head, y: r.midY - shaft), CGPoint(x: x1 - head, y: y0),
                                 CGPoint(x: x1, y: r.midY), CGPoint(x: x1 - head, y: y1), CGPoint(x: x1 - head, y: r.midY + shaft),
                                 CGPoint(x: x0, y: r.midY + shaft)])
            p.closeSubpath()
        case .bubble:
            let body = CGRect(x: x0, y: y0, width: w, height: h * 0.78)
            let rad = min(body.height * 0.45, w * 0.25)
            let tailBase = x0 + w * 0.22
            // Rounded box with a tail out of its bottom edge, as one outline.
            p.move(to: CGPoint(x: x0 + rad, y: y0))
            p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: body.maxY), radius: rad)
            p.addArc(tangent1End: CGPoint(x: x1, y: body.maxY), tangent2End: CGPoint(x: x0, y: body.maxY), radius: rad)
            p.addLine(to: CGPoint(x: tailBase + w * 0.14, y: body.maxY))
            p.addLine(to: CGPoint(x: x0 + w * 0.12, y: y1))
            p.addLine(to: CGPoint(x: tailBase, y: body.maxY))
            p.addArc(tangent1End: CGPoint(x: x0, y: body.maxY), tangent2End: CGPoint(x: x0, y: y0), radius: rad)
            p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: rad)
            p.closeSubpath()
        }
        return p
    }

    // MARK: Files

    var plist: [String: Any] {
        ["kind": kind.rawValue, "x": Double(frame.minX), "y": Double(frame.minY), "w": Double(frame.width), "h": Double(frame.height),
         "angle": Double(angle), "style": style.rawValue, "width": Double(width), "stroke": stroke.hex, "fill": fill.hex, "aa": antialias]
    }

    init?(plist d: [String: Any]) {
        guard let k = ShapeKind(rawValue: d["kind"] as? Int ?? -1) else { return nil }
        kind = k
        frame = CGRect(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0, width: d["w"] as? Double ?? 1, height: d["h"] as? Double ?? 1)
        angle = CGFloat(d["angle"] as? Double ?? 0)
        style = FillStyle(rawValue: d["style"] as? Int ?? 0) ?? .outline
        width = CGFloat(d["width"] as? Double ?? 4)
        stroke = RGBA(hex: d["stroke"] as? String ?? "000000") ?? .black
        fill = RGBA(hex: d["fill"] as? String ?? "000000") ?? .black
        antialias = d["aa"] as? Bool ?? true
    }
}
