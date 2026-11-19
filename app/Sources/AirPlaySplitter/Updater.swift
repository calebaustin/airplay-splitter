import Foundation
import AppKit

/// Quietly checks GitHub for a newer release: shortly after launch, then once
/// a day. Never downloads or installs anything by itself; the menu offers a
/// direct link to the new DMG. Failures (offline, rate limits) are ignored.
@MainActor
final class Updater: ObservableObject {
    struct Update: Equatable {
        let version: String
        let dmgURL: URL
        let pageURL: URL
    }

    @Published private(set) var available: Update?

    /// The GitHub repository releases are published to (Info.plist
    /// `SplitterUpdateRepo`, so forks can point at their own).
    private let repo = Bundle.main.object(forInfoDictionaryKey: "SplitterUpdateRepo") as? String
        ?? "calebaustin/airplay-splitter"
    private let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private var timer: Timer?

    func start() {
        Task { try? await Task.sleep(for: .seconds(15)); await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    /// "Later": hide this version until a newer one appears.
    func skip() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: "skippedVersion") }
        available = nil
    }

    func download() {
        guard let u = available else { return }
        NSWorkspace.shared.open(u.dmgURL)
    }

    func openReleasePage() {
        guard let u = available else { return }
        NSWorkspace.shared.open(u.pageURL)
    }

    func check() async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AirPlay-Splitter/\(current)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let dmg = (json["assets"] as? [[String: Any]] ?? [])
            .compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".dmg") }
            .flatMap(URL.init(string:)) ?? page
        guard Self.isNewer(version, than: current),
              UserDefaults.standard.string(forKey: "skippedVersion") != version else { return }
        available = Update(version: version, dmgURL: dmg, pageURL: page)
    }

    /// Compares dotted versions numerically (0.10.0 is newer than 0.9.1).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
