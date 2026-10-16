import AppKit

/// Adjustments ▸ Curves: a tone curve per channel, edited with draggable points.
enum Curves {
    enum Mode: Int, CaseIterable {
        case luminosity, rgb, red, green, blue
        var title: String { ["Luminosity", "RGB", "Red", "Green", "Blue"][rawValue] }
    }

    /// Smooth curve through the points (monotone cubic, so it never overshoots), as a 256-entry table.
    static func table(_ pts: [CGPoint]) -> [UInt8] {
        let p = pts.sorted { $0.x < $1.x }
        guard p.count >= 2 else { return (0..<256).map { UInt8($0) } }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1), m = [Double](repeating: 0, count: n)
        for i in 0..<(n - 1) { d[i] = Double(p[i + 1].y - p[i].y) / max(1e-6, Double(p[i + 1].x - p[i].x)) }
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 { m[i] = 0; m[i + 1] = 0 }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        return (0..<256).map { xi in
            let x = Double(xi)
            if x <= Double(p[0].x) { return clamp8(Double(p[0].y)) }
            if x >= Double(p[n - 1].x) { return clamp8(Double(p[n - 1].y)) }
            var k = 0
            while k < n - 2 && x > Double(p[k + 1].x) { k += 1 }
            let x0 = Double(p[k].x), x1 = Double(p[k + 1].x), h = x1 - x0, t = (x - x0) / h
            let h00 = 2 * t * t * t - 3 * t * t + 1, h10 = t * t * t - 2 * t * t + t
            let h01 = -2 * t * t * t + 3 * t * t, h11 = t * t * t - t * t
            return clamp8(h00 * Double(p[k].y) + h10 * h * m[k] + h01 * Double(p[k + 1].y) + h11 * h * m[k + 1])
        }
    }

    // Settings travel as a flat list (so Repeat Last Effect works): [mode, n0, x, y…, n1, …, n2, …].
    static func encode(mode: Mode, curves: [[CGPoint]]) -> [Double] {
        var v = [Double(mode.rawValue)]
        for c in curves { v.append(Double(c.count)); for p in c { v.append(Double(p.x)); v.append(Double(p.y)) } }
        return v
    }

    static func decode(_ v: [Double]) -> (Mode, [[CGPoint]]) {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        guard let m0 = v.first, let mode = Mode(rawValue: Int(m0)) else { return (.rgb, [line, line, line]) }
        var curves: [[CGPoint]] = [], i = 1
        for _ in 0..<3 {
            guard i < v.count else { curves.append(line); continue }
            let n = Int(v[i]); i += 1
            var c: [CGPoint] = []
            for _ in 0..<n where i + 1 < v.count { c.append(CGPoint(x: v[i], y: v[i + 1])); i += 2 }
            curves.append(c.count >= 2 ? c : line)
        }
        return (mode, curves)
    }

    static let filter = Filter(name: "Curves", key: "M", rawValues: true) { io, v in
        let (mode, curves) = decode(v)
        switch mode {
        case .luminosity:
            let t = table(curves[0])
            mapStraight(io) { r, g, b, _ in
                let l = luma(r, g, b)
                let nl = Double(t[Int(clamp8(l))])
                if l < 0.5 { r = nl; g = nl; b = nl; return }
                let k = nl / l
                r *= k; g *= k; b *= k
            }
        case .rgb:
            let t = table(curves[0]); applyLUT(io, t, t, t)
        case .red, .green, .blue:
            applyLUT(io, table(curves[0]), table(curves[1]), table(curves[2]))
        }
    }
}

/// The curve graph: drag points, click to add one, drag a point off the graph to remove it.
final class CurveView: NSView {
    var points: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)] { didSet { needsDisplay = true } }
    var color: NSColor = .labelColor { didSet { needsDisplay = true } }
    var onChange: (([CGPoint]) -> Void)?
    private var dragging: Int?

    override var intrinsicContentSize: NSSize { NSSize(width: 280, height: 280) }
    private var plot: CGRect { bounds.insetBy(dx: 10, dy: 10) }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plot.minX + p.x / 255 * plot.width, y: plot.minY + p.y / 255 * plot.height)
    }
    private func toCurve(_ v: CGPoint) -> CGPoint {
        CGPoint(x: min(255, max(0, (v.x - plot.minX) / plot.width * 255)).rounded(),
                y: min(255, max(0, (v.y - plot.minY) / plot.height * 255)).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        NSColor.textBackgroundColor.setFill(); plot.fill()
        c.setStrokeColor(NSColor.separatorColor.cgColor); c.setLineWidth(1)
        for i in 1..<4 {
            let x = plot.minX + plot.width * CGFloat(i) / 4, y = plot.minY + plot.height * CGFloat(i) / 4
            c.move(to: CGPoint(x: x, y: plot.minY)); c.addLine(to: CGPoint(x: x, y: plot.maxY))
            c.move(to: CGPoint(x: plot.minX, y: y)); c.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        c.strokePath()
        c.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
        c.move(to: toView(.zero)); c.addLine(to: toView(CGPoint(x: 255, y: 255))); c.strokePath()
        let t = Curves.table(points)
        c.setStrokeColor(color.cgColor); c.setLineWidth(2)
        for x in 0..<256 {
            let v = toView(CGPoint(x: CGFloat(x), y: CGFloat(t[x])))
            if x == 0 { c.move(to: v) } else { c.addLine(to: v) }
        }
        c.strokePath()
        for p in points {
            let v = toView(p)
            let r = CGRect(x: v.x - 4.5, y: v.y - 4.5, width: 9, height: 9)
            c.setFillColor(NSColor.textBackgroundColor.cgColor); c.fillEllipse(in: r)
            c.setStrokeColor(color.cgColor); c.setLineWidth(1.5); c.strokeEllipse(in: r)
        }
        NSColor.separatorColor.setStroke(); NSBezierPath(rect: plot).stroke()
    }

    override func mouseDown(with e: NSEvent) {
        let v = convert(e.locationInWindow, from: nil)
        if let i = points.firstIndex(where: { (toView($0) - v).length < 8 }) {
            dragging = i
        } else {
            points.append(toCurve(v))
            dragging = points.count - 1
            onChange?(points)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let i = dragging else { return }
        let v = convert(e.locationInWindow, from: nil)
        let outside = !plot.insetBy(dx: -24, dy: -24).contains(v)
        if outside && points.count > 2 && i != 0 && i != points.count - 1 {
            points.remove(at: i); dragging = nil
        } else {
            var p = toCurve(v)
            // keep points in order along x, ends pinned to the edges
            let sorted = points.enumerated().sorted { $0.element.x < $1.element.x }
            if let rank = sorted.firstIndex(where: { $0.offset == i }) {
                if rank == 0 { p.x = 0 } else if rank == sorted.count - 1 { p.x = 255 }
                else { p.x = min(max(p.x, sorted[rank - 1].element.x + 1), sorted[rank + 1].element.x - 1) }
            }
            points[i] = p
        }
        onChange?(points)
    }

    override func mouseUp(with e: NSEvent) { dragging = nil }
}

extension Dialogs {
    /// The Curves dialog. Returns the settings, or nil on cancel.
    static func curves(initial: [Double]? = nil, preview: @escaping ([Double]) -> Void) -> [Double]? {
        if let v = Dialogs.testValues { preview(v); return v }
        let a = NSAlert()
        a.messageText = "Curves"
        a.informativeText = "Drag points to shape the curve. Click to add a point; drag one off the graph to remove it."
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        var mode = Curves.Mode.luminosity
        var curves = [line, line, line]
        if let initial { (mode, curves) = Curves.decode(initial) }   // editing an adjustment layer
        let view = CurveView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 280).isActive = true
        view.heightAnchor.constraint(equalToConstant: 280).isActive = true
        func channel() -> Int { switch mode { case .green: 1; case .blue: 2; default: 0 } }
        func tint() -> NSColor { switch mode { case .red: .systemRed; case .green: .systemGreen; case .blue: .systemBlue; default: .labelColor } }
        view.points = curves[channel()]; view.color = tint()
        var timer: Timer?
        let push = {
            timer?.invalidate()
            let t = Timer(timeInterval: 0.04, repeats: false) { _ in preview(Curves.encode(mode: mode, curves: curves)) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        view.onChange = { pts in curves[channel()] = pts; push() }
        let pop = popup(Curves.Mode.allCases.map(\.title), selected: mode.rawValue) { i in
            mode = Curves.Mode(rawValue: i)!
            view.points = curves[channel()]; view.color = tint(); push()
        }
        pop.controlSize = .regular
        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.onAction { _ in curves[channel()] = line; view.points = line; push() }
        let top = NSStackView(views: [pop, reset])
        let stack = NSStackView(views: [top, view])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 290, height: 320))
        a.accessoryView = stack
        let r = a.runModal()
        timer?.invalidate()
        return r == .alertFirstButtonReturn ? Curves.encode(mode: mode, curves: curves) : nil
    }
}
