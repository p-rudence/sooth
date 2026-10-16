import AppKit

/// Draws glyphs with the spec's effects: glow, then (inside the drop shadow) the outer outline,
/// the outline, and a solid or gradient fill. The live editor and the committed pixels both draw
/// through this, so what you see is what you get.
final class StyledLayoutManager: NSLayoutManager {
    var spec = TextSpec()
    /// The laid-out text's rectangle in container coordinates (the gradient spans all of it).
    var textRect = CGRect.zero
    private var origin = CGPoint.zero

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        self.origin = origin
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count: Int,
                               font: NSFont, textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any] = [:], in ctx: CGContext) {
        let s = spec
        // Shadow and glow sizes live in device space; scale them so they keep their size at any zoom.
        let m = ctx.userSpaceToDeviceSpaceTransform
        let k = hypot(m.a, m.b)
        // The real glyph outlines (CoreText's stroke text mode is ignored when drawing like this).
        let path = CGMutablePath()
        for i in 0..<count {
            guard let g = CTFontCreatePathForGlyph(font as CTFont, glyphs[i], nil) else { continue }
            var t = textMatrix
            t.tx += positions[i].x; t.ty += positions[i].y
            path.addPath(g, transform: t)
        }
        let outer = s.outlineWidth + s.outline2Width
        func stroke(_ width: CGFloat, _ color: RGBA) {
            ctx.addPath(path)
            ctx.setLineWidth(width * 2); ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setStrokeColor(color.cg); ctx.strokePath()
        }
        ctx.saveGState()
        if s.glowSize > 0 && !path.isEmpty {
            // Two passes: a wide soft halo and a tighter bright one, like a real neon tube.
            for (blur, alpha) in [(s.glowSize, 1.0), (s.glowSize * 0.4, 0.9)] as [(CGFloat, CGFloat)] {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: blur * k, color: s.glowColor.cg.copy(alpha: s.glowColor.cg.alpha * alpha)!)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.addPath(path); ctx.setFillColor(s.glowColor.cg); ctx.fillPath()
                if outer > 0 { stroke(outer, s.glowColor) }
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        if s.shadow {
            let a = s.shadowAngle * .pi / 180
            ctx.setShadow(offset: CGSize(width: cos(a) * s.shadowDistance * k, height: -sin(a) * s.shadowDistance * k),
                          blur: s.shadowBlur * k, color: s.shadowColor.cg)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if s.outline2Width > 0 { stroke(outer, s.outline2Color) }
        if s.outlineWidth > 0 { stroke(s.outlineWidth, s.outlineColor) }
        super.showCGGlyphs(glyphs, positions: positions, count: count, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: ctx)
        if s.gradient && !path.isEmpty {
            let r = textRect.offsetBy(dx: origin.x, dy: origin.y)
            let a = s.gradientAngle * .pi / 180
            let half = (abs(r.width * cos(a)) + abs(r.height * sin(a))) / 2
            let v = CGPoint(x: cos(a) * half, y: sin(a) * half)
            let c = CGPoint(x: r.midX, y: r.midY)
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [s.color.cg, s.color2.cg] as CFArray, locations: [0, 1])!
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(g, start: c - v, end: c + v, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        if s.shadow { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }
}

final class SoothTextView: NSTextView {
    var onFinish: (() -> Void)?
    /// Caption box behind the text, in the view's own coordinates.
    var box: (rect: CGRect, radius: CGFloat, color: CGColor)?
    override func cancelOperation(_ sender: Any?) { onFinish?() }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, e.modifierFlags.contains(.command) { onFinish?(); return }
        super.keyDown(with: e)
    }
    /// Outlines, glow and shadows reach past each line's own rectangle, which is all AppKit redraws
    /// while typing; redraw the whole box so nothing gets clipped.
    override func setNeedsDisplay(_ invalidRect: NSRect) { super.setNeedsDisplay(bounds) }

    override func draw(_ dirtyRect: NSRect) {
        if let b = box, let c = NSGraphicsContext.current?.cgContext {
            c.addPath(CGPath(roundedRect: b.rect, cornerWidth: b.radius, cornerHeight: b.radius, transform: nil))
            c.setFillColor(b.color); c.fillPath()
        }
        super.draw(dirtyRect)
    }
}

/// Everything needed to draw a piece of text. Text layers keep one, so they stay editable
/// until they are flattened, merged or painted on.
struct TextSpec: Equatable, Hashable {
    var string = ""
    var fontName = "Helvetica Neue"
    var fontSize: CGFloat = 36
    var bold = false, italic = false, underline = false
    var align: TextAlign = .left
    var color = RGBA.black
    var outlineWidth: CGFloat = 0
    var outlineColor = RGBA.white
    var shadow = false
    /// Top edge of the text and its left, centre or right x, depending on alignment.
    var anchor = CGPoint.zero

    // Effects
    var gradient = false
    var color2 = RGBA(r: 255, g: 170, b: 40)
    var gradientAngle: CGFloat = 90
    var outline2Width: CGFloat = 0
    var outline2Color = RGBA.white
    var shadowColor = RGBA(r: 0, g: 0, b: 0, a: 170)
    var shadowAngle: CGFloat = 45
    var shadowDistance: CGFloat = 6
    var shadowBlur: CGFloat = 8
    var glowSize: CGFloat = 0
    var glowColor = RGBA(r: 255, g: 60, b: 200)
    var tracking: CGFloat = 0
    var lineHeight: CGFloat = 1
    var rotation: CGFloat = 0
    var box = false
    var boxColor = RGBA(r: 0, g: 0, b: 0, a: 160)
    var boxPadding: CGFloat = 12
    var boxRadius: CGFloat = 8

    func hash(into h: inout Hasher) {
        h.combine(string); h.combine(fontName); h.combine(fontSize); h.combine(bold); h.combine(italic)
        h.combine(underline); h.combine(align); h.combine(color); h.combine(outlineWidth); h.combine(outlineColor)
        h.combine(shadow); h.combine(anchor.x); h.combine(anchor.y)
        h.combine(gradient); h.combine(color2); h.combine(gradientAngle); h.combine(outline2Width); h.combine(outline2Color)
        h.combine(shadowColor); h.combine(shadowAngle); h.combine(shadowDistance); h.combine(shadowBlur)
        h.combine(glowSize); h.combine(glowColor); h.combine(tracking); h.combine(lineHeight); h.combine(rotation)
        h.combine(box); h.combine(boxColor); h.combine(boxPadding); h.combine(boxRadius)
    }

    /// The effect fields, shared by the plist, the toolbar state and presets.
    static let effectKeys: [(String, WritableKeyPath<TextSpec, CGFloat>)] = [
        ("gradientAngle", \.gradientAngle), ("outline2", \.outline2Width), ("shadowAngle", \.shadowAngle),
        ("shadowDistance", \.shadowDistance), ("shadowBlur", \.shadowBlur), ("glow", \.glowSize), ("tracking", \.tracking),
        ("lineHeight", \.lineHeight), ("rotation", \.rotation), ("boxPadding", \.boxPadding), ("boxRadius", \.boxRadius),
    ]
    static let colorKeys: [(String, WritableKeyPath<TextSpec, RGBA>)] = [
        ("color2", \.color2), ("outline2Color", \.outline2Color), ("shadowColor", \.shadowColor),
        ("glowColor", \.glowColor), ("boxColor", \.boxColor),
    ]
    static let flagKeys: [(String, WritableKeyPath<TextSpec, Bool>)] = [("gradient", \.gradient), ("box", \.box)]

    var font: NSFont {
        var f = NSFont(name: fontName, size: fontSize) ?? NSFont(name: fontName + " Regular", size: fontSize)
            ?? NSFontManager.shared.font(withFamily: fontName, traits: [], weight: 5, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let fm = NSFontManager.shared
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    var plist: [String: Any] {
        var d: [String: Any] = ["string": string, "font": fontName, "size": Double(fontSize), "bold": bold, "italic": italic,
                                "underline": underline, "align": align.rawValue, "color": color.hex,
                                "outline": Double(outlineWidth), "outlineColor": outlineColor.hex,
                                "shadow": shadow, "x": Double(anchor.x), "y": Double(anchor.y)]
        for (k, kp) in Self.effectKeys { d[k] = Double(self[keyPath: kp]) }
        for (k, kp) in Self.colorKeys { d[k] = self[keyPath: kp].hex }
        for (k, kp) in Self.flagKeys { d[k] = self[keyPath: kp] }
        return d
    }

    init() {}

    init?(plist d: [String: Any]) {
        guard let s = d["string"] as? String else { return nil }
        string = s
        fontName = d["font"] as? String ?? fontName
        fontSize = CGFloat(d["size"] as? Double ?? 36)
        bold = d["bold"] as? Bool ?? false; italic = d["italic"] as? Bool ?? false; underline = d["underline"] as? Bool ?? false
        align = TextAlign(rawValue: d["align"] as? Int ?? 0) ?? .left
        color = RGBA(hex: d["color"] as? String ?? "000000") ?? .black
        outlineWidth = CGFloat(d["outline"] as? Double ?? 0)
        outlineColor = RGBA(hex: d["outlineColor"] as? String ?? "FFFFFF") ?? .white
        shadow = d["shadow"] as? Bool ?? false
        anchor = CGPoint(x: d["x"] as? Double ?? 0, y: d["y"] as? Double ?? 0)
        for (k, kp) in Self.effectKeys { if let v = d[k] as? Double { self[keyPath: kp] = CGFloat(v) } }
        for (k, kp) in Self.colorKeys { if let v = d[k] as? String, let c = RGBA(hex: v) { self[keyPath: kp] = c } }
        for (k, kp) in Self.flagKeys { if let v = d[k] as? Bool { self[keyPath: kp] = v } }
    }
}

extension AppState {
    /// The toolbar's text style laid over `base` (keeps its string and anchor).
    func textStyle(over base: TextSpec) -> TextSpec {
        var s = textEffects
        s.string = base.string; s.anchor = base.anchor
        s.fontName = fontName; s.fontSize = fontSize; s.bold = bold; s.italic = italic; s.underline = underline
        s.align = textAlign; s.color = primary; s.outlineWidth = outlineWidth; s.outlineColor = secondary; s.shadow = textShadow
        return s
    }

    /// Put a text layer's style into the toolbar, so editing it starts from how it looks.
    func loadTextStyle(_ s: TextSpec) {
        textEffects = s
        fontName = s.fontName; fontSize = s.fontSize; bold = s.bold; italic = s.italic; underline = s.underline
        textAlign = s.align; primary = s.color; outlineWidth = s.outlineWidth; secondary = s.outlineColor; textShadow = s.shadow
        NotificationCenter.default.post(name: .textStyleLoaded, object: nil)
    }
}

extension Notification.Name {
    static let textStyleLoaded = Notification.Name("SoothTextStyleLoaded")
}

/// Lays out and draws one piece of text. It is the live editor on the canvas while editing, and
/// the renderer for text layers otherwise, so what you see is what you get.
final class TextEditor: NSObject, NSTextViewDelegate {
    let storage = NSTextStorage()
    let layout = StyledLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 1e6, height: 1e6))
    let view: SoothTextView
    var spec: TextSpec
    /// Index of the text layer being edited, or nil for new text.
    var layerIndex: Int?
    /// The layer being edited, so the text never lands on another one if the stack changed meanwhile.
    weak var layer: Layer?
    /// The spec as it was when editing began (to skip a history step when nothing changed).
    var original: TextSpec?
    private(set) var pad: CGFloat = 2

    var anchor: CGPoint {
        get { spec.anchor }
        set { spec.anchor = newValue }
    }

    var isEmpty: Bool { storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The spec with the text as typed so far.
    var current: TextSpec { var s = spec; s.string = storage.string; return s }

    init(spec: TextSpec) {
        self.spec = spec
        self.spec.anchor = CGPoint(x: spec.anchor.x.rounded(), y: spec.anchor.y.rounded())
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        view = SoothTextView(frame: CGRect(x: spec.anchor.x, y: spec.anchor.y, width: 10, height: 10), textContainer: container)
        super.init()
        view.delegate = self
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.maxSize = CGSize(width: 1e6, height: 1e6)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.usesFindBar = false
        view.focusRingType = .none
        if !spec.string.isEmpty { storage.setAttributedString(NSAttributedString(string: spec.string)) }
        applyStyle()
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.alignment = spec.align.ns
        para.lineBreakMode = .byClipping
        para.lineHeightMultiple = spec.lineHeight
        var a: [NSAttributedString.Key: Any] = [.font: spec.font, .foregroundColor: spec.color.ns, .paragraphStyle: para,
                                                .kern: spec.tracking]
        if spec.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    /// Apply the spec's style to all of the text (as Paint.NET does) and re-fit the box.
    func applyStyle() {
        let attrs = attributes
        if storage.length > 0 && !view.hasMarkedText() {
            storage.beginEditing()
            storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
        }
        view.typingAttributes = attrs
        view.insertionPointColor = spec.color == .white || spec.color.a < 128 ? .controlAccentColor : spec.color.ns
        layout.spec = spec
        let ink = spec.outlineWidth + spec.outline2Width
        let shadowReach = spec.shadow ? spec.shadowDistance + spec.shadowBlur * 1.5 : 0
        pad = ceil(max(ink + spec.glowSize * 1.5, ink + shadowReach, spec.box ? spec.boxPadding : 0)) + 2
        relayout()
        view.needsDisplay = true
    }

    /// Width of the widest line, trailing spaces included, so typing never wraps or clips.
    private func naturalWidth() -> CGFloat {
        var w: CGFloat = 0
        let attrs = attributes
        for line in storage.string.components(separatedBy: "\n") where !line.isEmpty {
            let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs))
            w = max(w, CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil)))
        }
        return w
    }

    /// Size the box to its text and place it on the anchor.
    func relayout() {
        let font = spec.font
        let lineH = layout.defaultLineHeight(for: font)
        let italicSlop = spec.italic ? spec.fontSize * 0.2 : 0
        let w = ceil(naturalWidth() + italicSlop) + 2
        container.size = CGSize(width: w, height: 1e6)
        layout.ensureLayout(for: container)
        let h = max(ceil(layout.usedRect(for: container).height), ceil(lineH))
        let x: CGFloat
        switch spec.align {
        case .left: x = anchor.x
        case .center: x = anchor.x - w / 2
        case .right: x = anchor.x - w
        }
        view.textContainerInset = CGSize(width: pad, height: pad)
        layout.textRect = CGRect(x: 0, y: 0, width: w, height: h)
        boxFrame = CGRect(x: x - pad, y: anchor.y - pad, width: w + pad * 2, height: h + pad * 2)
        view.frameCenterRotation = 0
        view.frame = boxFrame
        view.frameCenterRotation = spec.rotation   // the canvas is flipped, so this turns the same way as the render
        let bp = spec.boxPadding
        view.box = spec.box ? (CGRect(x: pad - bp, y: pad - bp, width: w + bp * 2, height: h + bp * 2),
                               spec.boxRadius, spec.boxColor.cg) : nil
    }

    /// The text box before rotation, in image coordinates.
    private(set) var boxFrame = CGRect.zero

    /// Where the glyphs start (before rotation), in image coordinates.
    var textOrigin: CGPoint { CGPoint(x: boxFrame.minX + pad, y: boxFrame.minY + pad) }

    /// The box's rotation about its centre, image space (clockwise on screen).
    var rotationTransform: CGAffineTransform {
        let c = CGPoint(x: boxFrame.midX, y: boxFrame.midY)
        return CGAffineTransform(translationX: c.x, y: c.y).rotated(by: spec.rotation * .pi / 180).translatedBy(x: -c.x, y: -c.y)
    }

    /// The box outline as drawn on screen (rotated).
    var outline: CGPath { var t = rotationTransform; return CGPath(rect: boxFrame, transform: &t) }

    /// Image-space rectangle the rendered text can touch (effects and rotation included).
    var inkRect: CGRect { outline.boundingBoxOfPath.insetBy(dx: -2, dy: -2) }

    /// Render into a flipped (y-down) context in image coordinates.
    func draw(in c: CGContext) {
        c.saveGState()
        c.concatenate(rotationTransform)
        if let b = view.box {
            c.addPath(CGPath(roundedRect: b.rect.offsetBy(dx: boxFrame.minX, dy: boxFrame.minY),
                             cornerWidth: b.radius, cornerHeight: b.radius, transform: nil))
            c.setFillColor(b.color); c.fillPath()
        }
        let g = NSGraphicsContext(cgContext: c, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let range = layout.glyphRange(for: container)
        layout.drawBackground(forGlyphRange: range, at: textOrigin)
        layout.drawGlyphs(forGlyphRange: range, at: textOrigin)
        NSGraphicsContext.restoreGraphicsState()
        c.restoreGState()
    }

    /// Put the caret at an image-space point.
    func placeCaret(at p: CGPoint) {
        let q = p.applying(rotationTransform.inverted())
        let local = CGPoint(x: q.x - textOrigin.x, y: q.y - textOrigin.y)
        var frac: CGFloat = 0
        let i = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: &frac)
        view.setSelectedRange(NSRange(location: min(storage.length, i + (frac > 0.5 ? 1 : 0)), length: 0))
    }

    func textDidChange(_ notification: Notification) { relayout() }

    // MARK: Text layers

    /// Draw a spec into a layer that holds nothing else (a text layer), replacing its pixels.
    static func render(_ spec: TextSpec, into L: Layer, antialias: Bool = true, clearing area: CGRect? = nil) {
        let c = L.ctx
        if let r = area?.integral.intersection(L.rect), !r.isNull {
            c.clear(CGRect(x: r.minX, y: CGFloat(L.height) - r.maxY, width: r.width, height: r.height))
        } else {
            L.fill(.clear)
        }
        let ed = TextEditor(spec: spec)
        c.saveGState()
        c.translateBy(x: 0, y: CGFloat(L.height)); c.scaleBy(x: 1, y: -1)
        c.setShouldAntialias(antialias)
        ed.draw(in: c)
        c.restoreGState()
        L.touch()
    }

    private nonisolated(unsafe) static var frameCache: [TextSpec: CGRect] = [:]

    /// The box a spec occupies, in image coordinates.
    static func frame(of spec: TextSpec) -> CGRect {
        if let f = frameCache[spec] { return f }
        if frameCache.count > 64 { frameCache.removeAll() }
        let f = TextEditor(spec: spec).inkRect.insetBy(dx: 2, dy: 2)
        frameCache[spec] = f
        return f
    }
}

enum TextAlign: Int, CaseIterable {
    case left, center, right
    var ns: NSTextAlignment { [.left, .center, .right][rawValue] }
    var symbol: String { ["text.alignleft", "text.aligncenter", "text.alignright"][rawValue] }
}
