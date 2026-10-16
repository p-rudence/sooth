import AppKit

enum Dialogs {
    private static func alert(_ title: String, ok: String = "OK") -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        a.icon = NSApp.applicationIconImage
        return a
    }

    private static func field(_ v: String, width: CGFloat = 70) -> NSTextField {
        let f = NSTextField(string: v)
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        (f.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        return f
    }

    private static func fit(_ v: NSView) -> NSView {
        v.frame = NSRect(origin: .zero, size: v.fittingSize)
        return v
    }

    private static func fmt(_ v: Double, _ step: Double) -> String {
        step < 1 ? String(format: "%.2f", v) : String(Int(v.rounded()))
    }

    /// Slider dialog with live preview. Returns the chosen values, or nil on cancel.
    /// The self-test's stand-in for settings chosen in a dialog.
    nonisolated(unsafe) static var testValues: [Double]?

    static func params(title: String, params: [Param], preview: @escaping ([Double]) -> Void) -> [Double]? {
        if let v = testValues { preview(v); return v }
        let a = alert(title)
        var values = params.map(\.def)
        var timer: Timer?
        let schedule = {
            timer?.invalidate()
            let t = Timer(timeInterval: 0.06, repeats: false) { _ in preview(values) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 8; grid.columnSpacing = 10
        for (i, p) in params.enumerated() {
            let s = NSSlider(value: p.def, minValue: p.min, maxValue: p.max, target: nil, action: nil)
            s.isContinuous = true
            s.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let f = field(fmt(p.def, p.step), width: 60)
            s.onAction { c in
                let v = (c.doubleValue / p.step).rounded() * p.step
                values[i] = v; f.stringValue = fmt(v, p.step); schedule()
            }
            f.onAction { c in
                guard let v = Double(c.stringValue) else { return }
                let cl = min(p.max, max(p.min, v))
                values[i] = cl; s.doubleValue = cl; c.stringValue = fmt(cl, p.step); schedule()
            }
            grid.addRow(with: [label(p.name + ":"), s, f])
        }
        grid.column(at: 0).xPlacement = .trailing
        a.accessoryView = fit(grid)
        preview(values)
        let r = a.runModal()
        timer?.invalidate()
        return r == .alertFirstButtonReturn ? values : nil
    }

    static func newImage(defaultSize: CGSize) -> (Int, Int, Int)? {
        let a = alert("New Image")
        a.informativeText = "Size in pixels."
        let w = field("\(Int(defaultSize.width))"), h = field("\(Int(defaultSize.height))")
        let bg = NSPopUpButton(frame: .zero, pullsDown: false)
        bg.addItems(withTitles: ["White", "Secondary color", "Transparent"])
        let grid = NSGridView(views: [[label("Width:"), w], [label("Height:"), h], [label("Background:"), bg]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        a.accessoryView = fit(grid)
        a.window.initialFirstResponder = w
        guard a.runModal() == .alertFirstButtonReturn,
              let wi = Int(w.stringValue), let hi = Int(h.stringValue), wi > 0, hi > 0, wi <= 30000, hi <= 30000 else { return nil }
        return (wi, hi, bg.indexOfSelectedItem)
    }

    static func resize(width: Int, height: Int) -> (Int, Int, Bool)? {
        let a = alert("Resize Image")
        let pct = field("100", width: 60)
        let w = field("\(width)"), h = field("\(height)")
        let keep = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
        keep.state = .on
        let res = NSPopUpButton(frame: .zero, pullsDown: false)
        res.addItems(withTitles: ["Best quality", "Nearest neighbor (pixel art)"])
        let aspect = Double(width) / Double(height)
        pct.onAction { c in
            guard let p = Double(c.stringValue), p > 0 else { return }
            w.stringValue = "\(max(1, Int((Double(width) * p / 100).rounded())))"
            h.stringValue = "\(max(1, Int((Double(height) * p / 100).rounded())))"
        }
        w.onAction { c in
            guard keep.state == .on, let v = Double(c.stringValue) else { return }
            h.stringValue = "\(max(1, Int((v / aspect).rounded())))"
        }
        h.onAction { c in
            guard keep.state == .on, let v = Double(c.stringValue) else { return }
            w.stringValue = "\(max(1, Int((v * aspect).rounded())))"
        }
        let grid = NSGridView(views: [
            [label("By percentage:"), NSStackView(views: [pct, label("%")])],
            [label("Width:"), w], [label("Height:"), h],
            [NSGridCell.emptyContentView, keep], [label("Resampling:"), res],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        a.accessoryView = fit(grid)
        guard a.runModal() == .alertFirstButtonReturn,
              let wi = Int(w.stringValue), let hi = Int(h.stringValue), wi > 0, hi > 0, wi <= 30000, hi <= 30000 else { return nil }
        return (wi, hi, res.indexOfSelectedItem == 0)
    }

    static let anchors: [(String, Double, Double)] = [
        ("Top Left", 0, 0), ("Top", 0.5, 0), ("Top Right", 1, 0),
        ("Left", 0, 0.5), ("Middle", 0.5, 0.5), ("Right", 1, 0.5),
        ("Bottom Left", 0, 1), ("Bottom", 0.5, 1), ("Bottom Right", 1, 1),
    ]

    static func canvasSize(width: Int, height: Int) -> (Int, Int, Double, Double)? {
        let a = alert("Canvas Size")
        a.informativeText = "New area on the background layer is filled with the secondary color."
        let w = field("\(width)"), h = field("\(height)")
        let anchor = NSPopUpButton(frame: .zero, pullsDown: false)
        anchor.addItems(withTitles: anchors.map(\.0))
        anchor.selectItem(at: 4)
        let grid = NSGridView(views: [[label("Width:"), w], [label("Height:"), h], [label("Anchor:"), anchor]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        a.accessoryView = fit(grid)
        guard a.runModal() == .alertFirstButtonReturn,
              let wi = Int(w.stringValue), let hi = Int(h.stringValue), wi > 0, hi > 0, wi <= 30000, hi <= 30000 else { return nil }
        let an = anchors[anchor.indexOfSelectedItem]
        return (wi, hi, an.1, an.2)
    }

    /// Edits the layer in place with live preview; returns false (and restores) on cancel.
    static func layerProperties(_ l: Layer, preview: @escaping () -> Void) -> Bool {
        let a = alert("Layer Properties")
        let old = (l.name, l.visible, l.blend, l.opacity)
        let name = field(l.name, width: 200)
        let vis = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
        vis.state = l.visible ? .on : .off
        let blend = NSPopUpButton(frame: .zero, pullsDown: false)
        blend.addItems(withTitles: BlendMode.allCases.map(\.title))
        blend.selectItem(at: l.blend.rawValue)
        let op = NSSlider(value: Double(l.opacity) * 255, minValue: 0, maxValue: 255, target: nil, action: nil)
        op.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let opl = label("\(Int((l.opacity * 255).rounded()))")
        vis.onAction { c in l.visible = (c as! NSButton).state == .on; preview() }
        blend.onAction { c in l.blend = BlendMode(rawValue: (c as! NSPopUpButton).indexOfSelectedItem)!; preview() }
        op.onAction { c in l.opacity = CGFloat(c.doubleValue.rounded() / 255); opl.stringValue = "\(Int(c.doubleValue.rounded()))"; preview() }
        let grid = NSGridView(views: [
            [label("Name:"), name], [NSGridCell.emptyContentView, vis],
            [label("Blend mode:"), blend], [label("Opacity:"), NSStackView(views: [op, opl])],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        a.accessoryView = fit(grid)
        if a.runModal() == .alertFirstButtonReturn {
            l.name = name.stringValue.isEmpty ? old.0 : name.stringValue
            return true
        }
        (l.name, l.visible, l.blend, l.opacity) = old
        preview()
        return false
    }

    static func text(window: NSWindow?) -> String? {
        let a = alert("Add Text", ok: "Place")
        a.informativeText = "Uses the font and size in the toolbar and the primary color."
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        tv.font = .systemFont(ofSize: 14)
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.window.initialFirstResponder = tv
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return tv.string
    }

    /// The self-test's stand-in for a person clicking a button.
    nonisolated(unsafe) static var testAnswer: Int?

    static func ask(_ title: String, info: String, buttons: [String]) -> Int {
        if let r = testAnswer { return r }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
