import Foundation

/// Minimal RFC 6184 H.264 RTP packetizer (single NAL + FU-A) that sends to a
/// localhost UDP port. doubletake's relay source (udpsrc ! rtph264depay) reads it.
final class RTPSender {
    private let fd: Int32
    private var addr = sockaddr_in()
    private var seq: UInt16 = UInt16.random(in: 0...UInt16.max)
    private let ssrc: UInt32 = UInt32.random(in: 1...UInt32.max)
    private let maxPayload = 1400

    init(port: UInt16) {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var buf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buf, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    /// Sends one access unit. `nals` are raw NAL units (no start codes or
    /// length prefixes). `timestamp` is in the 90 kHz RTP clock.
    func send(nals: [Data], timestamp: UInt32) {
        for (i, nal) in nals.enumerated() where !nal.isEmpty {
            let last = i == nals.count - 1
            if nal.count <= maxPayload {
                packet(payload: nal, marker: last, ts: timestamp)
                continue
            }
            // FU-A fragmentation.
            let header = nal[nal.startIndex]
            let fuIndicator = (header & 0xE0) | 28
            let type = header & 0x1F
            var offset = nal.startIndex + 1
            var first = true
            while offset < nal.endIndex {
                let end = min(offset + maxPayload - 2, nal.endIndex)
                let isEnd = end == nal.endIndex
                var fuHeader = type
                if first { fuHeader |= 0x80 }
                if isEnd { fuHeader |= 0x40 }
                var payload = Data([fuIndicator, fuHeader])
                payload.append(nal[offset..<end])
                packet(payload: payload, marker: last && isEnd, ts: timestamp)
                offset = end
                first = false
            }
        }
    }

    /// One RTP packet with the payload as-is (used for L16 audio).
    func sendRaw(payload: Data, timestamp: UInt32) {
        packet(payload: payload, marker: false, ts: timestamp)
    }

    private func packet(payload: Data, marker: Bool, ts: UInt32) {
        var p = Data(capacity: 12 + payload.count)
        p.append(0x80)                                  // V=2
        p.append((marker ? 0x80 : 0) | 96)              // M + PT 96
        p.append(contentsOf: withUnsafeBytes(of: seq.bigEndian, Array.init))
        p.append(contentsOf: withUnsafeBytes(of: ts.bigEndian, Array.init))
        p.append(contentsOf: withUnsafeBytes(of: ssrc.bigEndian, Array.init))
        p.append(payload)
        seq &+= 1
        p.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
