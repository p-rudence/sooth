// The shared parts every panel is built from. In the house look (Tianmu) they are the suite's plain text:
// OLED black, the IBM VGA 8x16 pixel font, grey inks, hairlines, and words that double as buttons
// (`[dup] [del]`). In the other looks (Look.swift) the same parts draw as that era's buttons, boxes and wells.

import AppKit

let pixelFontName = "PxPlus_IBM_VGA_8x16"
/// The layout unit: row heights are built on it. Whole multiples of 16 keep the pixel font crisp.
let uiSize: CGFloat = 16

/// The current look's interface font (the pixel font in the house look).
func pixelFont(_ size: CGFloat = uiSize) -> NSFont { uiFont(size) }

/// The house roles of colour, resolved in the current look.
enum Ink {
    static var text: NSColor { Palette.current.text }
    static var soft: NSColor { Palette.current.soft }
    static var name: NSColor { Palette.current.name }
    static var dim: NSColor { Palette.current.dim }
    static var faint: NSColor { Palette.current.faint }
    static var line: NSColor { Palette.current.line }
    /// Behind a selected row.
    static var pick: NSColor { Palette.current.pick }
    /// Text on a selected row.
    static var pickText: NSColor { Palette.current.pickText }
    /// Behind a field being typed in.
    static var well: NSColor { Palette.current.well }
    /// The window behind the panels.
    static var window: NSColor { Palette.current.window }
    /// Round the image.
    static var canvas: NSColor { Palette.current.canvas }
}

/// A rule between regions: a hairline, or an etched pair in the 90s looks.
final class Hairline: NSView {
    let vertical: Bool
    init(vertical: Bool) {
        self.vertical = vertical
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: vertical ? .horizontal : .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let t = Chrome.ruleWidth
        return vertical ? NSSize(width: t, height: NSView.noIntrinsicMetric) : NSSize(width: NSView.noIntrinsicMetric, height: t)
    }
    override func draw(_ dirtyRect: NSRect) { Chrome.rule(bounds, vertical: vertical) }
}

/// A text field in the look's font: a near-black well in the house look, that era's sunken field elsewhere.
func styleField(_ f: NSTextField) {
    f.font = pixelFont()
    f.textColor = Ink.text
    f.focusRingType = .none
    switch Look.current {
    case .tianmu:
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = true
        f.backgroundColor = Ink.well
    case .bevel, .platinum:
        f.isBezeled = true
        f.bezelStyle = .squareBezel
        f.drawsBackground = true
        f.backgroundColor = .white
        f.textColor = .black
    case .glass, .native:
        f.isBezeled = true
        f.bezelStyle = .roundedBezel
        f.drawsBackground = true
        f.backgroundColor = Look.current == .glass ? .white : .textBackgroundColor
        f.focusRingType = Look.current == .native ? .default : .none
    }
}

/// A menu in the look's font (for `[choice]` parts and right-click menus).
func pixelMenu(_ items: [String], selected: Int?, _ f: @escaping (Int) -> Void) -> NSMenu {
    let m = NSMenu()
    m.font = pixelFont()
    m.autoenablesItems = false
    for (i, s) in items.enumerated() {
        let it = NSMenuItem(title: s, action: #selector(ClosureTarget.fire(_:)), keyEquivalent: "")
        let t = ClosureTarget { _ in f(i) }
        it.target = t
        it.representedObject = t   // keeps the target alive with the item
        it.state = i == selected ? .on : .off
        m.addItem(it)
    }
    return m
}

/// One line of text made of parts: plain words, `[buttons]`, `[x] toggles`, `[choice]` menus,
/// `best◄ other` radio rows and `[-]12[+]` numbers (drag the number to scrub, click it to type).
final class Strip: NSView, NSTextFieldDelegate {
    struct Number {
        var value: Double, min: Double, max: Double, step: Double
        var decimals = 0
        var set: (Double) -> Void
        func text(_ v: Double) -> String { decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v) }
        func clamp(_ v: Double) -> Double { Swift.min(max, Swift.max(min, (v / step).rounded() * step)) }
    }

    enum Kind {
        case plain
        case tap(() -> Void)
        case menu([String], Int?, (Int) -> Void)
        case number(Number)
        case spring
    }

    /// What a part *is*, so the boxed looks can draw it as a control. The house look draws `runs` as they are.
    enum Face {
        case runs
        case button(String)
        /// A button that stays in while on (bold, italic…).
        case press(String, Bool)
        case toggle(String, Bool)
        case choice(String)
        case radio(String, Bool)
        /// The `-` and `+` of a number.
        case step(String)
        /// The number itself.
        case value(String)
        /// A panel's name.
        case heading(String)
    }

    struct Part {
        var runs: [(String, NSColor)]
        var tip: String?
        var kind: Kind = .plain
        var face: Face = .runs
        var interactive: Bool { if case .plain = kind { return false }; if case .spring = kind { return false }; return true }
    }

    var parts: [Part] = [] {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true; refreshTips() }
    }
    var inset: CGFloat = 10
    private var editing: (field: NSTextField, number: Number, back: NSResponder?)?
    /// AppKit doesn't keep tooltip owners alive, so the strings live here.
    private var tipStrings: [NSString] = []
    /// Trackpad scrolling over a number, gathered until it adds up to a step.
    private var scrollSum: CGFloat = 0
    /// The part being clicked, drawn pushed in.
    private var pressed: Int?

    init(_ parts: [Part] = []) {
        super.init(frame: .zero)
        self.parts = parts
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: parts.reduce(inset * 2) { $0 + width(of: $1) }, height: uiSize + 8)
    }

    private var boxed: Bool { Look.current != .tianmu }

    private func attributed(_ p: Part) -> NSAttributedString {
        let s = NSMutableAttributedString()
        for (t, c) in p.runs { s.append(NSAttributedString(string: t, attributes: [.font: pixelFont(), .foregroundColor: c])) }
        return s
    }

    private func label(_ s: String, _ c: NSColor = Ink.text) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: pixelFont(), .foregroundColor: c])
    }

    /// Room round a boxed control, so neighbours never touch.
    private let margin: CGFloat = 2

    private func width(of p: Part) -> CGFloat {
        if case .spring = p.kind { return 0 }
        guard boxed else { return ceil(attributed(p).size().width) }
        func w(_ s: String) -> CGFloat { ceil(label(s).size().width) }
        switch p.face {
        case .runs:
            // Boxed controls carry their own margins, so the spaces between them shrink.
            if p.runs.allSatisfy({ $0.0.allSatisfy { $0 == " " } }) { return p.runs.reduce(0) { $0 + CGFloat($1.0.count) } * 3 }
            return ceil(attributed(p).size().width)
        case .button(let s), .press(let s, _): return w(s) + 14 + margin * 2
        case .toggle(let s, _): return 14 + 5 + w(s) + margin * 2
        case .choice(let s): return w(s) + 12 + 18 + margin * 2
        case .radio(let s, _): return 13 + 4 + w(s) + 8
        case .step: return 18 + margin
        case .value(let s): return max(w(s) + 12, 36) + margin
        case .heading(let s): return ceil(NSAttributedString(string: s, attributes: titleAttributes(Ink.text)).size().width) + 12
        }
    }

    /// Where each part sits; the first spring takes the slack.
    private func frames() -> [CGRect] {
        let widths = parts.map(width(of:))
        let slack = max(0, bounds.width - inset * 2 - widths.reduce(0, +))
        var x = inset, out: [CGRect] = [], sprung = false
        for (p, w) in zip(parts, widths) {
            var w = w
            if case .spring = p.kind, !sprung { w = slack; sprung = true }
            out.append(CGRect(x: x, y: 0, width: w, height: bounds.height))
            x += w
        }
        return out
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTips()
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, (p, r)) in zip(parts, frames()).enumerated() where r.minX < bounds.maxX {
            if boxed { drawBoxed(p, in: r, down: pressed == i) } else { drawText(attributed(p), in: r) }
        }
    }

    /// Text at the left of `r`, centred on the line.
    private func drawText(_ s: NSAttributedString, in r: CGRect, x: CGFloat? = nil) {
        let h = s.size().height
        s.draw(at: CGPoint(x: x ?? r.minX, y: (r.midY - h / 2).rounded()))
    }

    /// The height a boxed control gets on this line.
    private func box(_ r: CGRect, _ x: CGFloat, _ w: CGFloat) -> CGRect {
        let h = min(r.height - 4, 21)
        return CGRect(x: x, y: (r.midY - h / 2).rounded(), width: w, height: h)
    }

    private func drawBoxed(_ p: Part, in r: CGRect, down: Bool) {
        let look = Look.current
        // Text on a lit control: white on Native's accent, the look's ink elsewhere.
        func ink(on: Bool) -> NSColor { look == .native && on ? .white : Ink.text }
        switch p.face {
        case .runs:
            drawText(attributed(p), in: r)
        case .button(let s), .press(let s, _):
            var on = false
            if case .press(_, let o) = p.face { on = o }
            let b = box(r, r.minX + margin, r.width - margin * 2)
            Chrome.button(b, down: down, on: on)
            let t = label(s, ink(on: on))
            let off: CGFloat = (down || on) && look == .bevel ? 1 : 0
            drawText(t, in: b.offsetBy(dx: off, dy: off), x: (b.midX - t.size().width / 2).rounded() + off)
        case .toggle(let s, let on):
            let c = CGRect(x: r.minX + margin, y: (r.midY - 7).rounded(), width: 14, height: 14)
            Chrome.checkbox(c, on: on)
            drawText(label(s, on ? Ink.text : Ink.name), in: r, x: c.maxX + 5)
        case .choice(let s):
            let b = box(r, r.minX + margin, r.width - margin * 2)
            switch look {
            case .bevel:
                Chrome.well95(b)
                let arrow = CGRect(x: b.maxX - 18, y: b.minY + 2, width: 16, height: b.height - 4)
                Chrome.bevel(arrow, down: down)
                Chrome.popupArrow(arrow.offsetBy(dx: down ? 1 : 0, dy: down ? 1 : 0), .black)
            default:
                Chrome.button(b, down: down)
                Chrome.popupArrow(CGRect(x: b.maxX - 18, y: b.minY, width: 14, height: b.height), Ink.text)
            }
            drawText(label(s, Ink.text), in: b, x: b.minX + 7)
        case .radio(let s, let on):
            let c = CGRect(x: r.minX, y: (r.midY - 6.5).rounded(), width: 13, height: 13)
            Chrome.radio(c, on: on)
            drawText(label(s, on ? Ink.text : Ink.name), in: r, x: c.maxX + 4)
        case .step(let s):
            let b = box(r, r.minX + margin / 2, 18)
            Chrome.button(b, down: down)
            let t = label(s, Ink.text)
            drawText(t, in: b, x: (b.midX - t.size().width / 2).rounded())
        case .value(let s):
            let b = box(r, r.minX + margin / 2, r.width - margin)
            Chrome.well(b)
            let t = label(s, look == .bevel || look == .platinum ? .black : Ink.text)
            drawText(t, in: b, x: (b.midX - t.size().width / 2).rounded())
        case .heading(let s):
            let t = NSAttributedString(string: s, attributes: titleAttributes(look == .native ? Ink.name : Ink.text))
            if look == .platinum {
                // Mac OS 8 clears the stripes behind a title.
                Ink.window.setFill()
                CGRect(x: r.minX - 4, y: r.minY + 2, width: t.size().width + 12, height: r.height - 4).fill()
            }
            drawText(t, in: r)
        }
    }

    private func refreshTips() {
        removeAllToolTips()
        tipStrings = []
        for (p, r) in zip(parts, frames()) {
            guard let t = p.tip else { continue }
            let s = t as NSString
            tipStrings.append(s)
            addToolTip(r, owner: s, userData: nil)
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        // The boxed looks are ordinary controls: the arrow stays an arrow, as it did on those machines.
        for (p, r) in zip(parts, frames()) {
            switch p.kind {
            case .tap, .menu: if !boxed { addCursorRect(r, cursor: .pointingHand) }
            case .number: addCursorRect(r, cursor: .resizeLeftRight)
            default: break
            }
        }
    }

    private func part(at e: NSEvent) -> (Int, Part, CGRect)? {
        let pt = convert(e.locationInWindow, from: nil)
        for (i, (p, r)) in zip(parts, frames()).enumerated() where p.interactive && r.insetBy(dx: -2, dy: 0).contains(pt) { return (i, p, r) }
        return nil
    }

    /// Show the part pushed in for a moment (the boxed looks only).
    private func press(_ i: Int, while f: () -> Void) {
        guard boxed else { f(); return }
        pressed = i
        display()
        f()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard self?.pressed == i else { return }
            self?.pressed = nil
            self?.needsDisplay = true
        }
    }

    override func mouseDown(with e: NSEvent) {
        guard let (i, p, r) = part(at: e) else { super.mouseDown(with: e); return }
        switch p.kind {
        case .tap(let f): press(i) { f() }
        case .menu(let items, let sel, let f):
            let m = pixelMenu(items, selected: sel, f)
            press(i) { m.popUp(positioning: sel.flatMap { m.item(at: $0) }, at: CGPoint(x: r.minX + (boxed ? margin : 0), y: r.maxY - 4), in: self) }
        case .number(let n): track(n, rect: r, from: e)
        default: break
        }
    }

    /// Drag sideways to scrub (⇧ for big steps); a click without a drag types a value instead.
    private func track(_ n: Number, rect: CGRect, from e: NSEvent) {
        let x0 = e.locationInWindow.x
        var moved = false
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let dx = ev.locationInWindow.x - x0
            if abs(dx) > 2 { moved = true }
            guard moved else { continue }
            let per: Double = ev.modifierFlags.contains(.shift) ? 10 : 1
            n.set(n.clamp(n.value + (dx / 4).rounded(.towardZero) * n.step * per))
        }
        if !moved { beginTyping(n, rect: rect) }
    }

    private func beginTyping(_ n: Number, rect: CGRect) {
        editing?.field.removeFromSuperview()
        let f = NSTextField(string: n.text(n.value))
        styleField(f)
        f.isBezeled = false
        f.drawsBackground = true
        f.backgroundColor = boxed ? .white : Ink.well
        if boxed { f.textColor = .black }
        f.delegate = self
        f.frame = boxed ? box(rect, rect.minX + margin / 2 + 2, max(rect.width - margin - 4, 6 * 8)).insetBy(dx: 0, dy: 2)
                        : CGRect(x: rect.minX - 2, y: ((bounds.height - uiSize) / 2).rounded() - 1,
                                 width: max(rect.width, 6 * 8) + 4, height: uiSize + 2)
        addSubview(f)
        // Typing finishes back where the keyboard was (live text being edited, say), not on the canvas.
        let back = window?.firstResponder
        editing = (f, n, (back as? NSView)?.window === window ? back : nil)
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let (f, n, back) = editing else { return }
        editing = nil
        if let v = Double(f.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) {
            n.set(Swift.min(n.max, Swift.max(n.min, v)))   // typed values aren't rounded to the step
        }
        f.removeFromSuperview()
        giveBackKeyboard(back)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelTyping(); return true }
        return false
    }

    /// Drop a number being typed without applying it (Escape, or the line now shows another tool).
    func cancelTyping() {
        guard let (f, _, back) = editing else { return }
        editing = nil
        f.removeFromSuperview()
        giveBackKeyboard(back)
    }

    private func giveBackKeyboard(_ back: NSResponder?) {
        guard let w = window else { return }
        if let back, (back as? NSView)?.window === w, w.makeFirstResponder(back) { return }
        w.makeFirstResponder(w.initialFirstResponder)
    }

    override func scrollWheel(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        for (p, r) in zip(parts, frames()) where r.contains(pt) {
            if case .number(let n) = p.kind {
                guard e.momentumPhase.isEmpty else { return }   // no coasting after the fingers lift
                // A wheel click is one step; a trackpad steps once per ~12 points of travel.
                scrollSum += e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 12 : (e.scrollingDeltaY > 0 ? 1 : e.scrollingDeltaY < 0 ? -1 : 0)
                let steps = scrollSum.rounded(.towardZero)
                guard steps != 0 else { return }
                scrollSum -= steps
                n.set(n.clamp(n.value + Double(steps) * n.step))
                return
            }
        }
        super.scrollWheel(with: e)
    }
}

// MARK: - Part builders

extension Strip.Part {
    /// Plain words. Labels and hints are recased for the look (`width` → `Width`); pass `cased: false` for values.
    static func text(_ s: String, _ c: NSColor = Ink.name, tip: String? = nil, cased: Bool = true) -> Self {
        .init(runs: [(cased ? Look.current.word(s) : s, c)], tip: tip)
    }
    static var spring: Self { .init(runs: [], kind: .spring) }
    static var gap: Self { .init(runs: [("  ", Ink.name)]) }

    /// `[word]`: brackets dim, word soft.
    static func button(_ word: String, tip: String? = nil, _ f: @escaping () -> Void) -> Self {
        .init(runs: [("[", Ink.dim), (word, Ink.soft), ("]", Ink.dim)], tip: tip, kind: .tap(f), face: .button(Look.current.word(word)))
    }

    /// `[word]` that opens a menu (no current choice shown).
    static func menuButton(_ word: String, _ items: [String], tip: String? = nil, _ f: @escaping (Int) -> Void) -> Self {
        .init(runs: [("[", Ink.dim), (word, Ink.soft), ("]", Ink.dim)], tip: tip, kind: .menu(items, nil, f), face: .choice(Look.current.word(word)))
    }

    /// A word that lights up while on (`bold`, `italic`…).
    static func press(_ word: String, _ on: Bool, tip: String? = nil, _ f: @escaping (Bool) -> Void) -> Self {
        .init(runs: [(word, on ? Ink.text : Ink.dim), (" ", Ink.dim)], tip: tip, kind: .tap { f(!on) }, face: .press(Look.current.word(word), on))
    }

    /// `[x] title`, or `[ ] title` when off.
    static func toggle(_ title: String, _ on: Bool, tip: String? = nil, _ f: @escaping (Bool) -> Void) -> Self {
        .init(runs: [("[", Ink.dim), (on ? "x" : " ", Ink.text), ("] ", Ink.dim), (title, on ? Ink.soft : Ink.name)],
              tip: tip, kind: .tap { f(!on) }, face: .toggle(Look.current.word(title), on))
    }

    /// `[current]`, which opens a menu of the rest.
    static func choice(_ items: [String], _ selected: Int, tip: String? = nil, _ f: @escaping (Int) -> Void) -> Self {
        let cur = items.indices.contains(selected) ? items[selected] : "—"
        return .init(runs: [("[", Ink.dim), (cur.lowercased(), Ink.soft), ("]", Ink.dim)], tip: tip,
                     kind: .menu(items, selected, f), face: .choice(cur))
    }
}

/// `best◄ 1080p 720p`: every option shows; the chosen one is bright with a mark.
func radio(_ items: [String], _ selected: Int, tips: [String]? = nil, _ f: @escaping (Int) -> Void) -> [Strip.Part] {
    items.enumerated().map { i, s in
        let on = i == selected
        return Strip.Part(runs: [(s, on ? Ink.text : Ink.name), (on ? "◄ " : "  ", Ink.soft)],
                          tip: tips?[i], kind: .tap { f(i) }, face: .radio(Look.current.word(s), on))
    }
}

/// `[-]12[+]`, with the number scrubbable and typeable.
func number(_ v: Double, _ lo: Double, _ hi: Double, step: Double = 1, decimals: Int = 0, unit: String = "",
            tip: String? = nil, _ set: @escaping (Double) -> Void) -> [Strip.Part] {
    let n = Strip.Number(value: v, min: lo, max: hi, step: step, decimals: decimals, set: set)
    return [Strip.Part(runs: [("[", Ink.dim), ("-", Ink.soft), ("]", Ink.dim)], tip: tip, kind: .tap { set(n.clamp(v - step)) }, face: .step("−")),
            Strip.Part(runs: [(n.text(v) + unit, Ink.text)], tip: tip.map { $0 + " · drag or scroll to change, click to type" },
                       kind: .number(n), face: .value(n.text(v) + unit)),
            Strip.Part(runs: [("[", Ink.dim), ("+", Ink.soft), ("]", Ink.dim)], tip: tip, kind: .tap { set(n.clamp(v + step)) }, face: .step("+"))]
}
