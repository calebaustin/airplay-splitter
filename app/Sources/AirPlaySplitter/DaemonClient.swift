import Foundation

/// Talks to the bundled doubletake daemon over its Unix socket (one JSON
/// request and one JSON response per connection).
struct DaemonClient {
    let socketPath: String

    struct Device: Decodable, Hashable, Identifiable {
        let name: String
        let model: String
        let ip: String
        let port: Int
        let device_id: String
        var id: String { ip }
    }

    struct Stream: Decodable, Hashable {
        let device: String
        let device_ip: String
        let state: String
        let width: Int?
        let height: Int?
        let encoder: String?
    }

    struct Response: Decodable {
        let ok: Bool
        let state: String?
        let error: String?
        let needs_pin: Bool?
        let needs_credential: Bool?
        let devices: [Device]?
        let streams: [Stream]?
        let device_ip: String?
    }

    func send(_ request: [String: Any]) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw err("socket") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw err("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: pathBytes)
            buf[pathBytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else { throw err("daemon not running") }

        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var body = try JSONSerialization.data(withJSONObject: request)
        body.append(0x0A)
        _ = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        // Read until a complete JSON value decodes.
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            data.append(chunk, count: n)
            if let r = try? JSONDecoder().decode(Response.self, from: data) { return r }
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "AirPlaySplitter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
