import AppKit

/// Help ▸ Sooth Shortcuts: every tool key and the commands worth knowing, in one window.
enum HelpWindow {
    private nonisolated(unsafe) static var window: NSWindow?

    /// Close it so the next opening is in the current look.
    static func reset() { window?.orderOut(nil); window = nil }

    static func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); return }
        let text = NSMutableAttributedString()
        let h = pixelFont(), b = pixelFont(), k = pixelFont()
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 22 * 8)]
        para.headIndent = 22 * 8
        para.paragraphSpacing = 3
        func heading(_ s: String) {
            text.append(NSAttributedString(string: (text.length == 0 ? "" : "\n") + (Look.current == .tianmu ? s.lowercased() : s) + "\n",
                                           attributes: [.font: h, .foregroundColor: Ink.dim]))
        }
        func row(_ keys: String, _ what: String) {
            let r = NSMutableAttributedString(string: keys, attributes: [.font: k, .foregroundColor: Ink.text, .paragraphStyle: para])
            r.append(NSAttributedString(string: "\t" + what + "\n", attributes: [.font: b, .foregroundColor: Ink.name, .paragraphStyle: para]))
            text.append(r)
        }
        heading("Tools (press again to cycle)")
        var seen: Set<Character> = []
        for t in ToolKind.allCases where !seen.contains(t.key) {
            seen.insert(t.key)
            row(String(t.key).uppercased(), ToolKind.allCases.filter { $0.key == t.key }.map(\.title).joined(separator: ", "))
        }
        heading("While working")
        row("Space", "Hold to pan with any tool")
        row("X", "Swap primary and secondary colours")
        row("[  ]", "Smaller / larger brush")
        row("⌘-scroll", "Zoom at the pointer")
        row("Esc", "Cancel a drag, or finish typing text")
        row("⌫ / ⌥⌫", "Erase / fill the selection")
        heading("Moving things")
        row("Drag", "Move what's under the pointer (text, image, shape, or the selection's pixels)")
        row("Handles", "Corners resize (⇧ keeps shape), edges stretch")
        row("Right-drag", "Rotate (⇧ snaps to 15°); or drag just outside the box")
        row("Double-click", "Edit text, or lift the subject under the pointer onto its own layer (⌥ keeps the original)")
        row("Arrow keys", "Nudge 1 px (⇧ 10 px)")
        row("⌥-drag", "Leave a copy behind (selected pixels)")
        heading("Cut-outs")
        row("⌥⌘B", "Remove Background (run again to re-tune)")
        row("Eraser on a cut-out", "Erases its mask; right-drag paints it back")
        row("Magic Wand ▸ Subject", "Click a person, animal or thing to select it")
        heading("Edit")
        row("⌘Z / ⇧⌘Z", "Undo / redo (or click any step in History)")
        row("⇧⌘C", "Copy merged (all layers)")
        row("⇧⌘V / ⌥⌘V", "Paste into a new layer / a new image")
        row("⌘F", "Repeat the last effect")
        row("⇧⌘X", "Crop to selection")
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 680))
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 18, height: 16)
        tv.textStorage?.setAttributedString(text)
        let sv = NSScrollView(frame: tv.frame)
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = true
        let w = NSWindow(contentRect: tv.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sooth Shortcuts"
        w.contentView = sv
        w.titlebarAppearsTransparent = true
        w.backgroundColor = Ink.window
        w.appearance = Look.current.appearance
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
