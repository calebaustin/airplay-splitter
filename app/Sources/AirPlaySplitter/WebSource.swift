import AppKit
import WebKit

/// Shows a web page on the TVs: a hidden 1280×720 browser window, captured a
/// few times a second and scaled to 1080p (so pages read at a comfortable
/// size from across a room). Good for dashboards, web slides and signage.
@MainActor
final class WebSource: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var loading = false
    @Published private(set) var failed: String?

    private static let viewport = CGSize(width: 1280, height: 720)
    private var window: NSWindow?
    private var web: WKWebView?
    private var timer: Timer?
    private let lock = NSLock()
    nonisolated(unsafe) private var latest: CVPixelBuffer?

    func load(_ url: URL) {
        if web == nil { makeView() }
        failed = nil
        loading = true
        if url.isFileURL {
            // Local signage pages: allow the page to read files beside it.
            web?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web?.load(URLRequest(url: url))
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.snapshot() }
            }
        }
    }

    func reload() { web?.reload() }

    func stop() {
        timer?.invalidate(); timer = nil
        web?.stopLoading()
        web?.loadHTMLString("", baseURL: nil)
        lock.withLock { latest = nil }
    }

    /// The latest snapshot (safe from the capture thread).
    nonisolated func frame() -> CVPixelBuffer? { lock.withLock { latest } }

    private func makeView() {
        let rect = CGRect(origin: .zero, size: Self.viewport)
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: rect, configuration: cfg)
        v.navigationDelegate = self
        // WebKit stops drawing windows macOS reports as hidden, and a window
        // that's fully off-screen counts as hidden. So one pixel sits on the
        // screen's edge at 1% opacity: invisible in practice, but "visible".
        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = v
        w.sharingType = .none
        w.ignoresMouseEvents = true
        w.alphaValue = 0.01
        w.hasShadow = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let screen = NSScreen.screens.first?.frame ?? .zero
        w.setFrameOrigin(CGPoint(x: screen.maxX - 1, y: screen.minY))
        w.orderFrontRegardless()
        window = w
        web = v
    }

    private func snapshot() {
        guard let web else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Double(Self.viewport.width))
        web.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self, let image, let pb = ContentRenderer.image(image) else { return }
            self.lock.withLock { self.latest = pb }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false; failed = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false; failed = error.localizedDescription
    }
}
