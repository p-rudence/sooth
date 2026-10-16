import AppKit

/// Autosave for crash recovery. While an image has unsaved changes, a copy is written every few
/// seconds to ~/Library/Application Support/Sooth/Recovery (encoded off the main thread). It is
/// removed when the image is saved or closed; after a crash, the next launch offers it back.
final class Recovery {
    /// Where copies go (the self-test points this at a temporary folder).
    nonisolated(unsafe) static var folder: URL = {
        supportFolder("Recovery")
    }()
    /// Off for headless runs (--selftest, --bench, --export) so they never leave copies behind.
    static let automatic = !CommandLine.arguments.contains { ["--selftest", "--bench", "--export", "--tour"].contains($0) }
    private static let queue = DispatchQueue(label: "sooth.recovery", qos: .utility)

    private weak var doc: Document?
    let file: URL
    private var timer: Timer?
    private var savedRevision = -1
    private var writing = false

    init(doc: Document) {
        self.doc = doc
        file = Recovery.folder.appendingPathComponent(UUID().uuidString + ".sooth")
        guard Recovery.automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 5
    }

    deinit { timer?.invalidate() }

    func tick() {
        guard let doc, !writing else { return }
        guard doc.dirty else { discard(); return }
        guard doc.revision != savedRevision else { return }
        var snap = doc.snapshotForSaving()
        snap.extra = ["recoveredName": doc.displayName, "recoveredFrom": doc.fileURL?.path ?? ""]
        let rev = doc.revision, file = file
        writing = true
        Recovery.queue.async { [weak self] in
            let ok = (try? snap.encode().write(to: file, options: .atomic)) != nil
            DispatchQueue.main.async { self?.writing = false; if ok { self?.savedRevision = rev } }
        }
    }

    /// The image was saved or closed: its recovery copy is no longer needed.
    func discard() {
        savedRevision = -1
        let f = file
        Recovery.queue.async { try? FileManager.default.removeItem(at: f) }
    }

    /// Wait for pending writes (tests).
    static func drain() { queue.sync {} }

    func stop() { timer?.invalidate(); discard() }

    /// Recovery copies left by a session that didn't quit normally.
    static func leftovers() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["sooth", "easel"].contains($0.pathExtension) }
    }

    static func recoveredName(_ u: URL) -> String {
        guard let d = try? Data(contentsOf: u),
              let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] else { return "Untitled" }
        return p["recoveredName"] as? String ?? "Untitled"
    }
}
