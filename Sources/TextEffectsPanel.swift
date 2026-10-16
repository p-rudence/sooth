import AppKit

/// Ready-made looks for text. Each one sets the whole style, sized to the image.
enum TextPreset: String, CaseIterable {
    case meme = "Meme", neon = "Neon", chrome = "Chrome", comic = "Comic", subtitle = "Subtitle", sticker = "Sticker"

    func apply(_ a: AppState, imageWidth w: Int) {
        let fonts = Set(NSFontManager.shared.availableFontFamilies)
        func font(_ names: String...) -> String { names.first(where: fonts.contains) ?? "Helvetica Neue" }
        var fx = TextSpec()   // effect defaults, then the preset's changes
        a.bold = false; a.italic = false; a.underline = false
        a.textAlign = .center
        a.textShadow = false
        a.outlineWidth = 0
        let size = max(24, (CGFloat(w) / (self == .meme ? 11 : 13)).rounded())
        a.fontSize = size
        switch self {
        case .meme:
            a.fontName = font("Impact", "Haettenschweiler", "Helvetica Neue")
            a.primary = .white; a.secondary = .black
            a.outlineWidth = max(2, (size * 0.055).rounded())
        case .neon:
            a.fontName = font("Futura", "Avenir Next", "Helvetica Neue")
            a.bold = true
            a.primary = RGBA(r: 255, g: 236, b: 250); a.secondary = RGBA(r: 255, g: 40, b: 190)
            a.outlineWidth = max(1, (size * 0.03).rounded())
            fx.glowSize = (size * 0.35).rounded(); fx.glowColor = RGBA(r: 255, g: 40, b: 190)
        case .chrome:
            a.fontName = font("Futura", "Impact", "Helvetica Neue")
            a.bold = true; a.italic = true
            a.primary = RGBA(r: 248, g: 250, b: 255); a.secondary = RGBA(r: 18, g: 22, b: 60)
            a.outlineWidth = max(2, (size * 0.035).rounded())
            fx.gradient = true; fx.color2 = RGBA(r: 50, g: 90, b: 170); fx.gradientAngle = 90
            fx.outline2Width = max(2, (size * 0.03).rounded()); fx.outline2Color = .white
            a.textShadow = true
            fx.shadowDistance = (size * 0.07).rounded(); fx.shadowBlur = (size * 0.04).rounded()
            fx.shadowColor = RGBA(r: 0, g: 0, b: 0, a: 180)
        case .comic:
            a.fontName = font("Comic Sans MS", "Chalkboard SE", "Marker Felt")
            a.bold = true
            a.primary = RGBA(r: 255, g: 222, b: 40); a.secondary = .black
            a.outlineWidth = max(2, (size * 0.06).rounded())
            a.textShadow = true
            fx.shadowDistance = (size * 0.08).rounded(); fx.shadowBlur = 0; fx.shadowAngle = 45
            fx.shadowColor = RGBA(r: 0, g: 0, b: 0, a: 255)
            fx.rotation = -4
        case .subtitle:
            a.fontName = font("Helvetica Neue", "Arial")
            a.bold = true
            a.fontSize = max(18, (CGFloat(w) / 26).rounded())
            a.primary = .white; a.secondary = .black
            fx.box = true; fx.boxColor = RGBA(r: 0, g: 0, b: 0, a: 170)
            fx.boxPadding = (a.fontSize * 0.35).rounded(); fx.boxRadius = (a.fontSize * 0.2).rounded()
        case .sticker:
            a.fontName = font("Arial Rounded MT Bold", "Avenir Next", "Helvetica Neue")
            a.primary = RGBA(r: 255, g: 90, b: 130); a.secondary = .white
            a.outlineWidth = max(3, (size * 0.09).rounded())
            fx.outline2Width = max(2, (size * 0.03).rounded()); fx.outline2Color = RGBA(r: 50, g: 20, b: 50)
            a.textShadow = true
            fx.shadowDistance = (size * 0.05).rounded(); fx.shadowBlur = (size * 0.06).rounded()
        }
        a.textEffects = fx
        NotificationCenter.default.post(name: .textStyleLoaded, object: nil)
    }
}

/// Floating panel with every text style control. Changes apply live to the text being edited.
final class TextEffectsPanel: NSPanel {
    private static var instance: TextEffectsPanel?
    static var shared: TextEffectsPanel {
        if let i = instance { return i }
        let i = TextEffectsPanel()
        instance = i
        return i
    }
    /// Drop the panel so it's built again in the current look.
    static func reset() {
        guard let i = instance else { return }
        i.orderOut(nil)
        instance = nil
    }
    private let stack = NSStackView()
    private var observer: Any?
    private var stateObserver: Any?
    /// True while the panel itself is changing the state.
    private var changing = false
    private func mine(_ f: () -> Void) { changing = true; f(); changing = false }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: true)
        title = "Text Effects"
        titlebarAppearsTransparent = true
        backgroundColor = Look.current == .glass ? NSColor(srgbRed: 0.86, green: 0.94, blue: 0.98, alpha: 1) : Ink.window
        appearance = Look.current.appearance
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(stack)
        scroll.documentView = flip
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
            flip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        contentView = scroll
        observer = NotificationCenter.default.addObserver(forName: .textStyleLoaded, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        // Changes made elsewhere (the options bar's shadow or outline, the colours) show here too.
        // Its own changes don't rebuild it, so a slider being dragged is never pulled out from under the mouse.
        stateObserver = NotificationCenter.default.addObserver(forName: .appStateChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isVisible, !self.changing else { return }
            self.rebuild()
        }
        rebuild()
    }

    static func show() {
        let p = shared
        p.rebuild()
        if !p.isVisible, let w = NSApp.keyWindow {
            p.setFrameTopLeftPoint(NSPoint(x: w.frame.maxX - 560, y: w.frame.maxY - 90))
        }
        p.orderFront(nil)
    }

    // MARK: Building

    private func header(_ s: String) {
        let l = label(s.lowercased())
        l.textColor = Ink.dim
        if !stack.arrangedSubviews.isEmpty { stack.setCustomSpacing(14, after: stack.arrangedSubviews.last!) }
        stack.addArrangedSubview(l)
    }

    private func row(_ views: [NSView]) {
        let r = NSStackView(views: views)
        r.spacing = 8
        stack.addArrangedSubview(r)
    }

    private func slider(_ name: String, _ min: Double, _ max: Double, _ value: CGFloat, step: Double = 1,
                        _ set: @escaping (CGFloat) -> Void) {
        let l = label(name.lowercased(), small: true)
        l.textColor = Ink.name
        l.widthAnchor.constraint(equalToConstant: 11 * 8).isActive = true
        let s = NSSlider(value: Double(value), minValue: min, maxValue: max, target: nil, action: nil)
        s.controlSize = .small
        s.isContinuous = true
        s.trackFillColor = Ink.soft
        s.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let fmt = { (v: Double) in step < 1 ? String(format: "%.2f", v) : String(Int(v.rounded())) }
        let f = NSTextField(string: fmt(Double(value)))
        styleField(f)
        f.widthAnchor.constraint(equalToConstant: 5 * 8 + 4).isActive = true
        s.onAction { [weak self] c in
            let v = (c.doubleValue / step).rounded() * step
            f.stringValue = fmt(v); self?.mine { set(CGFloat(v)) }
        }
        f.onAction { [weak self] c in
            guard let v = Double(c.stringValue) else { return }
            s.doubleValue = v; self?.mine { set(CGFloat(v)) }
        }
        row([l, s, f])
    }

    private func well(_ name: String, _ color: RGBA, _ set: @escaping (RGBA) -> Void) -> NSView {
        let w = SwatchView()
        w.color = color
        w.toolTip = "Click to change"
        w.translatesAutoresizingMaskIntoConstraints = false
        w.widthAnchor.constraint(equalToConstant: 32).isActive = true
        w.heightAnchor.constraint(equalToConstant: 18).isActive = true
        w.onClick = { [weak self, weak w] in
            guard let self, let w else { return }
            self.popover?.close()
            let pop = NSPopover()
            pop.behavior = .transient
            pop.appearance = Look.current.appearance
            pop.contentViewController = ColorPickerController(color: w.color) { [weak self, weak w] c in
                w?.color = c; self?.mine { set(c) }
            }
            pop.show(relativeTo: w.bounds, of: w, preferredEdge: .maxX)
            self.popover = pop
        }
        let l = label(name.lowercased(), small: true)
        l.textColor = Ink.name
        let s = NSStackView(views: [l, w]); s.spacing = 6
        return s
    }

    private var popover: NSPopover?

    private func check(_ name: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> NSView {
        let s = Strip()
        s.inset = 0
        s.parts = [.toggle(name.lowercased(), on) { [weak self] v in self?.mine { set(v) }; self?.rebuild() }]
        return s
    }

    private func fx(_ change: (inout TextSpec) -> Void) {
        var e = AppState.shared.textEffects
        change(&e)
        AppState.shared.textEffects = e
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let a = AppState.shared, e = a.textEffects

        header("Presets")
        let presets = TextPreset.allCases
        for chunk in stride(from: 0, to: presets.count, by: 3) {
            var parts: [Strip.Part] = []
            for p in presets[chunk..<min(chunk + 3, presets.count)] {
                parts += [.button(p.rawValue.lowercased()) {
                    let w = (NSApp.mainWindow?.windowController as? EditorWindowController)?.doc.width ?? 800
                    p.apply(AppState.shared, imageWidth: w)
                }, .text(" ")]
            }
            let s = Strip(parts); s.inset = 0
            row([s])
        }
        let clear = Strip([.button("clear effects") {
            let s = AppState.shared
            s.textEffects = TextSpec(); s.outlineWidth = 0; s.textShadow = false
            NotificationCenter.default.post(name: .textStyleLoaded, object: nil)
        }])
        clear.inset = 0
        row([clear])

        header("Fill")
        let mode = Strip(radio(["solid", "gradient"], e.gradient ? 1 : 0) { [weak self] i in
            self?.fx { $0.gradient = i == 1 }
            self?.rebuild()
        })
        mode.inset = 0
        row([mode, well("Colour", a.primary) { AppState.shared.primary = $0 },
             well("To", e.color2) { [weak self] c in self?.fx { $0.color2 = c } }])
        slider("Angle", 0, 360, e.gradientAngle) { [weak self] v in self?.fx { $0.gradientAngle = v } }

        header("Outline")
        slider("Width", 0, 80, a.outlineWidth) { AppState.shared.outlineWidth = $0 }
        row([well("Colour", a.secondary) { AppState.shared.secondary = $0 }])
        slider("Outer width", 0, 80, e.outline2Width) { [weak self] v in self?.fx { $0.outline2Width = v } }
        row([well("Outer colour", e.outline2Color) { [weak self] c in self?.fx { $0.outline2Color = c } }])

        header("Shadow")
        row([check("Drop shadow", a.textShadow) { AppState.shared.textShadow = $0 },
             well("Colour", e.shadowColor) { [weak self] c in self?.fx { $0.shadowColor = c } }])
        slider("Distance", 0, 150, e.shadowDistance) { [weak self] v in self?.fx { $0.shadowDistance = v } }
        slider("Angle", 0, 360, e.shadowAngle) { [weak self] v in self?.fx { $0.shadowAngle = v } }
        slider("Softness", 0, 150, e.shadowBlur) { [weak self] v in self?.fx { $0.shadowBlur = v } }

        header("Glow")
        slider("Size", 0, 200, e.glowSize) { [weak self] v in self?.fx { $0.glowSize = v } }
        row([well("Colour", e.glowColor) { [weak self] c in self?.fx { $0.glowColor = c } }])

        header("Spacing")
        slider("Letters", -30, 150, e.tracking) { [weak self] v in self?.fx { $0.tracking = v } }
        slider("Lines", 0.5, 3, e.lineHeight, step: 0.05) { [weak self] v in self?.fx { $0.lineHeight = v } }

        header("Rotation")
        slider("Degrees", -180, 180, e.rotation) { [weak self] v in self?.fx { $0.rotation = v } }

        header("Caption Box")
        row([check("Box behind text", e.box) { [weak self] on in self?.fx { $0.box = on } },
             well("Colour", e.boxColor) { [weak self] c in self?.fx { $0.boxColor = c } }])
        slider("Padding", 0, 200, e.boxPadding) { [weak self] v in self?.fx { $0.boxPadding = v } }
        slider("Corners", 0, 200, e.boxRadius) { [weak self] v in self?.fx { $0.boxRadius = v } }

        let h = min(760, stack.fittingSize.height + 30)
        setContentSize(NSSize(width: 340, height: h))
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
