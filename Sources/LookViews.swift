// The window-level pieces of a look: what's behind everything, the frame round each side panel,
// and the title bar the retro looks draw for themselves.

import AppKit

/// The editor window's content view: the look's ground (black, grey, sky…) behind every panel.
final class LookBackdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        switch Look.current {
        case .glass: Chrome.sky(bounds, bubbles: false)
        default: Ink.window.setFill(); bounds.fill()
        }
    }
}

/// One side panel (colours, layers, history): a heading line with its buttons, then the body, framed as the look frames things.
final class PanelBox: NSView {
    let header: Strip
    let body: NSView

    init(title: String, body: NSView, buttons: [Strip.Part]) {
        header = Strip([.heading(title), .spring] + buttons)
        self.body = body
        super.init(frame: .zero)
        let pad = PanelBox.padding
        for v in [header, body] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        header.inset = Look.current == .tianmu ? 10 : 8
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Look.current == .tianmu ? 4 : pad.top),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad.side),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad.side),
            header.heightAnchor.constraint(equalToConstant: PanelBox.headerHeight),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: pad.gap),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad.side + pad.inner),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(pad.side + pad.inner)),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(pad.bottom + pad.inner)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    static var headerHeight: CGFloat { Look.current == .tianmu ? uiSize + 8 : 24 }

    /// (top, side, gap under the heading, bottom, inside the frame)
    private static var padding: (top: CGFloat, side: CGFloat, gap: CGFloat, bottom: CGFloat, inner: CGFloat) {
        switch Look.current {
        case .tianmu: (4, 0, 0, 0, 0)
        case .bevel: (4, 6, 2, 6, 3)
        case .platinum: (5, 6, 3, 6, 3)
        case .glass: (6, 8, 2, 8, 4)
        case .native: (6, 4, 2, 4, 0)
        }
    }

    /// The body's frame (in this view), with the inner padding added back.
    private var bodyFrame: CGRect {
        let p = PanelBox.padding
        return body.frame.insetBy(dx: -p.inner, dy: -p.inner)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch Look.current {
        case .tianmu, .native:
            break
        case .bevel:
            Chrome.well95(bodyFrame, fill: NSColor(srgbRed: 0.75, green: 0.75, blue: 0.75, alpha: 1))
        case .platinum:
            // A floating palette's striped heading, then an inset well for the body.
            let p = PanelBox.padding
            let bar = CGRect(x: p.side, y: header.frame.minY + 1, width: bounds.width - p.side * 2, height: header.frame.height - 2)
            Chrome.pinstripes(bar)
            NSColor(white: 0.53, alpha: 1).setStroke()
            NSBezierPath(rect: bar.insetBy(dx: 0.5, dy: 0.5)).stroke()
            Chrome.edges(bodyFrame, tl: NSColor(white: 0.47, alpha: 1), br: .white)
        case .glass:
            Chrome.glassPane(bounds.insetBy(dx: 3, dy: 3), radius: 9)
        }
    }
}

extension Strip.Part {
    /// A panel's name: dim lower case in the house look, a bold title elsewhere.
    static func heading(_ s: String) -> Self {
        .init(runs: [(s, Ink.dim)], face: .heading(Look.current.word(s)))
    }
}

/// The title bar the retro looks draw in place of the system's, with working buttons.
final class TitleBarView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    private var pressed: Int?
    /// Screenshots are taken of windows that aren't key; they should still look awake.
    nonisolated(unsafe) static var alwaysActive = false
    private var active: Bool { TitleBarView.alwaysActive || (window?.isKeyWindow ?? true) }
    private var observers: [Any] = []

    static var height: CGFloat {
        switch Look.current {
        case .bevel: 26
        case .platinum: 24
        case .glass: 30
        default: 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? NSWindow === self.window else { return }
                self.needsDisplay = true
            })
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The three buttons: close, minimise, zoom.
    private func buttons() -> [CGRect] {
        let b = bounds
        switch Look.current {
        case .bevel:
            let h: CGFloat = 16, w: CGFloat = 18, y = b.midY - h / 2 + 1
            let close = CGRect(x: b.maxX - 6 - w, y: y, width: w, height: h)
            let zoom = CGRect(x: close.minX - 2 - w, y: y, width: w, height: h)
            let mini = CGRect(x: zoom.minX - w, y: y, width: w, height: h)
            return [close, mini, zoom]
        case .platinum:
            let s: CGFloat = 13, y = (b.midY - s / 2).rounded()
            let close = CGRect(x: 9, y: y, width: s, height: s)
            let zoom = CGRect(x: b.maxX - 9 - s - s - 5, y: y, width: s, height: s)
            let shade = CGRect(x: b.maxX - 9 - s, y: y, width: s, height: s)
            return [close, shade, zoom]
        case .glass:
            let h: CGFloat = 19, y: CGFloat = 1
            let close = CGRect(x: b.maxX - 10 - 44, y: y, width: 44, height: h)
            let zoom = CGRect(x: close.minX - 26, y: y, width: 26, height: h)
            let mini = CGRect(x: zoom.minX - 26, y: y, width: 26, height: h)
            return [close, mini, zoom]
        default:
            return []
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let bs = buttons()
        switch Look.current {
        case .bevel:
            Ink.window.setFill(); b.fill()
            let bar = b.insetBy(dx: 3, dy: 3)
            let g = active ? NSGradient(starting: NSColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1), ending: NSColor(srgbRed: 0.06, green: 0.52, blue: 0.82, alpha: 1))!
                           : NSGradient(starting: NSColor(white: 0.5, alpha: 1), ending: NSColor(white: 0.71, alpha: 1))!
            g.draw(in: bar, angle: 0)
            let icon = PixelArt.icon(.brush)
            icon.draw(in: CGRect(x: bar.minX + 2, y: bar.midY - 8, width: 16, height: 16))
            let t = NSAttributedString(string: title, attributes: [.font: uiFont(bold: true), .foregroundColor: active ? NSColor.white : NSColor(white: 0.85, alpha: 1)])
            t.draw(at: CGPoint(x: bar.minX + 22, y: (bar.midY - t.size().height / 2).rounded()))
            for (i, r) in bs.enumerated() {
                Chrome.bevel(r, down: pressed == i)
                let o: CGFloat = pressed == i ? 1 : 0
                NSColor.black.setFill()
                let c = CGPoint(x: r.midX + o, y: r.midY + o)
                switch i {
                case 0:   // ×
                    let x = NSBezierPath()
                    x.move(to: CGPoint(x: c.x - 4, y: c.y - 3.5)); x.line(to: CGPoint(x: c.x + 3, y: c.y + 3.5))
                    x.move(to: CGPoint(x: c.x + 3, y: c.y - 3.5)); x.line(to: CGPoint(x: c.x - 4, y: c.y + 3.5))
                    x.lineWidth = 2; NSColor.black.setStroke(); x.stroke()
                case 1:   // _
                    CGRect(x: c.x - 4, y: c.y + 2, width: 7, height: 2).fill()
                default:  // □
                    let s = CGRect(x: c.x - 5, y: c.y - 4.5, width: 9, height: 8)
                    NSColor.black.setStroke(); NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    CGRect(x: s.minX, y: s.minY, width: s.width, height: 2).fill()
                }
            }
        case .platinum:
            Chrome.pinstripes(b, active: active)
            NSColor(white: 0.53, alpha: 1).setFill(); CGRect(x: 0, y: b.maxY - 1, width: b.width, height: 1).fill()
            let t = NSAttributedString(string: title, attributes: titleAttributes(.black))
            let tw = t.size().width
            let patch = CGRect(x: (b.midX - tw / 2 - 8).rounded(), y: 2, width: tw + 16, height: b.height - 4)
            Ink.window.setFill(); patch.fill()
            t.draw(at: CGPoint(x: patch.minX + 8, y: (b.midY - t.size().height / 2).rounded()))
            guard active else { return }
            for (i, r) in bs.enumerated() {
                Ink.window.setFill(); r.insetBy(dx: -2, dy: -2).fill()
                Chrome.edges(r, tl: NSColor(white: 0.4, alpha: 1), br: .white)
                let inner = r.insetBy(dx: 1, dy: 1)
                (pressed == i ? NSGradient(starting: NSColor(white: 0.55, alpha: 1), ending: NSColor(white: 0.75, alpha: 1))!
                              : NSGradient(starting: .white, ending: NSColor(white: 0.73, alpha: 1))!).draw(in: inner, angle: -90)
                NSColor.black.setStroke(); NSBezierPath(rect: inner.insetBy(dx: 0.5, dy: 0.5)).stroke()
                if i == 2 {   // the zoom box's inner square
                    NSBezierPath(rect: CGRect(x: inner.minX + 0.5, y: inner.minY + 0.5, width: 6, height: 6)).stroke()
                } else if i == 1 {   // the window-shade box's bar
                    NSColor.black.setFill(); CGRect(x: inner.minX, y: inner.midY - 1, width: inner.width, height: 2).fill()
                }
            }
        case .glass:
            let g = NSGradient(colors: [NSColor(white: 1, alpha: 0.85), NSColor(srgbRed: 0.78, green: 0.9, blue: 0.98, alpha: 0.8),
                                        NSColor(srgbRed: 0.62, green: 0.83, blue: 0.96, alpha: 0.75)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
            g.draw(in: b, angle: -90)
            NSColor.white.withAlphaComponent(0.9).setFill(); CGRect(x: 0, y: 0, width: b.width, height: 1).fill()
            NSColor(srgbRed: 0.45, green: 0.7, blue: 0.88, alpha: 0.8).setFill(); CGRect(x: 0, y: b.maxY - 1, width: b.width, height: 1).fill()
            let t = NSAttributedString(string: title, attributes: [.font: uiFont(bold: false), .foregroundColor: NSColor(srgbRed: 0.04, green: 0.18, blue: 0.29, alpha: active ? 1 : 0.55),
                                                                 .shadow: { let s = NSShadow(); s.shadowColor = .white; s.shadowBlurRadius = 6; return s }()])
            t.draw(at: CGPoint(x: 14, y: (b.midY - t.size().height / 2).rounded()))
            for (i, r) in bs.enumerated() {
                let red = NSColor(srgbRed: 0.85, green: 0.25, blue: 0.2, alpha: 1)
                Chrome.gloss(r, radius: 4, tint: i == 0 ? red : NSColor(srgbRed: 0.62, green: 0.82, blue: 0.95, alpha: 1), down: pressed == i)
                let c = CGPoint(x: r.midX, y: r.midY + 0.5)
                let p = NSBezierPath()
                switch i {
                case 0:
                    p.move(to: CGPoint(x: c.x - 4, y: c.y - 3.5)); p.line(to: CGPoint(x: c.x + 4, y: c.y + 3.5))
                    p.move(to: CGPoint(x: c.x + 4, y: c.y - 3.5)); p.line(to: CGPoint(x: c.x - 4, y: c.y + 3.5))
                case 1:
                    p.move(to: CGPoint(x: c.x - 4, y: c.y + 3)); p.line(to: CGPoint(x: c.x + 4, y: c.y + 3))
                default:
                    p.appendRect(CGRect(x: c.x - 4.5, y: c.y - 3.5, width: 9, height: 7))
                }
                p.lineWidth = 2
                let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 2
                NSGraphicsContext.saveGraphicsState(); sh.set()
                NSColor.white.setStroke(); p.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }
        default:
            break
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = buttons().firstIndex(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) else {
            if e.clickCount == 2 {
                // Respect the user's double-click setting (zoom or minimise), as the real title bar does.
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.miniaturize(nil) } else if action != "None" { window?.zoom(nil) }
            } else {
                window?.performDrag(with: e)
            }
            return
        }
        // Track the press like a real button: it fires only if released inside.
        pressed = i; needsDisplay = true
        var inside = true
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(ev.locationInWindow, from: nil)
            inside = buttons()[i].insetBy(dx: -2, dy: -2).contains(q)
            pressed = inside ? i : nil; needsDisplay = true
            if ev.type == .leftMouseUp { break }
        }
        pressed = nil; needsDisplay = true
        guard inside, let w = window else { return }
        let role = Look.current == .platinum ? [0, 1, 2][i] : i   // close, minimise/shade, zoom
        switch role {
        case 0: if w.delegate?.windowShouldClose?(w) ?? true { w.close() }
        case 1: w.miniaturize(nil)
        default: w.zoom(nil)
        }
    }
}

/// Dress a window for the current look: the system title bar (Tianmu, Native) or our own (the rest).
func dressWindow(_ w: NSWindow) {
    let own = Look.current.ownsTitleBar
    if own { w.styleMask.insert(.fullSizeContentView) } else { w.styleMask.remove(.fullSizeContentView) }
    w.titlebarAppearsTransparent = Look.current != .native
    w.titleVisibility = Look.current == .native ? .visible : .hidden
    for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = own }
    w.appearance = Look.current.appearance
    w.backgroundColor = Look.current == .glass ? NSColor(srgbRed: 0.86, green: 0.94, blue: 0.98, alpha: 1) : Ink.window
    w.tabbingMode = own ? .disallowed : .preferred
}
