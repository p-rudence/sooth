import AppKit
import Vision

/// Finds the foreground subjects in an image with Apple's on-device subject model (the one the
/// Photos app uses to lift stickers). Works offline; nothing leaves the Mac.
final class SubjectMap {
    let width: Int, height: Int
    private let observation: VNInstanceMaskObservation
    private let handler: VNImageRequestHandler
    /// Instance label per pixel of the model's own (smaller) label map; 0 = background.
    private let labels: [UInt8]
    private let labelW: Int, labelH: Int

    var instances: IndexSet { observation.allInstances }

    private init(image: CGImage, observation: VNInstanceMaskObservation, handler: VNImageRequestHandler) {
        width = image.width; height = image.height
        self.observation = observation; self.handler = handler
        let buf = observation.instanceMask
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        labelW = CVPixelBufferGetWidth(buf); labelH = CVPixelBufferGetHeight(buf)
        let row = CVPixelBufferGetBytesPerRow(buf)
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        var l = [UInt8](repeating: 0, count: labelW * labelH)
        for y in 0..<labelH { for x in 0..<labelW { l[y * labelW + x] = base[y * row + x] } }
        labels = l
    }

    /// Run the model. Returns nil when no subject is found. Call off the main thread.
    static func detect(_ image: CGImage) -> SubjectMap? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let req = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        return SubjectMap(image: image, observation: obs, handler: handler)
    }

    /// The subject under an image-space point, if any.
    func instance(at p: CGPoint) -> Int? {
        let x = Int(p.x / CGFloat(width) * CGFloat(labelW)), y = Int(p.y / CGFloat(height) * CGFloat(labelH))
        guard x >= 0, y >= 0, x < labelW, y < labelH else { return nil }
        // Look a little around the point so a click just off a thin edge still counts.
        for r in 0...2 {
            for dy in -r...r { for dx in -r...r {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < labelW, yy < labelH else { continue }
                let v = Int(labels[yy * labelW + xx])
                if v != 0 { return v }
            } }
        }
        return nil
    }

    /// Soft full-resolution mask (0...255) of the given subjects, or all of them.
    func mask(_ which: IndexSet? = nil) -> [UInt8]? {
        guard let buf = try? observation.generateScaledMaskForImage(forInstances: which ?? instances, from: handler) else { return nil }
        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf), row = CVPixelBufferGetBytesPerRow(buf)
        guard w == width, h == height, let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        var m = [UInt8](repeating: 0, count: w * h)
        if CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_OneComponent32Float {
            for y in 0..<h {
                let r = (base + y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { m[y * w + x] = UInt8(max(0, min(1, r[x])) * 255 + 0.5) }
            }
        } else {
            for y in 0..<h {
                let r = (base + y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { m[y * w + x] = r[x] }
            }
        }
        return m
    }

    /// Bounding box of a mask (image coordinates), or nil if empty.
    static func bounds(of m: [UInt8], width w: Int, height h: Int, threshold: UInt8 = 8) -> CGRect? {
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            let r = y * w
            for x in 0..<w where m[r + x] > threshold {
                if x < x0 { x0 = x }; if x > x1 { x1 = x }
                if y < y0 { y0 = y }; if y > y1 { y1 = y }
            }
        }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    // MARK: Cache

    private nonisolated(unsafe) static var cache: [String: SubjectMap] = [:]
    private static let lock = NSLock()

    /// What detection runs on for a layer: an object's original pixels, else the layer itself.
    static func image(for l: Layer) -> (CGImage, String) {
        if let o = l.object { return (o.source, "o\(Unmanaged.passUnretained(o.source).toOpaque())") }
        return (l.image(), "r\(l.rev)")
    }

    /// Detection for an image, reused while it is unchanged. Safe to call off the main thread.
    static func cached(_ img: CGImage, key: String) -> SubjectMap? {
        let key = key + "@\(img.width)x\(img.height)"
        lock.lock(); let hit = cache[key]; lock.unlock()
        if let hit { return hit }
        guard let m = detect(img) else { return nil }
        lock.lock(); if cache.count > 8 { cache.removeAll() }; cache[key] = m; lock.unlock()
        return m
    }
}
