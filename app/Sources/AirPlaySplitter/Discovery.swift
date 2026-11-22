import Foundation

/// Finds AirPlay receivers with macOS's own Bonjour (doubletake's built-in
/// mDNS client doesn't coexist with mDNSResponder on macOS).
final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var pending: Set<NetService> = []
    private var found: [String: DaemonClient.Device] = [:]   // by service name
    var onChange: (([DaemonClient.Device]) -> Void)?

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
    }

    /// Looks again (the Refresh button). The list stays in place while
    /// looking so the menu doesn't jump, then anything that didn't answer
    /// (a TV in another building, one that's unplugged) is dropped.
    func restart() {
        browser.stop()
        pending.removeAll()
        unconfirmed = Set(found.keys)
        start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.unconfirmed.isEmpty else { return }
            for name in self.unconfirmed { self.found[name] = nil }
            self.unconfirmed = []
            self.publish()
        }
    }
    private var unconfirmed: Set<String> = []

    func netServiceBrowser(_ b: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        unconfirmed.remove(service.name)
        pending.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ b: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        found[service.name] = nil
        pending.remove(service)
        publish()
    }

    func netServiceDidResolveAddress(_ service: NetService) {
        defer { pending.remove(service) }
        guard let ip = Self.ipv4(service.addresses ?? []) else { return }
        var txt: [String: String] = [:]
        if let data = service.txtRecordData() {
            for (k, v) in NetService.dictionary(fromTXTRecord: data) {
                txt[k] = String(data: v, encoding: .utf8)
            }
        }
        unconfirmed.remove(service.name)
        found[service.name] = DaemonClient.Device(
            name: service.name, model: txt["model"] ?? "", ip: ip,
            port: service.port, device_id: txt["deviceid"] ?? "")
        publish()
    }

    private func publish() {
        NSLog("AirPlaySplitter receivers: %@", found.values.map { "\($0.name)=\($0.ip):\($0.port)" }.sorted().joined(separator: ", "))
        onChange?(Array(found.values))
    }

    private static func ipv4(_ addresses: [Data]) -> String? {
        for data in addresses {
            let ip: String? = data.withUnsafeBytes { raw in
                guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var sin = raw.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count))
                return String(cString: buf)
            }
            if let ip { return ip }
        }
        return nil
    }
}
