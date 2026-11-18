// Draws the app icon. Run: swift app/Icon/make-icon.swift app/Icon/AppIcon.icns
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: 824/1024 body with continuous corners.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = .init(width: 0, height: -s * 0.01)
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 0.24, green: 0.42, blue: 1, alpha: 1),
                        NSColor(calibratedRed: 0.45, green: 0.27, blue: 0.96, alpha: 1)])!
        .draw(in: path, angle: -60)
    NSShadow().set()
    // Glass sheen across the top half.
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    // One screen fanning out to three.
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.30, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let r = CGRect(x: (s - sym.size.width) / 2, y: s * 0.43, width: sym.size.width, height: sym.size.height)
        sym.draw(in: r)
    }
    let small = NSImage.SymbolConfiguration(pointSize: s * 0.12, weight: .semibold)
        .applying(.init(paletteColors: [.white.withAlphaComponent(0.9)]))
    if let tv = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)?.withSymbolConfiguration(small) {
        let w = tv.size.width, gap = s * 0.05
        let total = w * 3 + gap * 2
        for i in 0..<3 {
            tv.draw(in: CGRect(x: (s - total) / 2 + CGFloat(i) * (w + gap), y: s * 0.22, width: w, height: tv.size.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run(); p.waitUntilExit()
try draw(512).write(to: URL(fileURLWithPath: out).deletingPathExtension().appendingPathExtension("png"))
print("Wrote \(out)")
