import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private var controllers: [EditorWindowController] = []
    private var lookObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()
        NSApp.appearance = Look.current.appearance
        NSApp.mainMenu = buildMenu()
        lookObserver = NotificationCenter.default.addObserver(forName: .lookChanged, object: nil, queue: .main) { _ in
            NSApp.appearance = Look.current.appearance
            // The floating panels are rebuilt in the new look the next time they open.
            LibraryPanel.reset()
            TextEffectsPanel.reset()
            HelpWindow.reset()
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export"), i + 2 < args.count {
            // Sooth --export <any supported image> <out.png|jpg|...>: flatten and convert, then quit.
            do {
                let d = try Document.load(url: URL(fileURLWithPath: args[i + 1]))
                let out = URL(fileURLWithPath: args[i + 2])
                try d.save(to: out, format: SaveFormat.from(url: out) ?? .png)
                print("\(d.width)x\(d.height), \(d.layers.count) layer(s): " + d.layers.map { "\($0.name) [\($0.blend.title), \(Int($0.opacity * 100))%\($0.visible ? "" : ", hidden")]" }.joined(separator: "; "))
                exit(0)
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        if args.contains("--bench") { Bench.run() }
        if let i = args.firstIndex(of: "--demo"), i + 2 < args.count { Demo.run(image: args[i + 1], out: args[i + 2]) }
        if let i = args.firstIndex(of: "--tour"), i + 1 < args.count { Tour.run(out: args[i + 1]) }
        if let i = args.firstIndex(of: "--selftest") {
            SelfTest.run(out: i + 1 < args.count ? args[i + 1] : NSTemporaryDirectory() + "sooth-selftest")
        }
        offerRecovery()
        // The very first launch asks for a look before the first image opens.
        if !Look.chosen {
            LookPicker.show { [weak self] in
                guard let self, self.controllers.isEmpty else { return }
                self.show(Document(width: 800, height: 600, background: .white))
            }
            return
        }
        if controllers.isEmpty {
            show(Document(width: 800, height: 600, background: .white))
        }
        NSApp.activate()
    }

    // MARK: Looks

    @objc func chooseLook(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let l = Look(rawValue: raw) { Look.choose(l) }
    }
    @objc func showLookPicker(_ sender: Any?) { LookPicker.show() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseLook(_:)) { item.state = (item.representedObject as? String) == Look.current.rawValue ? .on : .off }
        return true
    }

    /// After a crash, offer back the images that had unsaved changes.
    private func offerRecovery() {
        let left = Recovery.leftovers()
        guard !left.isEmpty, !CommandLine.arguments.contains("--selftest") else { return }
        let names = left.map(Recovery.recoveredName)
        let a = NSAlert()
        a.messageText = left.count == 1 ? "Sooth didn't quit normally. Restore your unsaved image?"
                                        : "Sooth didn't quit normally. Restore your \(left.count) unsaved images?"
        a.informativeText = names.joined(separator: ", ")
        a.addButton(withTitle: "Restore")
        a.addButton(withTitle: "Discard")
        let restore = a.runModal() == .alertFirstButtonReturn
        for (u, name) in zip(left, names) {
            if restore, let d = try? Document.load(url: u) {
                d.fileURL = nil; d.fileFormat = nil; d.dirty = true
                d.recoveredName = "\(name) (Recovered)"
                show(d)
                // Write its new recovery copy before letting go of the old one, so a second crash loses nothing.
                controllers.last?.recovery.tick()
                Recovery.drain()
            }
            try? FileManager.default.removeItem(at: u)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Replace the untouched launch canvas when files are opened from Finder.
        controllers.forEach { $0.canvas.engine.finishText() }   // text being typed counts as a change
        if controllers.count == 1, let c = controllers.first, c.doc.fileURL == nil, !c.doc.dirty, c.doc.history.count == 1 {
            c.window?.close()
        }
        for u in urls { open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { Look.chosen }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controllers.forEach { $0.canvas.engine.finishText() }   // text being typed counts as a change
        // Ask about every unsaved image first; only once nobody cancels is anything let go.
        for c in controllers where c.doc.dirty {
            if !c.confirmClose() { return .terminateCancel }
        }
        controllers.forEach { $0.recovery.stop() }
        Recovery.drain()   // the deletes must land before the process ends
        return .terminateNow
    }

    func open(_ url: URL) {
        if let c = controllers.first(where: { $0.doc.fileURL == url }) {
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let d = try Document.load(url: url)
            show(d)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func show(_ d: Document) {
        let c = EditorWindowController(doc: d)
        controllers.append(c)
        if let key = NSApp.keyWindow, key.windowController is EditorWindowController, let w = c.window {
            key.addTabbedWindow(w, ordered: .above)
        }
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    func closed(_ c: EditorWindowController) {
        controllers.removeAll { $0 === c }
    }

    @objc func showHelp(_ s: Any?) { HelpWindow.show() }

    @objc func showAbout(_ s: Any?) {
        let credits = NSAttributedString(string: "A free, native image editor for the Mac, in the spirit of Paint.NET.\nLayers, live text and shapes, cut-outs, and 60+ effects.\n\nSooth is Tianmu's word for making something real through intention.\nMade by Tianmu Labs.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        for u in urls {
            let i = NSMenuItem(title: u.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = u
            i.image = NSWorkspace.shared.icon(forFile: u.path)
            i.image?.size = NSSize(width: 16, height: 16)
            i.toolTip = u.path
            menu.addItem(i)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { open(u) } }
    @objc func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(sender) }

    // MARK: File actions

    @objc func newDocument(_ sender: Any?) {
        var size = CGSize(width: 800, height: 600)
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: d) {
            size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        guard let (w, h, bg) = Dialogs.newImage(defaultSize: size) else { return }
        guard Limits.ok(w, h) else { Limits.tooBig(); return }
        let fill: RGBA? = bg == 0 ? .white : (bg == 1 ? AppState.shared.secondary : nil)
        show(Document(width: w, height: h, background: fill))
    }

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        var types: [UTType] = [.image]
        for x in ["sooth", "easel"] { if let e = UTType(filenameExtension: x) { types.append(e) } }
        if let e = UTType(filenameExtension: "pdn") { types.append(e) }
        p.allowedContentTypes = types
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { open(u) }
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = key.isEmpty ? [] : mods
        return i
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        top.submenu = m
        return top
    }

    private func filterItem(_ f: Filter, shiftKey: Bool) -> NSMenuItem {
        let title = f.params.isEmpty && !f.rawValues ? f.name : f.name + "…"
        let i = item(title, #selector(EditorWindowController.runFilter(_:)),
                     f.key.lowercased(), shiftKey ? [.command, .shift] : .command)
        i.representedObject = f
        return i
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let E = EditorWindowController.self
        let sep = { NSMenuItem.separator() }

        main.addItem(menu("Sooth", [
            item("About Sooth", #selector(showAbout(_:))),
            sep(),
            item("Hide Sooth", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            sep(),
            item("Quit Sooth", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        // Our own recent list (AppKit's needs NSDocument): rebuilt each time it opens.
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recent.submenu = recentMenu

        main.addItem(menu("File", [
            item("New…", #selector(newDocument(_:)), "n"),
            item("Open…", #selector(openDocument(_:)), "o"),
            recent,
            sep(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(E.saveDocument(_:)), "s"),
            item("Save As…", #selector(E.saveDocumentAs(_:)), "s", [.command, .shift]),
            sep(),
            item("Share…", #selector(E.shareImage(_:))),
        ]))

        main.addItem(menu("Edit", [
            item("Undo", #selector(E.doUndo(_:)), "z"),
            item("Redo", #selector(E.doRedo(_:)), "z", [.command, .shift]),
            sep(),
            item("Cut", #selector(E.cut(_:)), "x"),
            item("Copy", #selector(E.copy(_:)), "c"),
            item("Copy Merged", #selector(E.copyMerged(_:)), "c", [.command, .shift]),
            item("Paste", #selector(E.paste(_:)), "v"),
            item("Paste into New Layer", #selector(E.pasteNewLayer(_:)), "v", [.command, .shift]),
            item("Paste into New Image", #selector(E.pasteNewImage(_:)), "v", [.command, .option]),
            sep(),
            item("Select All", #selector(E.selectAll(_:)), "a"),
            item("Deselect", #selector(E.deselect(_:)), "d"),
            item("Invert Selection", #selector(E.invertSelection(_:)), "i"),
            sep(),
            item("Erase Selection  (⌫)", #selector(E.eraseSelection(_:))),
            item("Fill Selection  (⌥⌫)", #selector(E.fillSelection(_:))),
            item("Content-Aware Fill  (⇧⌫)", #selector(E.contentAwareFill(_:))),
            sep(),
            item("Add to Library", #selector(E.addToLibrary(_:)), "l", [.command, .shift]),
        ]))

        main.addItem(menu("View", [
            item("Zoom In", #selector(E.zoomIn(_:)), "="),
            item("Zoom Out", #selector(E.zoomOut(_:)), "-"),
            item("Zoom to Window", #selector(E.zoomFit(_:)), "0"),
            item("Actual Size", #selector(E.actualSize(_:)), "1"),
            sep(),
            item("Pixel Grid", #selector(E.toggleGrid(_:)), "'"),
            sep(),
            menu("Look", Look.allCases.map { l in
                let i = item(l.title, #selector(chooseLook(_:)))
                i.target = self
                i.representedObject = l.rawValue
                return i
            } + [sep(), {
                let i = item("Choose a Look…", #selector(showLookPicker(_:)))
                i.target = self
                return i
            }()]),
            sep(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(menu("Image", [
            item("Crop to Selection", #selector(E.cropToSelection(_:)), "x", [.command, .shift]),
            item("Auto-Crop", #selector(E.autoCrop(_:)), "c", [.command, .option]),
            item("Resize…", #selector(E.resizeImage(_:)), "r"),
            item("Canvas Size…", #selector(E.canvasSize(_:)), "r", [.command, .shift]),
            sep(),
            item("Flip Horizontal", #selector(E.flipImageH(_:))),
            item("Flip Vertical", #selector(E.flipImageV(_:))),
            sep(),
            item("Rotate 90° Clockwise", #selector(E.rotateCW(_:)), "]", [.command, .shift]),
            item("Rotate 90° Counter-Clockwise", #selector(E.rotateCCW(_:)), "[", [.command, .shift]),
            item("Rotate 180°", #selector(E.rotate180(_:))),
            sep(),
            item("Flatten", #selector(E.flatten(_:)), "f", [.command, .shift]),
        ]))

        main.addItem(menu("Layers", [
            item("Add New Layer", #selector(E.addLayer(_:)), "n", [.command, .shift]),
            item("Delete Layer", #selector(E.deleteLayer(_:))),
            item("Duplicate Layer", #selector(E.duplicateLayer(_:)), "d", [.command, .shift]),
            item("Merge Layer Down", #selector(E.mergeDown(_:)), "e"),
            item("Import from File…", #selector(E.importFromFile(_:))),
            item("Remove Background…", #selector(E.removeBackground(_:)), "b", [.command, .option]),
            item("Rasterize Layer", #selector(E.rasterizeLayer(_:))),
            sep(),
            item("Flip Layer Horizontal", #selector(E.flipLayerH(_:))),
            item("Flip Layer Vertical", #selector(E.flipLayerV(_:))),
            item("Rotate Layer 180°", #selector(E.rotateLayer180(_:))),
            sep(),
            item("Move Layer Up", #selector(E.moveLayerUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Move Layer Down", #selector(E.moveLayerDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            sep(),
            item("Layer Properties…", #selector(E.layerProperties(_:)), "p", [.command, .option]),
            item("Text Effects…", #selector(E.showTextEffects(_:)), "t", [.command, .option]),
            sep(),
            item("Add Layer Mask", #selector(E.addLayerMask(_:)), "m", [.command, .option]),
            item("Edit Mask", #selector(E.toggleMaskEditing(_:)), "\\"),
            item("Apply Layer Mask", #selector(E.applyLayerMask(_:))),
            item("Delete Layer Mask", #selector(E.deleteLayerMask(_:))),
            sep(),
            menu("New Adjustment Layer", AdjustmentSpec.filters.map { f in
                let i = item(f.name + (f.params.isEmpty && !f.rawValues ? "" : "…"), #selector(E.addAdjustmentLayer(_:)))
                i.representedObject = f
                return i
            }),
            item("Edit Adjustment…", #selector(E.editAdjustment(_:))),
            sep(),
            item("Vectorize…", #selector(E.vectorize(_:)), "v", [.command, .shift, .option]),
            item("Export Vector as SVG…", #selector(E.exportSVG(_:))),
        ]))

        main.addItem(menu("Adjustments", Filters.adjustments.map { filterItem($0, shiftKey: true) }))

        var fx: [NSMenuItem] = [item("Repeat Last Effect", #selector(E.repeatFilter(_:)), "f"), sep()]
        for (group, list) in Filters.effects {
            fx.append(menu(group, list.map { filterItem($0, shiftKey: false) }))
        }
        main.addItem(menu("Effects", fx))

        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            sep(),
            item("Library", #selector(E.toggleLibrary(_:)), "l"),
            sep(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        let help = menu("Help", [item("Sooth Shortcuts", #selector(showHelp(_:)), "/", [.command, .shift])])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }
}

// Sooth has its own crash recovery; macOS window restoration would only add a second
// "reopen windows?" prompt (and stalls headless runs such as --selftest).
UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
if CommandLine.arguments.contains(where: { ["--selftest", "--bench", "--export", "--demo", "--tour"].contains($0) }) {
    UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
