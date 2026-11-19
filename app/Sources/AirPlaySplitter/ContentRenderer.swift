import AppKit
import CoreVideo

/// Settings for the holding screen and countdown, saved between launches.
struct HoldingDesign: Codable, Equatable {
    var title = "Welcome"
    var subtitle = "We'll begin shortly"
    var logoPath: String?
    var background = "#1E2A4A"   // hex
    var countdownLabel = "Starting in"

    static func load() -> HoldingDesign {
        guard let d = UserDefaults.standard.data(forKey: "holdingDesign"),
              let v = try? JSONDecoder().decode(HoldingDesign.self, from: d) else { return HoldingDesign() }
        return v
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "holdingDesign") }
    }
}

/// Draws the app's own content (image, holding screen, countdown) as 1080p
/// frames for the TVs. Everything goes through one stream, so every TV shows
/// the same thing at the same moment.
enum ContentRenderer {
    static let size = CGSize(width: 1920, height: 1080)

    /// An image fitted onto black, letterboxed if its shape differs.
    static func image(_ img: NSImage) -> CVPixelBuffer? {
        draw { ctx, rect in
            NSColor.black.setFill(); rect.fill()
            let s = img.size
            guard s.width > 0, s.height > 0 else { return }
            let scale = min(rect.width / s.width, rect.height / s.height)
            let fit = CGSize(width: s.width * scale, height: s.height * scale)
            img.draw(in: CGRect(x: (rect.width - fit.width) / 2, y: (rect.height - fit.height) / 2,
                                width: fit.width, height: fit.height))
        }
    }

    /// Background, optional logo, title and subtitle.
    static func holding(_ d: HoldingDesign, logo: NSImage?) -> CVPixelBuffer? {
        draw { _, rect in
            background(d, rect)
            var y = rect.midY + 40
            if let logo, logo.size.width > 0 {
                let h: CGFloat = 220, w = min(700, logo.size.width * h / logo.size.height)
                logo.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY + 90, width: w, height: h))
                y = rect.midY - 30
            }
            text(d.title, size: 110, weight: .bold, centerY: y, in: rect)
            text(d.subtitle, size: 52, weight: .regular, centerY: y - 120, in: rect, alpha: 0.8)
        }
    }

    /// The holding background with a large clock counting down to `end`.
    static func countdown(_ d: HoldingDesign, logo: NSImage?, remaining: TimeInterval) -> CVPixelBuffer? {
        draw { _, rect in
            background(d, rect)
            if let logo, logo.size.width > 0 {
                let h: CGFloat = 140, w = min(500, logo.size.width * h / logo.size.height)
                logo.draw(in: CGRect(x: rect.midX - w / 2, y: rect.maxY - h - 90, width: w, height: h))
            }
            let secs = max(0, Int(remaining.rounded(.up)))
            if secs == 0 {
                text("Starting now", size: 150, weight: .bold, centerY: rect.midY, in: rect)
            } else {
                text(d.countdownLabel, size: 60, weight: .medium, centerY: rect.midY + 190, in: rect, alpha: 0.85)
                let clock = secs >= 3600
                    ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
                    : String(format: "%d:%02d", secs / 60, secs % 60)
                text(clock, size: 300, weight: .bold, centerY: rect.midY - 40, in: rect, monospaced: true)
            }
            if !d.title.isEmpty {
                text(d.title, size: 48, weight: .regular, centerY: rect.minY + 120, in: rect, alpha: 0.75)
            }
        }
    }

    // MARK: drawing helpers

    private static func background(_ d: HoldingDesign, _ rect: CGRect) {
        let base = NSColor(hex: d.background) ?? .darkGray
        let lighter = base.blended(withFraction: 0.18, of: .white) ?? base
        let darker = base.blended(withFraction: 0.35, of: .black) ?? base
        NSGradient(colors: [lighter, base, darker])?.draw(in: rect, angle: -70)
    }

    private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, centerY: CGFloat,
                             in rect: CGRect, alpha: CGFloat = 1, monospaced: Bool = false) {
        guard !s.isEmpty else { return }
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
                                                    .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
        let str = NSAttributedString(string: s, attributes: attrs)
        let h = str.boundingRect(with: CGSize(width: rect.width - 160, height: 10_000),
                                 options: [.usesLineFragmentOrigin]).height
        str.draw(with: CGRect(x: 80, y: centerY - h / 2, width: rect.width - 160, height: h),
                 options: [.usesLineFragmentOrigin])
    }

    private static func draw(_ body: (CGContext, CGRect) -> Void) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pb)
                == kCVReturnSuccess, let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width),
                                  height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        body(ctx, CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return pb
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255),
                      Int(c.blueComponent * 255))
    }
}
