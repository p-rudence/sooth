import AppKit

enum ToolKind: Int, CaseIterable {
    case moveSelected, moveSelection, rectSelect, ellipseSelect, lasso, magicWand,
         zoom, pan, bucket, gradient, brush, eraser, pencil, picker, clone, recolor, text, line, shapes

    var title: String {
        switch self {
        case .moveSelected: "Move Selected Pixels"
        case .moveSelection: "Move Selection (outline only)"
        case .rectSelect: "Rectangle Select"
        case .ellipseSelect: "Ellipse Select"
        case .lasso: "Lasso Select"
        case .magicWand: "Magic Wand"
        case .zoom: "Zoom"
        case .pan: "Pan"
        case .bucket: "Paint Bucket"
        case .gradient: "Gradient"
        case .brush: "Paintbrush"
        case .eraser: "Eraser"
        case .pencil: "Pencil"
        case .picker: "Color Picker"
        case .clone: "Clone Stamp"
        case .recolor: "Recolor"
        case .text: "Text"
        case .line: "Line"
        case .shapes: "Shapes"
        }
    }

    /// Paint.NET's single-key shortcuts; pressing a key again cycles tools sharing it.
    var key: Character {
        switch self {
        case .moveSelected, .moveSelection: "m"
        case .rectSelect, .ellipseSelect, .lasso, .magicWand: "s"
        case .zoom: "z"
        case .pan: "h"
        case .bucket: "f"
        case .gradient: "g"
        case .brush: "b"
        case .eraser: "e"
        case .pencil: "p"
        case .picker: "k"
        case .clone: "l"
        case .recolor: "r"
        case .text: "t"
        case .line, .shapes: "o"
        }
    }

    var symbol: String {
        switch self {
        case .moveSelected: "arrow.up.and.down.and.arrow.left.and.right"
        case .moveSelection: "cursorarrow.motionlines"
        case .rectSelect: "rectangle.dashed"
        case .ellipseSelect: "circle.dashed"
        case .lasso: "lasso"
        case .magicWand: "wand.and.stars"
        case .zoom: "magnifyingglass"
        case .pan: "hand.raised"
        case .bucket: "drop.fill"
        case .gradient: "circle.lefthalf.filled"
        case .brush: "paintbrush"
        case .eraser: "eraser"
        case .pencil: "pencil"
        case .picker: "eyedropper"
        case .clone: "square.on.square"
        case .recolor: "paintpalette"
        case .text: "textformat"
        case .line: "line.diagonal"
        case .shapes: "square.on.circle"
        }
    }

    var cursor: NSCursor {
        switch self {
        case .pan: .openHand
        case .moveSelected: Cursors.movePixels
        case .moveSelection: Cursors.moveSelection
        case .text: .iBeam
        default: .crosshair
        }
    }

    var usesBrushWidth: Bool { [.brush, .eraser, .clone, .recolor, .line, .shapes].contains(self) }
    var showsBrushCursor: Bool { [.brush, .eraser, .clone, .recolor].contains(self) }
}

enum ShapeKind: Int, CaseIterable {
    case rectangle, roundedRectangle, ellipse, triangle, diamond, star, heart, arrow, bubble
    var title: String {
        ["Rectangle", "Rounded Rectangle", "Ellipse", "Triangle", "Diamond", "Star", "Heart", "Arrow", "Speech Bubble"][rawValue]
    }
}

enum FillStyle: Int, CaseIterable {
    case outline, fill, both
    var title: String { ["Draw Shape Outline", "Draw Filled Shape", "Filled With Outline"][rawValue] }
}

enum GradientKind: Int, CaseIterable {
    case linear, reflected, radial, diamond, conical
    var title: String { ["Linear", "Linear Reflected", "Radial", "Diamond", "Conical"][rawValue] }
}

extension Notification.Name {
    static let appStateChanged = Notification.Name("SoothAppStateChanged")
}

/// Tool and color state shared by every open image, like Paint.NET's floating palettes.
final class AppState {
    static let shared = AppState()

    var tool: ToolKind = .brush { didSet { post() } }
    var primary = RGBA.black { didSet { post() } }
    var secondary = RGBA.white { didSet { post() } }
    var brushWidth: CGFloat = 4 { didSet { post() } }
    var antialias = true { didSet { post() } }
    /// Paintbrush / eraser edge: 1 = crisp, 0 = airbrush-soft.
    var brushHardness: CGFloat = 0.75 { didSet { post() } }
    var brushOpacity: CGFloat = 1 { didSet { post() } }
    /// A tablet pen's pressure scales the brush size.
    var pressureSize = true { didSet { post() } }
    var tolerance: Double = 0.3 { didSet { post() } }
    var floodGlobal = false { didSet { post() } }
    /// Magic Wand selects the subject (person, animal, object) under the click.
    var wandSubject = false { didSet { post() } }
    var sampleImage = false { didSet { post() } }
    var shape: ShapeKind = .rectangle { didSet { post() } }
    var fillStyle: FillStyle = .outline { didSet { post() } }
    var gradient: GradientKind = .linear { didSet { post() } }
    /// Gradient fades the layer's own pixels out instead of painting colours.
    var gradientTransparency = false { didSet { post() } }
    /// Line tool: arrowheads at the start / end.
    var arrowStart = false { didSet { post() } }
    var arrowEnd = false { didSet { post() } }
    var selectMode: SelectMode = .replace { didSet { post() } }
    /// Rectangle / Ellipse Select: 0 normal, 1 fixed ratio, 2 fixed size (w × h below).
    var selectShape = 0 { didSet { post() } }
    var selectW: CGFloat = 16 { didSet { post() } }
    var selectH: CGFloat = 9 { didSet { post() } }
    var fontName = "Helvetica Neue" { didSet { post() } }
    var fontSize: CGFloat = 36 { didSet { post() } }
    var bold = false { didSet { post() } }
    var italic = false { didSet { post() } }
    /// JPEG / HEIC quality, 0...1.
    var exportQuality: CGFloat = 0.92
    var underline = false { didSet { post() } }
    var textAlign: TextAlign = .left { didSet { post() } }
    /// Text outline thickness in pixels (0 = none), drawn in the secondary color under the fill.
    var outlineWidth: CGFloat = 0 { didSet { post() } }
    var textShadow = false { didSet { post() } }
    /// Text effects beyond the toolbar (gradient, second outline, shadow details, glow, spacing,
    /// rotation, caption box). Only its effect fields are used; the toolbar owns the rest.
    var textEffects = TextSpec() { didSet { post() } }
    let palette: [RGBA] = AppState.defaultPalette()
    /// Colours recently painted with or picked, newest first.
    private(set) var recent: [RGBA] = [] { didSet { post() } }

    func noteRecent(_ c: RGBA) {
        guard recent.first != c else { return }
        recent = Array(([c] + recent.filter { $0 != c }).prefix(12))
    }

    private func post() { NotificationCenter.default.post(name: .appStateChanged, object: nil) }

    func swapColors() { (primary, secondary) = (secondary, primary) }

    var font: NSFont {
        var f = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize)
        let fm = NSFontManager.shared
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }

    static func defaultPalette() -> [RGBA] {
        var p: [RGBA] = []
        for i in 0..<12 { let v = UInt8((Double(i) / 11 * 255).rounded()); p.append(RGBA(r: v, g: v, b: v)) }
        for (s, b) in [(0.3, 1.0), (0.6, 1.0), (1.0, 1.0), (1.0, 0.72), (1.0, 0.45)] {
            for h in 0..<12 {
                p.append(RGBA(NSColor(colorSpace: .sRGB, hue: CGFloat(h) / 12, saturation: s, brightness: b, alpha: 1)))
            }
        }
        return p
    }
}

// MARK: - Control helpers

final class ClosureTarget: NSObject {
    let f: (Any?) -> Void
    init(_ f: @escaping (Any?) -> Void) { self.f = f }
    @objc func fire(_ sender: Any?) { f(sender) }
}

nonisolated(unsafe) private var closureKey: UInt8 = 0

extension NSControl {
    func onAction(_ f: @escaping (NSControl) -> Void) {
        let t = ClosureTarget { [unowned self] _ in f(self) }
        objc_setAssociatedObject(self, &closureKey, t, .OBJC_ASSOCIATION_RETAIN)
        target = t
        action = #selector(ClosureTarget.fire(_:))
    }
}

/// Dialog and panel labels, in the suite's pixel font.
func label(_ s: String, bold: Bool = false, small: Bool = false) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = pixelFont()
    l.textColor = bold ? Ink.text : Ink.soft
    return l
}

func symbolImage(_ name: String, size: CGFloat = 15) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
}

func iconButton(_ symbol: String, tip: String, _ f: @escaping () -> Void) -> NSButton {
    let b = NSButton(image: symbolImage(symbol, size: 13) ?? NSImage(), target: nil, action: nil)
    b.bezelStyle = .accessoryBarAction
    b.isBordered = false
    b.toolTip = tip
    b.onAction { _ in f() }
    return b
}

func popup(_ items: [String], selected: Int, _ f: @escaping (Int) -> Void) -> NSPopUpButton {
    let p = NSPopUpButton(frame: .zero, pullsDown: false)
    p.addItems(withTitles: items)
    p.selectItem(at: selected)
    p.controlSize = .small
    p.font = .systemFont(ofSize: 11)
    p.onAction { c in f((c as! NSPopUpButton).indexOfSelectedItem) }
    return p
}

/// One 16×16 checker tile for fast tiled drawing.
let checkerTile: CGImage = {
    let l = Layer(width: 16, height: 16, name: "")
    l.fill(RGBA.white)
    l.ctx.setFillColor(CGColor(gray: 0.8, alpha: 1))
    l.ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8)); l.ctx.fill(CGRect(x: 8, y: 8, width: 8, height: 8))
    return l.image()
}()

let checkerColor: NSColor = {
    let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
        NSColor(white: 1, alpha: 1).setFill(); r.fill()
        NSColor(white: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }
    return NSColor(patternImage: img)
}()
