import AppKit

struct HSV: Equatable {
    var h: Double   // 0..<360
    var s: Double   // 0...1
    var v: Double   // 0...1

    init(h: Double, s: Double, v: Double) { self.h = h; self.s = s; self.v = v }

    init(_ c: RGBA) {
        let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        v = mx
        s = mx == 0 ? 0 : d / mx
        if d == 0 { h = 0 }
        else if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
        if h < 0 { h += 360 }
    }

    func rgba(alpha: UInt8) -> RGBA {
        let c = v * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return RGBA(r: clamp8((r + m) * 255), g: clamp8((g + m) * 255), b: clamp8((b + m) * 255), a: alpha)
    }
}

/// Hue around the rim, saturation outward from the centre, dimmed by value.
final class ColorWheelView: NSView {
    var hsv = HSV(h: 0, s: 0, v: 1) { didSet { needsDisplay = true } }
    var onChange: ((HSV) -> Void)?

    private static let wheel: CGImage = {
        let n = 360
        let l = Layer(width: n, height: n, name: "")
        let c = CGFloat(n) / 2
        for y in 0..<n {
            for x in 0..<n {
                let dx = CGFloat(x) + 0.5 - c, dy = CGFloat(y) + 0.5 - c
                let r = (dx * dx + dy * dy).squareRoot() / c
                guard r <= 1.004 else { continue }
                var h = atan2(-dy, dx) * 180 / .pi
                if h < 0 { h += 360 }
                let rgb = HSV(h: Double(h), s: Double(min(1, r)), v: 1).rgba(alpha: 255)
                let a = Int(min(1, max(0, (1.004 - r) * c)) * 255)
                let i = (y * n + x) * 4
                l.bytes[i] = premul(Int(rgb.r), a); l.bytes[i + 1] = premul(Int(rgb.g), a)
                l.bytes[i + 2] = premul(Int(rgb.b), a); l.bytes[i + 3] = UInt8(a)
            }
        }
        return l.image()
    }()

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 180) }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 4, dy: 4)
        c.saveGState()
        c.translateBy(x: 0, y: bounds.height); c.scaleBy(x: 1, y: -1)
        let rr = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
        c.draw(Self.wheel, in: rr)
        c.setFillColor(CGColor(gray: 0, alpha: 1 - hsv.v))
        c.fillEllipse(in: rr)
        c.restoreGState()
        let a = hsv.h * .pi / 180, rad = hsv.s * r.width / 2
        let p = CGPoint(x: r.midX + cos(a) * rad, y: r.midY - sin(a) * rad)
        let m = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
        c.setStrokeColor(.black); c.setLineWidth(3); c.strokeEllipse(in: m)
        c.setStrokeColor(.white); c.setLineWidth(1.5); c.strokeEllipse(in: m)
    }

    private func pick(_ e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let r = bounds.insetBy(dx: 4, dy: 4)
        let dx = p.x - r.midX, dy = r.midY - p.y
        var h = atan2(dy, dx) * 180 / .pi
        if h < 0 { h += 360 }
        hsv.h = Double(h)
        hsv.s = Double(min(1, (dx * dx + dy * dy).squareRoot() / (r.width / 2)))
        onChange?(hsv)
    }

    override func mouseDown(with e: NSEvent) { pick(e) }
    override func mouseDragged(with e: NSEvent) { pick(e) }
}

/// Paint.NET-style colour editor: wheel, HSV / RGB / alpha sliders with numbers, hex.
final class ColorPickerController: NSViewController {
    let primary: Bool
    /// Where the colour goes; nil means the primary or secondary colour.
    private let custom: ((RGBA) -> Void)?
    private var hsv: HSV
    private var alpha: UInt8
    private let wheel = ColorWheelView()
    private var sliders: [(NSSlider, NSTextField, (Double) -> Void, () -> Double)] = []
    private let hex = NSTextField(string: "")
    private let preview = SwatchView()

    init(primary: Bool) {
        self.primary = primary
        custom = nil
        let c = primary ? AppState.shared.primary : AppState.shared.secondary
        hsv = HSV(c); alpha = c.a
        super.init(nibName: nil, bundle: nil)
    }

    /// Edits any colour (the text effects' second colours, say).
    init(color c: RGBA, set: @escaping (RGBA) -> Void) {
        primary = false
        custom = set
        hsv = HSV(c); alpha = c.a
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var color: RGBA { hsv.rgba(alpha: alpha) }

    override func loadView() {
        wheel.hsv = hsv
        wheel.onChange = { [weak self] h in self?.hsv = h; self?.changed(from: nil) }
        func row(_ name: String, _ max: Double, get: @escaping () -> Double, set: @escaping (Double) -> Void) -> NSView {
            let l = label(name.lowercased(), small: true)
            l.textColor = Ink.name
            l.widthAnchor.constraint(equalToConstant: 12).isActive = true
            let s = NSSlider(value: get(), minValue: 0, maxValue: max, target: nil, action: nil)
            s.controlSize = .small; s.isContinuous = true
            s.trackFillColor = Ink.soft
            s.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let f = NSTextField(string: "\(Int(get().rounded()))")
            styleField(f)
            f.widthAnchor.constraint(equalToConstant: 4 * 8 + 4).isActive = true
            let idx = sliders.count
            s.onAction { [weak self] c in set(c.doubleValue); self?.changed(from: idx) }
            f.onAction { [weak self] c in
                guard let v = Double(c.stringValue) else { return }
                set(min(max, Swift.max(0, v))); self?.changed(from: nil)
            }
            sliders.append((s, f, set, get))
            let r = NSStackView(views: [l, s, f]); r.spacing = 6
            return r
        }
        let rows: [NSView] = [
            row("H", 359, get: { [unowned self] in hsv.h }, set: { [unowned self] in hsv.h = $0 }),
            row("S", 100, get: { [unowned self] in hsv.s * 100 }, set: { [unowned self] in hsv.s = $0 / 100 }),
            row("V", 100, get: { [unowned self] in hsv.v * 100 }, set: { [unowned self] in hsv.v = $0 / 100 }),
            row("R", 255, get: { [unowned self] in Double(color.r) }, set: { [unowned self] in setRGB(r: $0) }),
            row("G", 255, get: { [unowned self] in Double(color.g) }, set: { [unowned self] in setRGB(g: $0) }),
            row("B", 255, get: { [unowned self] in Double(color.b) }, set: { [unowned self] in setRGB(b: $0) }),
            row("A", 255, get: { [unowned self] in Double(alpha) }, set: { [unowned self] in alpha = UInt8($0.rounded()) }),
        ]
        styleField(hex)
        hex.widthAnchor.constraint(equalToConstant: 9 * 8 + 4).isActive = true
        hex.onAction { [weak self] c in
            guard let self, let v = RGBA(hex: c.stringValue) else { return }
            hsv = HSV(v); alpha = v.a; changed(from: nil)
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant: 40).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let hash = label("#"); hash.textColor = Ink.dim
        let hexRow = NSStackView(views: [hash, hex, preview]); hexRow.spacing = 4
        let right = NSStackView(views: rows + [hexRow])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 4
        let all = NSStackView(views: [wheel, right])
        all.alignment = .top; all.spacing = 12
        all.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        all.wantsLayer = true
        all.layer?.backgroundColor = Ink.window.cgColor
        view = all
        changed(from: nil)
    }

    private func setRGB(r: Double? = nil, g: Double? = nil, b: Double? = nil) {
        var c = color
        if let r { c.r = UInt8(r.rounded()) }
        if let g { c.g = UInt8(g.rounded()) }
        if let b { c.b = UInt8(b.rounded()) }
        let keepHue = hsv.h
        hsv = HSV(c)
        if hsv.s == 0 { hsv.h = keepHue }
    }

    /// Push the colour to the app and refresh every control except the one being dragged.
    private func changed(from source: Int?) {
        wheel.hsv = hsv
        for (i, (s, f, _, get)) in sliders.enumerated() {
            let v = get()
            if i != source { s.doubleValue = v }
            f.stringValue = "\(Int(v.rounded()))"
        }
        if hex.currentEditor() == nil { hex.stringValue = color.hex }
        preview.color = color
        if let custom { custom(color) } else if primary { AppState.shared.primary = color } else { AppState.shared.secondary = color }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        AppState.shared.noteRecent(color)
    }
}
