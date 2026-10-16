// Draws the Sooth icon in the Tianmu Labs house style (筆, the brush, glowing white on a black
// scanlined tile, with three pixel dabs of paint for the cursor), as an .iconset folder.
// Usage: swift tools/make_icon.swift <out.iconset>
import AppKit

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    NSGraphicsContext.current?.cgContext.scaleBy(x: k, y: k)

    let ink = NSColor(white: 0.96, alpha: 1)
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSColor.black.setFill(); tile.fill()
    ink.withAlphaComponent(0.28).setStroke(); tile.lineWidth = 8; tile.stroke()

    // faint scanlines
    tile.addClip()
    NSColor(white: 0, alpha: 0.28).setFill()
    for y in stride(from: 100, to: 924, by: 12) { NSRect(x: 100, y: y, width: 824, height: 4).fill() }

    let glow = NSShadow()
    glow.shadowColor = ink.withAlphaComponent(0.35); glow.shadowBlurRadius = 38; glow.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    glow.set()
    let font = NSFont(name: "Hiragino Sans W3", size: 470) ?? .systemFont(ofSize: 470)
    let brush = NSAttributedString(string: "筆", attributes: [.font: font, .foregroundColor: ink])
    let s = brush.size()
    brush.draw(at: NSPoint(x: (1024 - s.width) / 2 - 40, y: (1024 - s.height) / 2 + 30))
    NSGraphicsContext.restoreGraphicsState()

    // the cursor: three square dabs of paint, red, green, blue, each with its own soft glow
    for (i, c) in [NSColor(srgbRed: 1, green: 0.27, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.3, green: 0.92, blue: 0.45, alpha: 1),
                   NSColor(srgbRed: 0.33, green: 0.55, blue: 1, alpha: 1)].enumerated() {
        let g = NSShadow(); g.shadowColor = c.withAlphaComponent(0.7); g.shadowBlurRadius = 26; g.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState(); g.set()
        c.setFill(); NSRect(x: 648 + CGFloat(i) * 56, y: 236, width: 40, height: 40).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
