import AppKit
import VirtualDisplayShim

/// A 1920×1080 screen that exists only in software. macOS treats it like a
/// monitor plugged in by HDMI: it appears in System Settings › Displays, you
/// can drag windows onto it, and AirPlay Splitter sends it to every TV. It
/// goes away when it's no longer needed or the app quits.
///
/// macOS 26 is picky about virtual screens (lessons from the open-source
/// OpenDisplay project, which hit the same wall):
/// - A screen macOS once refused stays refused for that identity (serial
///   number), even after logging out. So if a screen doesn't come online
///   within a few seconds we try a fresh serial, and remember the one that
///   works so the screen keeps its place in Displays settings.
/// - The pixel reservation should match the mode (1920×1080), with a
///   believable monitor size, or macOS accepts it but never brings it online.
/// - "Online" means listed by CGGetOnlineDisplayList; CGDisplayIsOnline can
///   return -1 for unknown IDs.
@MainActor
final class VirtualScreen {
    static let width: UInt32 = 1920
    static let height: UInt32 = 1080
    static let name = "AirPlay Splitter Screen"
    private static let serialKey = "virtualScreenSerial"

    private var display: CGVirtualDisplay?

    /// The screen's ID while it exists.
    var displayID: CGDirectDisplayID? { display?.displayID }
    var isOn: Bool { display != nil }

    /// Adds the screen and waits until macOS really lists it, trying fresh
    /// identities if needed. Returns false if every attempt was refused.
    func start() async -> Bool {
        if let id = displayID, Self.isOnline(id) { return true }
        remove()
        var serial = UInt32(UserDefaults.standard.integer(forKey: Self.serialKey))
        if serial == 0 { serial = UInt32.random(in: 0x1000...0xFFFF) << 8 }
        for attempt in 0..<5 {
            let s = serial &+ UInt32(attempt)
            guard let v = make(serial: s) else { continue }
            display = v
            // Usually online within a fraction of a second.
            for _ in 0..<20 {
                if Self.isOnline(v.displayID) {
                    UserDefaults.standard.set(Int(s), forKey: Self.serialKey)
                    return true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            display = nil   // refused: drop it and try a fresh identity
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    /// Removes the screen; windows on it move back to the main screen.
    func remove() { display = nil }

    private func make(serial: UInt32) -> CGVirtualDisplay? {
        let d = CGVirtualDisplayDescriptor()
        d.name = Self.name
        d.maxPixelsWide = Self.width
        d.maxPixelsHigh = Self.height
        d.sizeInMillimeters = CGSize(width: 600, height: 340)   // a 27" monitor
        d.vendorID = 0x4153          // "AS"
        d.productID = 0x5350         // "SP"
        d.serialNum = serial
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)            // sRGB
        d.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        d.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        d.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        d.setDispatchQueue(DispatchQueue.main)
        d.terminationHandler = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.display = nil } }
        }
        guard let v = CGVirtualDisplay(descriptor: d) else { return nil }
        let s = CGVirtualDisplaySettings()
        s.hiDPI = 0
        // A monitor-like mode list (a single odd mode can look like a TV).
        s.modes = [CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
                   CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60),
                   CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60)]
        return v.apply(s) ? v : nil
    }

    static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &n) == .success else { return false }
        return ids.prefix(Int(n)).contains(id)
    }
}
