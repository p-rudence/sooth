import AppKit

// MARK: - Tool palette

/// The tools: a column of words in the house look (`b brush◄`, blank lines between groups), or a
/// two-wide grid of pictures in the others, the way Paint and MacPaint laid them out.
final class ToolPaletteView: NSView {
    private static let groups: [[ToolKind]] = [
        [.moveSelected, .moveSelection],
        [.rectSelect, .ellipseSelect, .lasso, .magicWand],
        [.zoom, .pan],
        [.bucket, .gradient, .brush, .eraser, .pencil, .picker, .clone, .recolor],
        [.text, .line, .shapes],
    ]
    private let rowH: CGFloat = uiSize + 4
    private let gapH: CGFloat = 10
    private var observer: Any?
    private var tips: [NSString] = []   // AppKit doesn't keep tooltip owners alive
    private let icons = Look.current.iconTools

    /// The picture grid's cell, and the space between cells.
    private var cell: CGFloat { Look.current == .bevel || Look.current == .platinum ? 26 : 30 }
    private var spacing: CGFloat { Look.current == .bevel ? 0 : 4 }
    static var width: CGFloat {
        switch Look.current {
        case .tianmu: 112
        case .bevel: 2 * 26 + 16
        case .platinum: 2 * 26 + 4 + 16
        default: 2 * 30 + 4 + 18
        }
    }

    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        observer = NotificationCenter.default.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.needsDisplay = true
        }
        for (t, r) in rows() {
            let s = "\(t.title) (\(String(t.key).uppercased()))" as NSString
            tips.append(s)
            addToolTip(r, owner: s, userData: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rows() -> [(ToolKind, CGRect)] {
        var y: CGFloat = 8, out: [(ToolKind, CGRect)] = []
        if icons {
            let x0 = ((Self.width - 2 * cell - spacing) / 2).rounded()
            for g in Self.groups {
                for (i, t) in g.enumerated() {
                    out.append((t, CGRect(x: x0 + CGFloat(i % 2) * (cell + spacing), y: y, width: cell, height: cell)))
                    if i % 2 == 1 || i == g.count - 1 { y += cell + spacing }
                }
                y += 8
            }
            return out
        }
        for g in Self.groups {
            for t in g { out.append((t, CGRect(x: 0, y: y, width: 112, height: rowH))); y += rowH }
            y += gapH
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let cur = AppState.shared.tool
        guard icons else {
            for (t, r) in rows() {
                let on = t == cur
                let s = NSMutableAttributedString()
                s.append(NSAttributedString(string: String(t.key) + " ", attributes: [.font: pixelFont(), .foregroundColor: on ? Ink.name : Ink.dim]))
                s.append(NSAttributedString(string: t.word, attributes: [.font: pixelFont(), .foregroundColor: on ? Ink.text : Ink.name]))
                if on { s.append(NSAttributedString(string: "◄", attributes: [.font: pixelFont(), .foregroundColor: Ink.soft])) }
                s.draw(at: CGPoint(x: 10, y: r.minY + 2))
            }
            return
        }
        for (t, r) in rows() {
            let on = t == cur
            switch Look.current {
            case .bevel, .platinum:
                Chrome.button(r, on: on)
            case .glass:
                if on { Chrome.gloss(r, radius: 6, on: true) }
            default:
                if on {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
                }
            }
            let tint: NSColor? = Look.current == .native ? (on ? .white : .labelColor)
                               : Look.current == .glass ? NSColor(srgbRed: 0.05, green: 0.25, blue: 0.42, alpha: 1) : nil
            let img = t.icon(size: 15, color: tint)
            var ir = CGRect(x: (r.midX - img.size.width / 2).rounded(), y: (r.midY - img.size.height / 2).rounded(),
                            width: img.size.width, height: img.size.height)
            if on && Look.current == .bevel { ir = ir.offsetBy(dx: 1, dy: 1) }
            img.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
        }
    }

    override func resetCursorRects() {
        guard !icons else { return }
        for (_, r) in rows() { addCursorRect(r, cursor: .pointingHand) }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let (t, _) = rows().first(where: { $0.1.contains(p) }) { AppState.shared.tool = t }
    }
}

extension ToolKind {
    /// The palette's short name.
    var word: String {
        switch self {
        case .moveSelected: "move"
        case .moveSelection: "outline"
        case .rectSelect: "rect"
        case .ellipseSelect: "ellipse"
        case .lasso: "lasso"
        case .magicWand: "wand"
        case .zoom: "zoom"
        case .pan: "pan"
        case .bucket: "bucket"
        case .gradient: "gradient"
        case .brush: "brush"
        case .eraser: "eraser"
        case .pencil: "pencil"
        case .picker: "picker"
        case .clone: "clone"
        case .recolor: "recolor"
        case .text: "text"
        case .line: "line"
        case .shapes: "shapes"
        }
    }
}

// MARK: - Options bar (Paint.NET's tool toolbar)

/// One line of pixel text for the current tool's settings, rebuilt whenever the state changes.
final class OptionsBar: NSView {
    private let strip = Strip()
    private var observers: [Any] = []
    private var shownTool: ToolKind?

    init() {
        super.init(frame: .zero)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        for n in [Notification.Name.appStateChanged, .textStyleLoaded] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                self?.rebuild()
            })
        }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    private typealias P = Strip.Part

    private func rebuild() {
        let st = AppState.shared
        let t = st.tool
        if t != shownTool { strip.cancelTyping(); shownTool = t }   // a half-typed number belongs to the old tool
        // The palette already marks the tool, so the line starts with its settings (it's long enough).
        var p: [P] = []
        func hint(_ s: String) { p += [.gap, .text(s, Ink.dim)] }

        if t.usesBrushWidth {
            p.append(.text("width "))
            p += number(Double(st.brushWidth), 1, 500, tip: "Brush width in pixels ([ and ] change it too)") { AppState.shared.brushWidth = CGFloat($0) }
            p.append(.gap)
        }
        if t == .brush || t == .eraser {
            p.append(.text("hardness "))
            p += number(Double((st.brushHardness * 100).rounded()), 0, 100, step: 5, unit: "%") { AppState.shared.brushHardness = CGFloat($0 / 100) }
            p += [.gap, .text("opacity ")]
            p += number(Double((st.brushOpacity * 100).rounded()), 0, 100, step: 5, unit: "%") { AppState.shared.brushOpacity = CGFloat($0 / 100) }
            p += [.gap, .toggle("pressure", st.pressureSize, tip: "A tablet pen's pressure changes the brush size") { AppState.shared.pressureSize = $0 }]
            p.append(.gap)
        }
        if [.brush, .eraser, .clone, .line, .shapes, .text, .gradient].contains(t) {
            p += [.toggle("antialias", st.antialias) { AppState.shared.antialias = $0 }, .gap]
        }
        switch t {
        case .rectSelect, .ellipseSelect, .lasso, .magicWand:
            p.append(.text("mode "))
            p.append(.choice(SelectMode.allCases.map(\.title), st.selectMode.rawValue, tip: "Selection mode") {
                AppState.shared.selectMode = SelectMode(rawValue: $0)!
            })
            p.append(.gap)
            if t == .magicWand { addFlood(&p) }
            if t == .rectSelect || t == .ellipseSelect {
                p += radio(["free", "ratio", "size"], st.selectShape, tips: ["Normal", "Fixed ratio", "Fixed size"]) { AppState.shared.selectShape = $0 }
                if st.selectShape != 0 {
                    let fixed = st.selectShape == 2
                    p += number(Double(st.selectW), fixed ? 1 : 0.01, 30000, step: fixed ? 1 : 0.1, decimals: fixed ? 0 : 1) { AppState.shared.selectW = CGFloat($0) }
                    p.append(.text(" × "))
                    p += number(Double(st.selectH), fixed ? 1 : 0.01, 30000, step: fixed ? 1 : 0.1, decimals: fixed ? 0 : 1) { AppState.shared.selectH = CGFloat($0) }
                    p.append(.text(fixed ? " px" : ""))
                }
            }
            hint("⇧ add · ⌥ subtract · ⇧⌥ intersect")
        case .bucket:
            addFlood(&p)
        case .recolor:
            addTolerance(&p)
            hint("replaces secondary-ish colours with primary")
        case .picker:
            addSampling(&p)
            hint("click = primary · right-click = secondary")
        case .gradient:
            p.append(.choice(GradientKind.allCases.map(\.title), st.gradient.rawValue, tip: "Gradient shape") {
                AppState.shared.gradient = GradientKind(rawValue: $0)!
            })
            p.append(.gap)
            p += radio(["colour", "transparency"], st.gradientTransparency ? 1 : 0) { AppState.shared.gradientTransparency = $0 == 1 }
            hint(st.gradientTransparency ? "fades the layer out from start to end · right-drag reverses"
                                         : "primary → secondary · right-drag reverses")
        case .shapes:
            p.append(.choice(ShapeKind.allCases.map(\.title), st.shape.rawValue, tip: "Shape") { AppState.shared.shape = ShapeKind(rawValue: $0)! })
            p.append(.gap)
            p.append(.choice(FillStyle.allCases.map(\.title), st.fillStyle.rawValue, tip: "Outline, fill or both") {
                AppState.shared.fillStyle = FillStyle(rawValue: $0)!
            })
        case .line:
            p += [.toggle("arrow at start", st.arrowStart) { AppState.shared.arrowStart = $0 }, .gap,
                  .toggle("arrow at end", st.arrowEnd) { AppState.shared.arrowEnd = $0 }]
            hint("⇧ snaps to 15°")
        case .clone:
            hint("⌥-click to set the source, then paint")
        case .text:
            let fonts = NSFontManager.shared.availableFontFamilies
            p.append(.init(runs: [("[", Ink.dim), (st.fontName, Ink.soft), ("]", Ink.dim)], tip: "Font",
                           kind: .menu(fonts, fonts.firstIndex(of: st.fontName)) { AppState.shared.fontName = fonts[$0] }, face: .choice(st.fontName)))
            p.append(.text(" "))
            p += number(Double(st.fontSize), 1, 2000, tip: "Font size") { AppState.shared.fontSize = CGFloat($0) }
            p.append(.gap)
            for (word, on, set) in [("bold", st.bold, { (v: Bool) in AppState.shared.bold = v }),
                                    ("italic", st.italic, { (v: Bool) in AppState.shared.italic = v }),
                                    ("underline", st.underline, { (v: Bool) in AppState.shared.underline = v })] {
                p.append(.press(word, on) { set($0) })
            }
            p.append(.text(" "))
            p += radio(["left", "centre", "right"], st.textAlign.rawValue) { AppState.shared.textAlign = TextAlign(rawValue: $0)! }
            p.append(.text("outline "))
            p += number(Double(st.outlineWidth), 0, 200, tip: "Outline thickness in pixels, drawn in the secondary colour (0 = none)") {
                AppState.shared.outlineWidth = CGFloat($0)
            }
            p += [.gap, .toggle("shadow", st.textShadow) { AppState.shared.textShadow = $0 }, .gap,
                  .button("meme", tip: "Impact, white with a black outline, centred, sized to the image") {
                      let w = (NSApp.keyWindow?.windowController as? EditorWindowController)?.doc.width ?? 800
                      TextPreset.meme.apply(AppState.shared, imageWidth: w)
                  }, .text(" "),
                  .button("effects", tip: "Gradient, outer outline, shadow, glow, spacing, rotation, caption box and presets") {
                      TextEffectsPanel.show()
                  }]
        case .zoom:
            hint("click to zoom in · ⌥ or right-click to zoom out · ⌘-scroll anywhere")
        case .pan:
            hint("drag to pan · hold space with any tool")
        case .moveSelected:
            hint("drag to move · handles resize (⇧ keeps shape) · drag just outside or right-drag to rotate · arrows nudge · ⌥ leaves a copy · ↩ finishes")
        case .moveSelection:
            hint("moves only the outline · handles resize · drag just outside or right-drag to rotate · arrows nudge")
        default:
            break
        }
        strip.parts = p
    }

    private func addTolerance(_ p: inout [P]) {
        p.append(.text("tolerance "))
        p += number((AppState.shared.tolerance * 100).rounded(), 0, 100, unit: "%") { AppState.shared.tolerance = $0 / 100 }
        p.append(.gap)
    }

    private func addSampling(_ p: inout [P]) {
        p.append(.text("sample "))
        p += radio(["layer", "image"], AppState.shared.sampleImage ? 1 : 0) { AppState.shared.sampleImage = $0 == 1 }
    }

    private func addFlood(_ p: inout [P]) {
        let st = AppState.shared
        p.append(.text("flood "))
        if st.tool == .magicWand {
            p += radio(["contiguous", "global", "subject"], st.wandSubject ? 2 : (st.floodGlobal ? 1 : 0)) {
                AppState.shared.wandSubject = $0 == 2
                AppState.shared.floodGlobal = $0 == 1
            }
            if st.wandSubject {
                p.append(.gap)
                addSampling(&p)
                p += [.gap, .text("click a person, animal or thing to select it", Ink.dim)]
                return
            }
        } else {
            p += radio(["contiguous", "global"], st.floodGlobal ? 1 : 0) { AppState.shared.floodGlobal = $0 == 1 }
        }
        p.append(.gap)
        addTolerance(&p)
        addSampling(&p)
    }
}

// MARK: - Colors

final class SwatchView: NSView {
    var color: RGBA = .black { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        switch Look.current {
        case .bevel: Chrome.well95(bounds)
        case .platinum: Chrome.platinumWell(bounds)
        default:
            Ink.dim.setFill(); bounds.fill()
            (Look.current == .tianmu ? NSColor.black : NSColor.white).setFill(); bounds.insetBy(dx: 1, dy: 1).fill()
        }
        let inner = Look.current == .bevel || Look.current == .platinum ? bounds.insetBy(dx: 2, dy: 2) : r.insetBy(dx: 1, dy: 1)
        checkerColor.setFill(); inner.fill()
        color.ns.setFill(); inner.fill()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class PaletteView: NSView {
    var colors: [RGBA] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    let columns = 12
    let cell: CGFloat = 20

    init(colors: [RGBA]) {
        self.colors = colors
        super.init(frame: .zero)
        toolTip = "Click: primary colour · Right-click or ⌥-click: secondary colour"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columns) * cell, height: CGFloat((colors.count + columns - 1) / columns) * cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in colors.enumerated() {
            let r = NSRect(x: CGFloat(i % columns) * cell, y: CGFloat(i / columns) * cell, width: cell, height: cell).insetBy(dx: 1, dy: 1)
            checkerColor.setFill(); r.fill()
            c.ns.setFill(); r.fill()
            // A faint edge, so black (and other very dark) swatches still show on the black panel.
            (Look.current == .tianmu ? Ink.faint : Ink.line).setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
        }
    }

    private func color(at e: NSEvent) -> RGBA? {
        let p = convert(e.locationInWindow, from: nil)
        let i = Int(p.y / cell) * columns + Int(p.x / cell)
        return i >= 0 && i < colors.count && p.x >= 0 && p.x < CGFloat(columns) * cell ? colors[i] : nil
    }

    override func mouseDown(with e: NSEvent) {
        guard let c = color(at: e) else { return }
        if e.modifierFlags.contains(.option) { AppState.shared.secondary = c } else { AppState.shared.primary = c }
    }

    override func rightMouseDown(with e: NSEvent) {
        if let c = color(at: e) { AppState.shared.secondary = c }
    }
}

final class ColorsPanel: NSView {
    private let primary = SwatchView()
    private let secondary = SwatchView()
    private let hex = NSTextField(string: "")
    private var observer: Any?
    private let recentView = PaletteView(colors: [])
    private let recentLabel = Strip([.text("recent", Ink.dim)])
    private var popover: NSPopover?

    init() {
        super.init(frame: .zero)
        primary.onClick = { [weak self] in self?.edit(primary: true) }
        secondary.onClick = { [weak self] in self?.edit(primary: false) }
        primary.toolTip = "Primary colour (click to edit)"
        secondary.toolTip = "Secondary colour (click to edit)"

        let swatches = NSView()
        swatches.translatesAutoresizingMaskIntoConstraints = false
        for (v, x, y) in [(secondary, 22.0, 22.0), (primary, 0.0, 0.0)] {
            v.frame = NSRect(x: x, y: 22 - y, width: 40, height: 40)
            swatches.addSubview(v)
        }
        swatches.widthAnchor.constraint(equalToConstant: 64).isActive = true
        swatches.heightAnchor.constraint(equalToConstant: 64).isActive = true

        styleField(hex)
        hex.placeholderAttributedString = NSAttributedString(string: "hex", attributes: [.font: pixelFont(), .foregroundColor: Ink.dim])
        hex.toolTip = "Primary colour as hex (RRGGBB or RRGGBBAA)"
        hex.widthAnchor.constraint(equalToConstant: 9 * 8 + 4).isActive = true
        hex.onAction { c in
            if let v = RGBA(hex: c.stringValue) { AppState.shared.primary = v }
            if let w = c.window, w.firstResponder === c.currentEditor() { w.makeFirstResponder(w.initialFirstResponder) }
        }
        let buttons = Strip([.button("swap", tip: "Swap colours (X)") { AppState.shared.swapColors() }, .text(" "),
                             .button("b/w", tip: "Reset to black and white") {
                                 AppState.shared.primary = .black; AppState.shared.secondary = .white
                             }])
        buttons.inset = 0
        let hexRow = NSStackView(views: [Strip([.text("#", Ink.dim)]), hex])
        hexRow.spacing = 0
        (hexRow.views[0] as? Strip)?.inset = 0

        let side = NSStackView(views: [hexRow, buttons])
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 6
        let top = NSStackView(views: [swatches, side])
        top.alignment = .top
        top.spacing = 14

        let pal = PaletteView(colors: AppState.shared.palette)
        recentLabel.inset = 0
        let all = NSStackView(views: [top, pal, recentLabel, recentView])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 8
        all.setCustomSpacing(2, after: recentLabel)
        all.translatesAutoresizingMaskIntoConstraints = false
        addSubview(all)
        NSLayoutConstraint.activate([
            all.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            all.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            all.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
        observer = NotificationCenter.default.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func sync() {
        let st = AppState.shared
        primary.color = st.primary
        secondary.color = st.secondary
        if hex.currentEditor() == nil { hex.stringValue = st.primary.hex }
        if recentView.colors != st.recent { recentView.colors = st.recent }
        recentLabel.isHidden = st.recent.isEmpty
    }

    private func edit(primary p: Bool) {
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.appearance = Look.current.appearance
        pop.contentViewController = ColorPickerController(primary: p)
        pop.show(relativeTo: (p ? primary : secondary).bounds, of: p ? primary : secondary, preferredEdge: .maxX)
        popover = pop
    }
}

// MARK: - Rows

/// Table rows that mark the selection in the look's own way (a quiet grey bar in the house look,
/// not the accent colour).
final class QuietRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        switch Look.current {
        case .glass:
            Chrome.gloss(bounds.insetBy(dx: 2, dy: 1), radius: 5, on: true)
        case .native:
            Ink.pick.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 5, yRadius: 5).fill()
        default:
            Ink.pick.setFill()
            bounds.fill()
        }
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isSelected: Bool {
        didSet { PickLabel.mark(self, picked: isSelected) }
    }
    // Cells arrive after the row is already selected.
    override func didAddSubview(_ v: NSView) {
        super.didAddSubview(v)
        PickLabel.mark(self, picked: isSelected)
    }
}

/// A label that turns `Ink.pickText` on a selected row (white on Bevel's navy) and back again.
final class PickLabel: NSTextField {
    var base: NSColor = Ink.text { didSet { if !picked { textColor = base } } }
    var picked = false { didSet { textColor = picked && Ink.pickText != Ink.text ? Ink.pickText : base } }

    static func mark(_ v: NSView, picked: Bool) {
        for s in v.subviews {
            if let l = s as? PickLabel { l.picked = picked }
            mark(s, picked: picked)
        }
    }
}

func pixelLabel(_ s: String = "", _ c: NSColor = Ink.text) -> NSTextField {
    let l = PickLabel(labelWithString: s)
    l.font = pixelFont()
    l.base = c
    l.textColor = c
    l.lineBreakMode = .byTruncatingTail
    return l
}

// MARK: - Layers

final class LayerCell: NSTableCellView {
    /// Visibility, as ● (shown) or ○ (hidden).
    let check: NSButton = {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.setButtonType(.toggle)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }()

    func setVisible(_ on: Bool) {
        check.state = on ? .on : .off
        switch Look.current {
        case .tianmu:
            let a = NSAttributedString(string: on ? "●" : "○", attributes: [.font: pixelFont(), .foregroundColor: on ? Ink.soft : Ink.dim])
            check.attributedTitle = a
            check.attributedAlternateTitle = a
        case .bevel, .platinum:
            // A checkbox, as layer palettes had then.
            let img = NSImage(size: NSSize(width: 14, height: 14), flipped: true) { r in Chrome.checkbox(r, on: on); return true }
            check.title = ""
            check.image = img; check.alternateImage = img
            check.imagePosition = .imageOnly
        default:
            let img = symbolImage(on ? "eye" : "eye.slash", size: 12)?
                .withSymbolConfiguration(.init(paletteColors: [on ? Ink.soft : Ink.dim]))
            check.title = ""
            check.image = img; check.alternateImage = img
            check.imagePosition = .imageOnly
        }
        (name as? PickLabel)?.base = on ? Ink.text : Ink.name
        if !(name is PickLabel) { name.textColor = on ? Ink.text : Ink.name }
    }
    let thumb = LayerCell.thumbButton()
    /// The layer mask's thumbnail (hidden without one). Click it to paint the mask, the layer's to paint the layer.
    let maskThumb = LayerCell.thumbButton()
    let name = pixelLabel()
    let info = pixelLabel("", Ink.dim)

    private static func thumbButton() -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleProportionallyUpOrDown
        b.wantsLayer = true
        b.layer?.borderWidth = 1
        b.layer?.borderColor = Ink.faint.cgColor
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    /// Which thumbnail brushes paint: a bright frame on it.
    func setTarget(mask: Bool) {
        thumb.layer?.borderColor = (!mask && !maskThumb.isHidden ? Ink.soft : Ink.faint).cgColor
        thumb.layer?.borderWidth = !mask && !maskThumb.isHidden ? 2 : 1
        maskThumb.layer?.borderColor = (mask ? Ink.soft : Ink.faint).cgColor
        maskThumb.layer?.borderWidth = mask ? 2 : 1
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let text = NSStackView(views: [name, info])
        text.orientation = .vertical; text.alignment = .leading; text.spacing = 0
        let row = NSStackView(views: [check, thumb, maskThumb, text])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 48),
            thumb.heightAnchor.constraint(equalToConstant: 36),
            maskThumb.widthAnchor.constraint(equalToConstant: 36),
            maskThumb.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

func thumbnail(_ img: CGImage, maxW: CGFloat = 96, maxH: CGFloat = 72) -> NSImage {
    let s = min(maxW / CGFloat(img.width), maxH / CGFloat(img.height), 1)
    let size = NSSize(width: max(1, CGFloat(img.width) * s), height: max(1, CGFloat(img.height) * s))
    return NSImage(size: size, flipped: false) { r in
        checkerColor.setFill(); r.fill()
        NSGraphicsContext.current?.cgContext.interpolationQuality = .medium
        NSGraphicsContext.current?.cgContext.draw(img, in: r)
        return true
    }
}

/// A plain table on black with an overlay scroller.
func quietTable(_ table: NSTableView, rowHeight: CGFloat) -> NSScrollView {
    table.addTableColumn(NSTableColumn(identifier: .init("c")))
    table.headerView = nil
    table.rowHeight = rowHeight
    table.style = .plain
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.gridStyleMask = []
    table.focusRingType = .none
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    return scroll
}

final class LayersPanel: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private static let dragType = NSPasteboard.PasteboardType("org.tianmu.sooth.layer-row")
    weak var controller: EditorWindowController?
    let doc: Document
    private let table = NSTableView()
    private var updating = false

    init(doc: Document) {
        self.doc = doc
        super.init(frame: .zero)
        let scroll = quietTable(table, rowHeight: 44)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.registerForDraggedTypes([LayersPanel.dragType])
        table.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.font = pixelFont()
        menu.delegate = self
        table.menu = menu
        table.refusesFirstResponder = true   // the keyboard stays with the canvas (tool keys keep working)

        let c = { [weak self] in self?.controller }
        let adjNames = AdjustmentSpec.filters.map(\.name)
        let bar = Strip([
            .button("+", tip: "Add New Layer (⇧⌘N)") { c()?.addLayer(nil) }, .text(" "),
            .menuButton("adj", adjNames, tip: "New adjustment layer: changes everything below, live and re-editable") {
                c()?.newAdjustmentLayer(AdjustmentSpec.filters[$0])
            }, .text(" "),
            .button("dup", tip: "Duplicate Layer (⇧⌘D)") { c()?.duplicateLayer(nil) }, .text(" "),
            .button("del", tip: "Delete Layer") { c()?.deleteLayer(nil) }, .text(" "),
            .button("merge", tip: "Merge Layer Down (⌘E)") { c()?.mergeDown(nil) },
            .button("↑", tip: "Move Layer Up") { c()?.moveLayerUp(nil) },
            .button("↓", tip: "Move Layer Down") { c()?.moveLayerDown(nil) },
        ])
        bar.inset = 4
        let v = NSStackView(views: [scroll, bar])
        v.orientation = .vertical
        v.spacing = 2
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: topAnchor),
            v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            bar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        updating = true
        table.reloadData()
        table.selectRowIndexes([doc.layers.count - 1 - doc.active], byExtendingSelection: false)
        updating = false
    }

    private func index(_ row: Int) -> Int { doc.layers.count - 1 - row }

    func numberOfRows(in tableView: NSTableView) -> Int { doc.layers.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { QuietRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("LayerCell"), owner: nil) as? LayerCell) ?? {
            let c = LayerCell(frame: .zero); c.identifier = .init("LayerCell"); return c
        }()
        let i = index(row)
        // The table can redraw between a change to the layers and its reload; that row is gone.
        guard doc.layers.indices.contains(i) else { return cell }
        let l = doc.layers[i]
        cell.name.stringValue = l.name
        var bits: [String] = []
        if l.adjustment != nil { bits.append("adjustment") }
        if l.mask != nil { bits.append(doc.editingMask && i == doc.active ? "painting mask" : "masked") }
        if l.text != nil { bits.append("text") }
        if let o = l.object { bits.append(o.cutout != nil ? "cut-out" : "image") }
        if let sh = l.shape { bits.append(sh.kind.title.lowercased()) }
        if l.blend != .normal { bits.append(l.blend.title.lowercased()) }
        if l.opacity < 1 { bits.append("\(Int((l.opacity * 100).rounded()))%") }
        cell.info.stringValue = bits.joined(separator: " · ")
        cell.info.isHidden = bits.isEmpty
        cell.thumb.image = l.thumbnail { thumbnail($0) }
        cell.maskThumb.isHidden = l.mask == nil
        cell.maskThumb.image = l.mask?.thumbnail { thumbnail($0, maxW: 72, maxH: 72) }
        cell.setTarget(mask: doc.editingMask && i == doc.active)
        cell.thumb.toolTip = l.mask == nil ? nil : "Paint the layer"
        cell.maskThumb.toolTip = "Paint the mask: black hides, white shows (⌘\\ switches)"
        cell.thumb.onAction { [weak self] _ in self?.target(i, mask: false) }
        cell.maskThumb.onAction { [weak self] _ in self?.target(i, mask: true) }
        cell.setVisible(l.visible)
        cell.check.toolTip = l.visible ? "Hide layer" : "Show layer"
        cell.check.onAction { [weak self] c in
            guard let self, i < self.doc.layers.count else { return }
            self.doc.layers[i].visible = (c as! NSButton).state == .on
            self.doc.active = i
            self.doc.commit(l.visible ? "Layer Shown" : "Layer Hidden", symbol: "eye", touch: .none)
        }
        cell.toolTip = "Double-click for name, blend mode and opacity"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, table.selectedRow >= 0 else { return }
        doc.active = index(table.selectedRow)
        controller?.statusChanged()
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        if doc.activeLayer.adjustment != nil { controller?.editAdjustment(nil) } else { controller?.layerProperties(nil) }
    }

    /// A thumbnail was clicked: that layer becomes active, painting its pixels or its mask.
    private func target(_ i: Int, mask: Bool) {
        guard doc.layers.indices.contains(i) else { return }
        doc.active = i
        doc.editingMask = mask && doc.layers[i].mask != nil
        reload()
        controller?.statusChanged()
    }

    // MARK: Drag to reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: LayersPanel.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table else { return [] }
        if op == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let s = info.draggingPasteboard.pasteboardItems?.first?.string(forType: LayersPanel.dragType), let from = Int(s) else { return false }
        // Rows run top-to-bottom; layers bottom-to-top.
        let n = doc.layers.count
        let src = n - 1 - from
        var dstRow = row > from ? row - 1 : row
        dstRow = max(0, min(n - 1, dstRow))
        let dst = n - 1 - dstRow
        guard src != dst else { return false }
        controller?.moveLayer(from: src, to: dst)
        return true
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, let c = controller else { return }
        let i = index(row)
        if doc.active != i { doc.active = i; reload() }
        let l = doc.layers[i]
        func add(_ title: String, _ sel: Selector, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = c
            it.isEnabled = enabled
            menu.addItem(it)
        }
        add("Duplicate Layer", #selector(EditorWindowController.duplicateLayer(_:)))
        add("Delete Layer", #selector(EditorWindowController.deleteLayer(_:)), enabled: doc.layers.count > 1)
        add("Merge Layer Down", #selector(EditorWindowController.mergeDown(_:)), enabled: i > 0)
        menu.addItem(.separator())
        add("Add to Library", #selector(EditorWindowController.addToLibrary(_:)))
        add("Vectorize…", #selector(EditorWindowController.vectorize(_:)), enabled: l.adjustment == nil && l.object?.vector == nil)
        if l.object?.vector != nil { add("Export Vector as SVG…", #selector(EditorWindowController.exportSVG(_:))) }
        menu.addItem(.separator())
        add("Remove Background…", #selector(EditorWindowController.removeBackground(_:)), enabled: l.text == nil)
        add("Rasterize Layer", #selector(EditorWindowController.rasterizeLayer(_:)), enabled: l.isLive)
        menu.addItem(.separator())
        add("Layer Properties…", #selector(EditorWindowController.layerProperties(_:)))
    }
}

// MARK: - History

final class HistoryPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var controller: EditorWindowController?
    let doc: Document
    private let table = NSTableView()
    private var updating = false

    init(doc: Document) {
        self.doc = doc
        super.init(frame: .zero)
        let scroll = quietTable(table, rowHeight: uiSize + 4)
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        updating = true
        table.reloadData()
        table.selectRowIndexes([doc.cursor], byExtendingSelection: false)
        table.scrollRowToVisible(doc.cursor)
        updating = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { doc.history.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { QuietRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = doc.history[row]
        let cell = NSTableCellView()
        let t = pixelLabel(Look.current == .tianmu ? item.name.lowercased() : item.name, row > doc.cursor ? Ink.dim : row == doc.cursor ? Ink.text : Ink.name)
        t.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(t)
        t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10).isActive = true
        t.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6).isActive = true
        t.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, table.selectedRow >= 0 else { return }
        let row = table.selectedRow
        // Text being typed is finished first (it becomes a step of its own, which may drop the redo rows).
        if controller?.canvas.engine.text != nil {
            controller?.canvas.engine.finishText()
            if row >= doc.history.count { reload(); return }
        }
        doc.jump(to: row)
    }
}

// MARK: - Status bar

/// `<name>  2400×1350  sel —  12,40 ……… [-] 44% [+] [fit]`
final class StatusBar: NSView {
    private let strip = Strip()
    var name = "" { didSet { refresh() } }
    var dirty = false { didSet { refresh() } }
    var size = "" { didSet { refresh() } }
    var sel = "" { didSet { refresh() } }
    var pos = "" { didSet { refresh() } }
    var zoom = "" { didSet { refresh() } }
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onFit: (() -> Void)?

    init() {
        super.init(frame: .zero)
        strip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.topAnchor.constraint(equalTo: topAnchor),
            strip.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // Windows' status bar is a row of sunken panes; the others sit on the window as it is.
        if Look.current == .bevel { Chrome.edges(bounds.insetBy(dx: 2, dy: 3), tl: NSColor(white: 0.5, alpha: 1), br: .white) }
    }

    private func refresh() {
        let short = name.count > 28 ? String(name.prefix(27)) + "…" : name
        let house = Look.current == .tianmu
        var p: [Strip.Part] = house ? [.text("<", Ink.dim), .text(short, Ink.text, tip: short == name ? nil : name, cased: false), .text(">", Ink.dim)]
                                    : [.text(short, Ink.text, tip: short == name ? nil : name, cased: false)]
        p += [.text(dirty ? (house ? " *" : " •") : "", Ink.soft), .gap, .text(size, Ink.name)]
        if !sel.isEmpty { p += [.gap, .text("sel ", Ink.dim), .text(sel, Ink.name)] }
        if !pos.isEmpty { p += [.gap, .text("at ", Ink.dim), .text(pos, Ink.name)] }
        p += [.spring,
              .button("library", tip: "Your kept things (⌘L)") { LibraryPanel.toggle() }, .text("  "),
              .button("-", tip: "Zoom Out (⌘-)") { [weak self] in self?.onZoomOut?() },
              .text(" " + zoom + " ", Ink.text, cased: false),
              .button("+", tip: "Zoom In (⌘=)") { [weak self] in self?.onZoomIn?() }, .text(" "),
              .button("fit", tip: "Zoom to Window (⌘0)") { [weak self] in self?.onFit?() }]
        strip.parts = p
    }
}
