import AppKit

/// Renders an effect off the main thread. Previews coalesce: only one render runs at a time,
/// and while it runs only the newest requested values are kept, so dragging a slider never
/// queues up stale work or freezes the window.
final class FilterRunner {
    let filter: Filter
    let layer: Layer
    let src: Data
    private let selection: Selection?
    private let primary: RGBA, secondary: RGBA
    private let queue = DispatchQueue(label: "sooth.filter", qos: .userInitiated)
    private var running = false
    private var pending: [Double]?
    private var cancelled = false
    /// Newest finished render and the values it was made with.
    private var done: (values: [Double], pixels: Data)?
    var onPreview: (() -> Void)?

    init(filter: Filter, layer: Layer, selection: Selection?, primary: RGBA, secondary: RGBA) {
        self.filter = filter; self.layer = layer; self.selection = selection
        self.primary = primary; self.secondary = secondary
        src = layer.data()
    }

    /// Render `values` into a new buffer (any thread).
    private func render(_ values: [Double]) -> Data {
        var out = Data(count: src.count)
        let (w, h, f, sel, p, s) = (layer.width, layer.height, filter, selection, primary, secondary)
        src.withUnsafeBytes { raw in
            let sp = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            out.withUnsafeMutableBytes { o in
                let dp = o.baseAddress!.assumingMemoryBound(to: UInt8.self)
                f.run(FilterIO(src: sp, dst: dp, w: w, h: h, primary: p, secondary: s), values)
                if let sel { blendMask(src: sp, dst: dp, mask: sel.mask) }
            }
        }
        return out
    }

    func preview(_ values: [Double]) {
        if running { pending = values; return }
        running = true
        queue.async { [self] in
            let out = render(values)
            DispatchQueue.main.async { [self] in
                running = false
                guard !cancelled else { return }
                done = (values, out)
                layer.load(out)
                onPreview?()
                if let next = pending { pending = nil; preview(next) }
            }
        }
    }

    /// Restore the layer as it was.
    func cancel() {
        cancelled = true
        pending = nil
        layer.load(src)
    }

    /// Put the final result in the layer, then call `completion` on the main thread. Shows a
    /// progress sheet on `window` if the render takes more than a moment.
    /// `valid` is asked just before the result lands: if the image changed meanwhile (an undo in
    /// the moment before the sheet appears), the result is dropped and `completion` gets false.
    func finish(_ values: [Double], window: NSWindow?, valid: @escaping () -> Bool = { true },
                completion: @escaping (Bool) -> Void) {
        cancelled = true   // stop previews from landing after this
        pending = nil
        if let d = done, d.values == values {
            layer.load(d.pixels)
            completion(true)
            return
        }
        var sheet: NSWindow?
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !finished, let window else { return }
            sheet = FilterRunner.progressSheet(title: "Applying \(self.filter.name)…")
            window.beginSheet(sheet!)
        }
        queue.async { [self] in
            let out = render(values)
            DispatchQueue.main.async { [self] in
                finished = true
                if let sheet { window?.endSheet(sheet) }
                guard valid() else { completion(false); return }
                layer.load(out)
                completion(true)
            }
        }
    }

    static func progressSheet(title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76), styleMask: [.titled], backing: .buffered, defer: false)
        w.backgroundColor = Ink.window
        w.appearance = Look.current.appearance
        w.titlebarAppearsTransparent = true
        let spin = NSProgressIndicator()
        spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
        let s = NSStackView(views: [spin, label(title)])
        s.spacing = 10
        s.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        w.contentView = s
        return w
    }
}
