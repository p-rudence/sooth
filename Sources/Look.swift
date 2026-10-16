// The five looks Sooth can wear. Everything on screen is drawn from a few shared parts (`Ink`, `uiFont`,
// `Strip`, `Hairline`, the panels' frames), so a look is a palette, a font and a way of drawing those parts.

import AppKit

enum Look: String, CaseIterable {
    /// OLED black, the IBM VGA 8×16 font, `[bracket]` buttons: the house look shared with the other Tianmu Labs apps.
    case tianmu
    /// Mac OS 8: platinum grey, pinstriped title bars, lavender highlights, Geneva.
    case platinum
    /// Windows 95/98: battleship grey bevels, a navy title bar, Microsoft Sans Serif.
    case bevel
    /// Frutiger Aero: sky-blue glass, gloss and bubbles, Lucida Grande.
    case glass
    /// Today's macOS: the system font and colours, light or dark, your accent colour.
    case native

    var title: String {
        switch self {
        case .tianmu: "Tianmu"
        case .platinum: "Platinum"
        case .bevel: "Bevel"
        case .glass: "Glass"
        case .native: "Native"
        }
    }

    var blurb: String {
        switch self {
        case .tianmu: "OLED black and an old IBM pixel font. The house look of Tianmu Labs."
        case .platinum: "Pinstripes, lavender and Geneva, like a Mac in 1998."
        case .bevel: "Grey bevels and a navy title bar, like a PC in 1995."
        case .glass: "Glossy sky-blue glass and bubbles, from the Frutiger Aero years."
        case .native: "Today's macOS: the system font, light or dark, your accent colour."
        }
    }

    private static let key = "look"
    /// Headless runs (self-test, tour, bench) always use the house look so their output never depends on a setting.
    private static var headless: Bool {
        CommandLine.arguments.contains { ["--selftest", "--bench", "--export", "--demo", "--tour"].contains($0) }
    }
    static var current: Look = {
        if headless { return .tianmu }
        return UserDefaults.standard.string(forKey: key).flatMap(Look.init(rawValue:)) ?? .tianmu
    }()
    /// False until someone has picked a look (the first launch asks).
    static var chosen: Bool { headless || UserDefaults.standard.string(forKey: key) != nil }

    static func choose(_ l: Look) {
        UserDefaults.standard.set(l.rawValue, forKey: key)
        guard l != current else { return }
        current = l
        NotificationCenter.default.post(name: .lookChanged, object: nil)
    }

    /// The retro looks draw their own title bar instead of the system's.
    var ownsTitleBar: Bool { self == .platinum || self == .bevel || self == .glass }
    /// Tools as pictures rather than words.
    var iconTools: Bool { self != .tianmu }
    var isDark: Bool {
        switch self {
        case .tianmu: true
        case .native: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        default: false
        }
    }
    /// nil follows the system (Native only).
    var appearance: NSAppearance? {
        switch self {
        case .tianmu: NSAppearance(named: .darkAqua)
        case .native: nil
        default: NSAppearance(named: .aqua)
        }
    }
}

extension Notification.Name {
    static let lookChanged = Notification.Name("SoothLookChanged")
}

// MARK: - Palette

/// The colours a look paints with. `Ink`'s names are the house roles: `text` brightest, then `soft`, `name`,
/// `dim`, `faint`; `line` for rules, `pick` behind a selected row, `well` behind a field.
struct Palette {
    var window: NSColor
    var canvas: NSColor
    var text, soft, name, dim, faint, line, pick, pickText, well: NSColor
    var accent: NSColor

    static func of(_ l: Look) -> Palette {
        func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
        }
        switch l {
        case .tianmu:
            return Palette(window: .black, canvas: .black,
                           text: NSColor(white: 0.92, alpha: 1), soft: NSColor(white: 0.8, alpha: 1), name: NSColor(white: 0.55, alpha: 1),
                           dim: NSColor(white: 0.32, alpha: 1), faint: NSColor(white: 0.18, alpha: 1), line: NSColor(white: 0.13, alpha: 1),
                           pick: NSColor(white: 0.16, alpha: 1), pickText: NSColor(white: 0.92, alpha: 1), well: NSColor(white: 0.07, alpha: 1),
                           accent: NSColor(white: 0.8, alpha: 1))
        case .platinum:
            return Palette(window: hex(0xDDDDDD), canvas: hex(0xA6A6A6),
                           text: .black, soft: hex(0x111111), name: hex(0x222222), dim: hex(0x777777), faint: hex(0xAAAAAA),
                           line: hex(0x888888), pick: hex(0xCCCCFF), pickText: .black, well: .white, accent: hex(0x6666CC))
        case .bevel:
            return Palette(window: hex(0xC0C0C0), canvas: hex(0x808080),
                           text: .black, soft: .black, name: hex(0x111111), dim: hex(0x808080), faint: hex(0xA8A8A8),
                           line: hex(0x808080), pick: hex(0x000080), pickText: .white, well: .white, accent: hex(0x000080))
        case .glass:
            return Palette(window: hex(0xDCEFFB), canvas: hex(0xBFE3F7),
                           text: hex(0x0B2F4A), soft: hex(0x123E60), name: hex(0x2B5877), dim: hex(0x6F92AB), faint: hex(0xA9CDE3),
                           line: hex(0x8FC3E3), pick: hex(0xB7E0FF), pickText: hex(0x0B2F4A), well: NSColor(white: 1, alpha: 0.9),
                           accent: hex(0x1E8FE0))
        case .native:
            return Palette(window: .windowBackgroundColor, canvas: .underPageBackgroundColor,
                           text: .labelColor, soft: .labelColor, name: .secondaryLabelColor, dim: .tertiaryLabelColor,
                           faint: .quaternaryLabelColor, line: .separatorColor, pick: .unemphasizedSelectedContentBackgroundColor,
                           pickText: .labelColor, well: .textBackgroundColor, accent: .controlAccentColor)
        }
    }

    private static var cached: (Look, Palette)?
    static var current: Palette {
        if let (l, p) = cached, l == Look.current { return p }
        let p = of(Look.current)
        cached = (Look.current, p)
        return p
    }
}

// MARK: - Type

private var registeredBundledFonts = false

/// Registers the fonts that ship inside the app (the VGA font), once.
func registerBundledFonts() {
    guard !registeredBundledFonts else { return }
    registeredBundledFonts = true
    let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
    guard let dir, let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for u in urls where ["ttf", "otf"].contains(u.pathExtension.lowercased()) {
        CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
    }
}

/// The look's interface font. `uiSize` stays the layout unit (row heights are built on it).
func uiFont(_ size: CGFloat = uiSize, bold: Bool = false) -> NSFont {
    registerBundledFonts()
    let scale = size / uiSize
    switch Look.current {
    case .tianmu:
        return NSFont(name: pixelFontName, size: size) ?? .monospacedSystemFont(ofSize: size * 0.8, weight: bold ? .bold : .regular)
    case .platinum:
        let f = NSFont(name: "Geneva", size: 12 * scale) ?? .systemFont(ofSize: 12 * scale)
        return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
    case .bevel:
        if bold { return NSFont(name: "Tahoma-Bold", size: 12 * scale) ?? .boldSystemFont(ofSize: 12 * scale) }
        return NSFont(name: "MicrosoftSansSerif", size: 12 * scale) ?? .systemFont(ofSize: 12 * scale)
    case .glass:
        return NSFont(name: bold ? "LucidaGrande-Bold" : "LucidaGrande", size: 12 * scale) ?? .systemFont(ofSize: 12 * scale, weight: bold ? .bold : .regular)
    case .native:
        return .systemFont(ofSize: 12 * scale, weight: bold ? .semibold : .regular)
    }
}

/// Geneva has no bold on today's Macs; Mac OS 8's titles were heavy, so thicken the strokes instead.
func titleAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
    var a: [NSAttributedString.Key: Any] = [.font: uiFont(bold: true), .foregroundColor: color]
    if Look.current == .platinum { a[.strokeWidth] = -2.5; a[.strokeColor] = color }
    return a
}

extension Look {
    /// The house look writes in lower case; the others start each label with a capital.
    func word(_ s: String) -> String {
        guard self != .tianmu, let f = s.first else { return s }
        switch s {
        case "b/w": return "B/W"
        case "remove bg": return "Remove BG"
        case "props": return "Properties"
        case "del": return "Delete"
        case "dup": return "Dup"
        case "adj": return "Adjust"
        default: return f.uppercased() + s.dropFirst()
        }
    }
}

// MARK: - Drawing the parts

enum Chrome {
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }

    /// Two one-pixel edges: `tl` along the top and left, `br` along the bottom and right (flipped views).
    static func edges(_ r: CGRect, tl: NSColor, br: NSColor) {
        tl.setFill()
        CGRect(x: r.minX, y: r.minY, width: r.width - 1, height: 1).fill()
        CGRect(x: r.minX, y: r.minY, width: 1, height: r.height - 1).fill()
        br.setFill()
        CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1).fill()
        CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height).fill()
    }

    /// The Windows 95 raised edge (buttons, title-bar boxes), or sunken when `down`.
    static func bevel(_ r: CGRect, down: Bool = false, face: NSColor? = hex(0xC0C0C0)) {
        if let face { face.setFill(); r.fill() }
        if down {
            edges(r, tl: .black, br: .white)
            edges(r.insetBy(dx: 1, dy: 1), tl: hex(0x808080), br: hex(0xDFDFDF))
        } else {
            edges(r, tl: .white, br: .black)
            edges(r.insetBy(dx: 1, dy: 1), tl: hex(0xDFDFDF), br: hex(0x808080))
        }
    }

    /// The Windows 95 well: a white field sunk into the grey.
    static func well95(_ r: CGRect, fill: NSColor = .white) {
        fill.setFill(); r.fill()
        edges(r, tl: hex(0x808080), br: .white)
        edges(r.insetBy(dx: 1, dy: 1), tl: hex(0x404040), br: hex(0xDFDFDF))
    }

    /// The etched line Windows draws round a group of controls.
    static func etched(_ r: CGRect) {
        hex(0x808080).setStroke()
        let a = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5).offsetBy(dx: 0, dy: 0)); a.lineWidth = 1
        let inner = CGRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 1, height: r.height - 1)
        NSColor.white.setStroke()
        let b = NSBezierPath(rect: inner.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1; b.stroke()
        hex(0x808080).setStroke(); a.stroke()
    }

    /// The pressed-toggle dither Windows 95 used for a tool that's on.
    static let dither: NSColor = {
        let img = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { r in
            NSColor.white.setFill(); r.fill()
            hex(0xC0C0C0).setFill()
            CGRect(x: 0, y: 0, width: 1, height: 1).fill(); CGRect(x: 1, y: 1, width: 1, height: 1).fill()
            return true
        }
        return NSColor(patternImage: img)
    }()

    /// A Mac OS 8 push button: rounded, black-rimmed, light-to-grey shading; darker when pressed.
    static func platinumButton(_ r: CGRect, down: Bool = false) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        let g = down ? NSGradient(starting: hex(0x9A9AB0), ending: hex(0xB8B8C8))!
                     : NSGradient(starting: hex(0xF4F4F4), ending: hex(0xC8C8C8))!
        g.draw(in: p, angle: -90)
        if !down {
            NSColor.white.setStroke()
            let hi = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: 2.5, yRadius: 2.5); hi.lineWidth = 1; hi.stroke()
        }
        hex(0x222222).setStroke(); p.lineWidth = 1; p.stroke()
    }

    /// The Mac OS 8 inset field.
    static func platinumWell(_ r: CGRect) {
        NSColor.white.setFill(); r.fill()
        edges(r, tl: hex(0x777777), br: .white)
        edges(r.insetBy(dx: 1, dy: 1), tl: .black, br: hex(0xDDDDDD))
    }

    /// Mac OS 8 title-bar pinstripes, in `r`.
    static func pinstripes(_ r: CGRect, active: Bool = true) {
        hex(0xDDDDDD).setFill(); r.fill()
        guard active else { return }
        var y = r.minY + 3
        while y + 2 <= r.maxY - 2 {
            NSColor.white.setFill(); CGRect(x: r.minX, y: y, width: r.width, height: 1).fill()
            hex(0x999999).setFill(); CGRect(x: r.minX, y: y + 1, width: r.width, height: 1).fill()
            y += 2
        }
    }

    /// Frutiger Aero gloss: a rounded capsule, a bright upper half, a soft coloured lower half.
    static func gloss(_ r: CGRect, radius: CGFloat? = nil, tint: NSColor = hex(0x8ED0FF), down: Bool = false, on: Bool = false) {
        let rad = radius ?? min(r.height / 2, 9)
        let shape = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: rad, yRadius: rad)
        let base = on ? hex(0x6CC6FF) : tint
        let bottom = down ? base.blended(withFraction: 0.25, of: hex(0x1F6FB0))! : base
        NSGradient(colors: [NSColor.white, NSColor.white.blended(withFraction: 0.35, of: bottom)!, bottom.blended(withFraction: 0.15, of: .white)!, bottom],
                   atLocations: [0, 0.49, 0.5, 1], colorSpace: .sRGB)!.draw(in: shape, angle: -90)
        // A soft glow along the bottom, the light passing through the glass.
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.55)])!
        glow.draw(in: CGRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        hex(0x3D8BC7, 0.9).setStroke(); shape.lineWidth = 1; shape.stroke()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let inner = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: max(0, rad - 1), yRadius: max(0, rad - 1))
        inner.lineWidth = 1; inner.stroke()
    }

    /// A pane of Aero glass: frosted white over the sky, a bright rim.
    static func glassPane(_ r: CGRect, radius: CGFloat = 8) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.72), ending: NSColor.white.withAlphaComponent(0.48))!.draw(in: p, angle: -90)
        hex(0x7FBCE6, 0.85).setStroke(); p.lineWidth = 1; p.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let inner = NSBezierPath(roundedRect: r.insetBy(dx: 1.5, dy: 1.5), xRadius: radius - 1, yRadius: radius - 1)
        inner.lineWidth = 1; inner.stroke()
    }

    /// The Aero sky: a cool gradient, a soft aurora sweep and a scatter of bubbles.
    static func sky(_ r: CGRect, bubbles: Bool = true) {
        NSGradient(colors: [hex(0xEAF7FF), hex(0xC4E8FB), hex(0x9BD6F3)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
            .draw(in: r, angle: -90)
        let sweep = NSBezierPath()
        sweep.move(to: CGPoint(x: r.minX, y: r.maxY * 0.78))
        sweep.curve(to: CGPoint(x: r.maxX, y: r.maxY * 0.55), controlPoint1: CGPoint(x: r.width * 0.35, y: r.maxY * 0.6),
                    controlPoint2: CGPoint(x: r.width * 0.6, y: r.maxY * 0.9))
        sweep.line(to: CGPoint(x: r.maxX, y: r.maxY)); sweep.line(to: CGPoint(x: r.minX, y: r.maxY)); sweep.close()
        NSGradient(starting: hex(0x9EE37D, 0.35), ending: hex(0x3FB5A9, 0.25))!.draw(in: sweep, angle: 0)
        guard bubbles else { return }
        // Fixed positions (fractions of the area), so the bubbles don't jump about on every redraw.
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(0.08, 0.2, 26), (0.18, 0.72, 14), (0.83, 0.16, 34), (0.92, 0.62, 18),
                                                     (0.66, 0.84, 22), (0.4, 0.1, 10), (0.55, 0.35, 8), (0.28, 0.45, 6)]
        for (fx, fy, d) in spots {
            let c = CGRect(x: r.minX + fx * r.width - d / 2, y: r.minY + fy * r.height - d / 2, width: d, height: d)
            let b = NSBezierPath(ovalIn: c)
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.05), NSColor.white.withAlphaComponent(0.35)])!.draw(in: b, relativeCenterPosition: .zero)
            NSColor.white.withAlphaComponent(0.6).setStroke(); b.lineWidth = 1; b.stroke()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.minX + d * 0.22, y: c.minY + d * 0.18, width: d * 0.22, height: d * 0.16)).fill()
        }
    }

    /// Today's macOS bordered button.
    static func nativeButton(_ r: CGRect, down: Bool = false, on: Bool = false) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        (on ? NSColor.controlAccentColor : (down ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor.withAlphaComponent(0.6))).setFill()
        p.fill()
        if !on { NSColor.separatorColor.setStroke(); p.lineWidth = 1; p.stroke() }
    }

    static func nativeWell(_ r: CGRect) {
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.setFill(); p.fill()
        NSColor.separatorColor.setStroke(); p.lineWidth = 1; p.stroke()
    }

    // MARK: Composite parts, per look

    /// A push button in the current look.
    static func button(_ r: CGRect, down: Bool = false, on: Bool = false) {
        switch Look.current {
        case .tianmu: break
        case .bevel:
            if on { bevel(r, down: true, face: nil); dither.setFill(); r.insetBy(dx: 2, dy: 2).fill() } else { bevel(r, down: down) }
        case .platinum: platinumButton(r, down: down || on)
        case .glass: gloss(r, down: down, on: on)
        case .native: nativeButton(r, down: down, on: on)
        }
    }

    /// A field (number, hex) in the current look.
    static func well(_ r: CGRect) {
        switch Look.current {
        case .tianmu: Palette.current.well.setFill(); r.fill()
        case .bevel: well95(r)
        case .platinum: platinumWell(r)
        case .glass:
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.white.setFill(); p.fill(); hex(0x6FAED8).setStroke(); p.lineWidth = 1; p.stroke()
        case .native: nativeWell(r)
        }
    }

    /// A checkbox, `r` square.
    static func checkbox(_ r: CGRect, on: Bool) {
        switch Look.current {
        case .tianmu: break
        case .bevel: well95(r)
        case .platinum: platinumWell(r)
        case .glass:
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSGradient(starting: .white, ending: hex(0xD8EEFB))!.draw(in: p, angle: -90)
            hex(0x5A9CCB).setStroke(); p.lineWidth = 1; p.stroke()
        case .native:
            let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            (on ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill(); p.fill()
            if !on { NSColor.separatorColor.setStroke(); p.lineWidth = 1; p.stroke() }
        }
        guard on else { return }
        let ink: NSColor = Look.current == .native ? .white : (Look.current == .glass ? hex(0x1A6FB0) : .black)
        let m = NSBezierPath()
        m.move(to: CGPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.52))
        m.line(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.72))
        m.line(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.28))
        m.lineWidth = Look.current == .native ? 1.8 : 2
        m.lineCapStyle = Look.current == .bevel ? .square : .round
        ink.setStroke(); m.stroke()
    }

    /// A radio button, `r` square.
    static func radio(_ r: CGRect, on: Bool) {
        let o = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
        switch Look.current {
        case .tianmu: return
        case .bevel:
            NSColor.white.setFill(); o.fill()
            hex(0x808080).setStroke(); o.lineWidth = 1; o.stroke()
            hex(0x404040).setStroke()
            let arc = NSBezierPath(); arc.appendArc(withCenter: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2 - 1.5, startAngle: 135, endAngle: 315, clockwise: true)
            arc.lineWidth = 1; arc.stroke()
        case .platinum:
            NSGradient(starting: .white, ending: hex(0xCCCCCC))!.draw(in: o, angle: -90)
            hex(0x222222).setStroke(); o.lineWidth = 1; o.stroke()
        case .glass:
            NSGradient(starting: .white, ending: hex(0xCDEBFF))!.draw(in: o, angle: -90)
            hex(0x5A9CCB).setStroke(); o.lineWidth = 1; o.stroke()
        case .native:
            (on ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill(); o.fill()
            if !on { NSColor.separatorColor.setStroke(); o.lineWidth = 1; o.stroke() }
        }
        guard on else { return }
        let dot = r.insetBy(dx: r.width * 0.3, dy: r.height * 0.3)
        (Look.current == .native ? NSColor.white : (Look.current == .glass ? hex(0x1A6FB0) : .black)).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    /// The down-arrow on a pop-up menu button, centred in `r`.
    static func popupArrow(_ r: CGRect, _ c: NSColor) {
        let w: CGFloat = 7, h: CGFloat = 4
        let p = NSBezierPath()
        p.move(to: CGPoint(x: r.midX - w / 2, y: r.midY - h / 2))
        p.line(to: CGPoint(x: r.midX + w / 2, y: r.midY - h / 2))
        p.line(to: CGPoint(x: r.midX, y: r.midY + h / 2))
        p.close()
        c.setFill(); p.fill()
    }

    /// A rule between regions: one hairline in the flat looks, an etched pair in the 90s ones.
    static func rule(_ r: CGRect, vertical: Bool) {
        switch Look.current {
        case .bevel, .platinum:
            let a = Look.current == .bevel ? hex(0x808080) : hex(0x999999)
            if vertical {
                a.setFill(); CGRect(x: r.minX, y: r.minY, width: 1, height: r.height).fill()
                NSColor.white.setFill(); CGRect(x: r.minX + 1, y: r.minY, width: 1, height: r.height).fill()
            } else {
                a.setFill(); CGRect(x: r.minX, y: r.minY, width: r.width, height: 1).fill()
                NSColor.white.setFill(); CGRect(x: r.minX, y: r.minY + 1, width: r.width, height: 1).fill()
            }
        case .glass:
            NSColor.white.withAlphaComponent(0.7).setFill(); r.fill()
        default:
            Palette.current.line.setFill(); r.fill()
        }
    }

    /// How thick `rule` is.
    static var ruleWidth: CGFloat { Look.current == .bevel || Look.current == .platinum ? 2 : 1 }
}

// MARK: - Tool pictures

/// 16×16 pixel pictures for the tools, drawn for Sooth (no borrowed art). One character per pixel.
enum PixelArt {
    static let palette: [Character: UInt32] = [
        "k": 0x000000, "w": 0xFFFFFF, "g": 0x808080, "l": 0xC0C0C0, "d": 0x404040,
        "r": 0xE01010, "R": 0x800000, "b": 0x1040E0, "u": 0x000080, "c": 0x10C0E0, "y": 0xF8E020, "Y": 0xA08000,
        "n": 0x9A5A20, "N": 0x5A3010, "G": 0x10A030, "o": 0xF08020, "p": 0xF4A0C0, "P": 0xB05070, "s": 0xE8C8A0,
    ]

    static func image(_ rows: [String], scale: CGFloat = 1) -> NSImage {
        let h = rows.count, w = rows.map(\.count).max() ?? 0
        return NSImage(size: NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale), flipped: true) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let v = palette[ch] else { continue }
                    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1).setFill()
                    CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale).fill()
                }
            }
            return true
        }
    }

    static let art: [ToolKind: [String]] = [
        .moveSelected: [
            ".......k........",
            "......kwk.......",
            ".....kwwwk......",
            "....kkkwkkk.....",
            ".......w........",
            "...k...w...k....",
            "..kk...w...kk...",
            ".kwwwwwwwwwwwk..",
            "..kk...w...kk...",
            "...k...w...k....",
            ".......w........",
            "....kkkwkkk.....",
            ".....kwwwk......",
            "......kwk.......",
            ".......k........",
            "................",
        ],
        .moveSelection: [
            "k.kk.kk.kk.kk...",
            "................",
            "k...........k...",
            "k.....k.....k...",
            ".....kkk........",
            "k...k.k.k...k...",
            "k..kkkkkkk..k...",
            "....k.k.k.......",
            "k....kkk....k...",
            "k.....k.....k...",
            "................",
            "k.kk.kk.kk.kk...",
            "................",
            "................",
            "................",
            "................",
        ],
        .rectSelect: [
            "................",
            ".kk.kk.kk.kk.kk.",
            ".k.............k",
            "................",
            ".k.............k",
            ".k.............k",
            "................",
            ".k.............k",
            ".k.............k",
            "................",
            ".k.............k",
            ".k.............k",
            "................",
            ".kk.kk.kk.kk.kk.",
            "................",
            "................",
        ],
        .ellipseSelect: [
            "................",
            ".....kk.kk......",
            "...k.......k....",
            "..k.........k...",
            ".k...........k..",
            "................",
            "k.............k.",
            "k.............k.",
            "................",
            ".k...........k..",
            "..k.........k...",
            "...k.......k....",
            ".....kk.kk......",
            "................",
            "................",
            "................",
        ],
        .lasso: [
            "................",
            "....kkkkkk......",
            "..kk......kk....",
            ".k..........k...",
            "k............k..",
            "k............k..",
            ".k..........k...",
            "..kk.....kkk....",
            "....kkkkk.......",
            "......k.........",
            ".....k..........",
            "....k.k.........",
            "....k..k........",
            ".....kk.........",
            "................",
            "................",
        ],
        .magicWand: [
            "..........y.....",
            "......y...y...y.",
            ".......y..y..y..",
            "........yyyyy...",
            ".....yyyyywyyyyy",
            "........yyyyy...",
            ".......kky..y...",
            "......kwky...y..",
            ".....kwk..y.....",
            "....kwk.........",
            "...kwk..........",
            "..kwk...........",
            ".kwk............",
            "kwk.............",
            "kk..............",
            "................",
        ],
        .zoom: [
            "....kkkk........",
            "..kkwwwwkk......",
            ".kwwccwwwwk.....",
            ".kwcwwwwwwk.....",
            "kwwcwwwwwwwk....",
            "kwwwwwwwwwwk....",
            "kwwwwwwwwwwk....",
            "kwwwwwwwwwwk....",
            ".kwwwwwwwwk.....",
            ".kwwwwwwwwk.....",
            "..kkwwwwkkk.....",
            "....kkkk.kNk....",
            ".........kNNk...",
            "..........kNNk..",
            "...........kNNk.",
            "............kk..",
        ],
        .pan: [
            "......kk........",
            "...kk.kwk.kk....",
            "..kwwkkwkkwwk...",
            "..kwwkkwkkwwk...",
            "..kwwkkwkkwwkk..",
            "..kwwkkwkkwwkwk.",
            "..kwwwwwwwwwkwk.",
            "kkkwwwwwwwwwwwk.",
            "kwwkwwwwwwwwwwk.",
            "kwwwwwwwwwwwwwk.",
            ".kwwwwwwwwwwwk..",
            "..kwwwwwwwwwwk..",
            "...kwwwwwwwwk...",
            "....kwwwwwwwk...",
            "....kwwwwwwwk...",
            "....kkkkkkkkk...",
        ],
        .bucket: [
            "................",
            "......kk........",
            ".....kllk.......",
            "....klwllk......",
            "...klwwwllk.....",
            "..klwwwwwllk....",
            ".kllwwwwwwllkbb.",
            "kgllwwwwwwwlkbbb",
            ".kgllwwwwwlkbbbb",
            "..kgllwwwlk.bbbb",
            "...kgllllk..bbb.",
            "....kgllk...bbb.",
            ".....kgk....bb..",
            "......k.....b...",
            "................",
            "................",
        ],
        .gradient: [
            "................",
            "kkkkkkkkkkkkkkkk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kwwwwllllggggddk",
            "kkkkkkkkkkkkkkkk",
            "................",
            "................",
        ],
        .brush: [
            "..............kk",
            ".............knk",
            "............knk.",
            "...........knk..",
            "..........knk...",
            ".........knk....",
            "........knk.....",
            ".......knk......",
            "......kllk......",
            ".....kllk.......",
            "....kbbk........",
            "...kbbbk........",
            "..kbbbk.........",
            ".kbbbk..........",
            ".kbbk...........",
            "kkk.............",
        ],
        .eraser: [
            "................",
            "................",
            ".......kkkkkkkk.",
            "......kwwwwwwkk.",
            ".....kwwwwwwkpk.",
            "....kwwwwwwkppk.",
            "...kkkkkkkkpppk.",
            "..kppppppkpppk..",
            ".kppppppkpppk...",
            "kppppppkpppk....",
            "kppppppkppk.....",
            "kppppppkpk......",
            "kPPPPPPkk.......",
            "kkkkkkkk........",
            "................",
            "................",
        ],
        .pencil: [
            ".............kk.",
            "............krrk",
            "...........kRrrk",
            "..........klkRk.",
            ".........kylkk..",
            "........kyyk....",
            ".......kyyk.....",
            "......kyyk......",
            ".....kyyk.......",
            "....kyyk........",
            "...kYyk.........",
            "..ksYk..........",
            "..kssk..........",
            ".kdsk...........",
            ".kkk............",
            "................",
        ],
        .picker: [
            "............kkk.",
            "...........kkkkk",
            "..........kkkkkk",
            "........kkkkkkkk",
            ".........kkkkkk.",
            "........kwkkkk..",
            ".......kwwwk.k..",
            "......kwwwk.....",
            ".....kwwwk......",
            "....kwwwk.......",
            "...kwwwk........",
            "..kbbbk.........",
            ".kbbbk..........",
            ".kbbk...........",
            "kkk.............",
            "................",
        ],
        .clone: [
            "......kkkk......",
            ".....knnnnk.....",
            ".....knnnnk.....",
            ".....knnnnk.....",
            "......knnk......",
            "......knnk......",
            "......knnk......",
            "...kkkkkkkkkk...",
            "..knnnnnnnnnnk..",
            "..kkkkkkkkkkkk..",
            "..krrrrrrrrrrk..",
            "..kkkkkkkkkkkk..",
            "................",
            "...rr..rr..rr...",
            "...rr..rr..rr...",
            "................",
        ],
        .recolor: [
            "..............kk",
            ".............knk",
            "............knk.",
            "...........knk..",
            "..........knk...",
            ".........knk....",
            "........kllk....",
            ".......kllk.....",
            "......krrk......",
            ".....krrrk......",
            "....krrrk.......",
            "...krrk.........",
            "................",
            ".bbbb.k...rrrr..",
            ".bbbb.kk..rrrr..",
            ".bbbb.k...rrrr..",
        ],
        .text: [
            "................",
            "....kkkkkkkk....",
            "....k..kk..k....",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            ".......kk.......",
            "......kkkk......",
            "................",
            "................",
            "................",
            "................",
        ],
        .line: [
            "................",
            "..............k.",
            ".............kk.",
            "............kk..",
            "...........kk...",
            "..........kk....",
            ".........kk.....",
            "........kk......",
            ".......kk.......",
            "......kk........",
            ".....kk.........",
            "....kk..........",
            "...kk...........",
            "..kk............",
            ".k..............",
            "................",
        ],
        .shapes: [
            "................",
            ".kkkkkkkk.......",
            ".kbbbbbbk.......",
            ".kbbbbbbk.......",
            ".kbbbbbbk.......",
            ".kbbbbkkkkk.....",
            ".kbbbkrrrrrk....",
            ".kbbkrrrrrrrk...",
            ".kkkkrrrrrrrk...",
            "....krrrrrrrk...",
            "....krrrrrrrk...",
            ".....krrrrrk....",
            "......kkkkk.....",
            "................",
            "................",
            "................",
        ],
    ]

    private static var cache: [ToolKind: NSImage] = [:]
    static func icon(_ t: ToolKind) -> NSImage {
        if let i = cache[t] { return i }
        let i = image(art[t] ?? [])
        cache[t] = i
        return i
    }
}

extension ToolKind {
    /// The picture for the current look (the pixel art when a symbol is missing on this macOS).
    func icon(size: CGFloat = 15, color: NSColor? = nil) -> NSImage {
        if Look.current == .bevel || Look.current == .platinum { return PixelArt.icon(self) }
        guard var img = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)
        else { return PixelArt.icon(self) }
        var cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        if let color { cfg = cfg.applying(.init(paletteColors: [color])) }
        img = img.withSymbolConfiguration(cfg) ?? img
        return img
    }
}
