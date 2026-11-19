// Builds the app icon from glyph.svg (Caleb's design) on a glass tile.
// Run: swift app/Icon/make-icon.swift app/Icon
//   writes AppIcon.icns, AppIcon.png (README) and MenuBarIcon.pdf (template)
import AppKit

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/Icon")
guard let glyph = NSImage(contentsOf: dir.appendingPathComponent("glyph.svg")) else { fatalError("glyph.svg not found") }

// The glyph sits in a 1000-unit box; its strokes span about x 263–764, y 279–686 (top-down).
let glyphCenter = CGPoint(x: 513, y: 482)
let glyphScale: CGFloat = 1.2   // relative to the tile body

let tileColors = [NSColor(calibratedRed: 0.24, green: 0.42, blue: 1, alpha: 1),
                  NSColor(calibratedRed: 0.45, green: 0.27, blue: 0.96, alpha: 1)]

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Tile on the macOS icon grid (824/1024 body), with a soft drop shadow.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let tile = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = .init(width: 0, height: -s * 0.01)
    shadow.shadowColor = .black.withAlphaComponent(0.3)
    shadow.set()
    NSGradient(colors: tileColors)!.draw(in: tile, angle: -60)
    NSShadow().set()
    // Glass sheen across the top half.
    NSGraphicsContext.current?.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [.white.withAlphaComponent(0.28), .white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The glyph, centred on the tile.
    let unit = body.width / 1000 * glyphScale
    let side = 1000 * unit
    let origin = CGPoint(x: body.midX - glyphCenter.x * unit,
                         y: body.midY - (1000 - glyphCenter.y) * unit)
    glyph.draw(in: CGRect(origin: origin, size: CGSize(width: side, height: side)))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// App icon.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", dir.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
try draw(512).write(to: dir.appendingPathComponent("AppIcon.png"))

// Menu-bar icon: the glyph alone, cropped to its strokes, as a vector PDF.
// Marked as a template at runtime so macOS tints it for light and dark menu bars.
let crop = CGRect(x: 250, y: 1000 - 700, width: 530, height: 430) // bottom-up
let pdf = NSMutableData()
var box = CGRect(origin: .zero, size: crop.size)
let ctx = CGContext(consumer: CGDataConsumer(data: pdf as CFMutableData)!, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
glyph.draw(in: CGRect(x: -crop.minX, y: -crop.minY, width: 1000, height: 1000))
NSGraphicsContext.restoreGraphicsState()
ctx.endPDFPage()
ctx.closePDF()
try (pdf as Data).write(to: dir.appendingPathComponent("MenuBarIcon.pdf"))
print("Wrote AppIcon.icns, AppIcon.png, MenuBarIcon.pdf")
