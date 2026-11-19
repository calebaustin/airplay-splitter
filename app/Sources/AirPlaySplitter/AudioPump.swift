import Foundation
import CoreMedia
import AudioToolbox

/// Sends the Mac's audio to doubletake as L16 RTP (44.1 kHz stereo, 16-bit
/// big-endian), one 10 ms packet at a time on a steady clock.
///
/// ScreenCaptureKit delivers audio in bursts and sends nothing during
/// silence. Receivers need a continuous stream, so missing time is filled
/// with silence. Muting simply sends silence, which keeps every TV's audio
/// clock running without reconnecting.
final class AudioPump {
    static let sampleRate = 44_100
    private static let framesPerPacket = 441           // 10 ms
    private static let bytesPerFrame = 4               // 2 ch × 16 bit
    private static let maxBuffered = sampleRate / 4    // drop audio older than 250 ms

    private let rtp: RTPSender
    private let queue = DispatchQueue(label: "splitter.audio")
    private var buffer = Data()                        // S16BE interleaved
    private var timer: DispatchSourceTimer?
    private var rtpTime: UInt32 = 0
    private var started = Date()
    private var sentPackets = 0

    /// When true, silence is sent instead of captured audio.
    var muted = true

    init(port: UInt16) { rtp = RTPSender(port: port) }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        started = Date()
        sentPackets = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { self.buffer.removeAll() }
    }

    /// Send every packet that is due by now, so the stream tracks real time
    /// even if the timer fires late.
    private func tick() {
        let due = Int(Date().timeIntervalSince(started) * Double(Self.sampleRate)) / Self.framesPerPacket
        while sentPackets < due {
            let bytes = Self.framesPerPacket * Self.bytesPerFrame
            var payload: Data
            if !muted && buffer.count >= bytes {
                payload = buffer.prefix(bytes)
                buffer.removeFirst(bytes)
            } else {
                payload = Data(count: bytes)
            }
            rtp.sendRaw(payload: payload, timestamp: rtpTime)
            rtpTime &+= UInt32(Self.framesPerPacket)
            sentPackets += 1
        }
    }

    /// Accepts a ScreenCaptureKit audio sample buffer (Float32 or Int16,
    /// interleaved or not) and queues it as 16-bit big-endian stereo.
    func append(_ sample: CMSampleBuffer) {
        guard !muted,
              let fmt = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &listSize,
            bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
                bufferListOut: list, bufferListSize: listSize, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &block) == noErr else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let frames = CMSampleBufferGetNumSamples(sample)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return }

        func pcm(_ ch: Int, _ i: Int) -> Int16 {
            let c = min(ch, channels - 1)
            let (buf, idx) = interleaved ? (buffers[0], i * channels + c) : (buffers[c], i)
            guard let p = buf.mData else { return 0 }
            if isFloat {
                let v = p.assumingMemoryBound(to: Float32.self)[idx]
                return Int16(max(-1, min(1, v)) * 32767)
            }
            return p.assumingMemoryBound(to: Int16.self)[idx]
        }

        var out = Data(count: frames * Self.bytesPerFrame)
        out.withUnsafeMutableBytes { dst in
            let d = dst.bindMemory(to: UInt16.self)
            for i in 0..<frames {
                d[i * 2] = UInt16(bitPattern: pcm(0, i)).bigEndian
                d[i * 2 + 1] = UInt16(bitPattern: pcm(1, i)).bigEndian
            }
        }
        enqueue(out)
    }

    private func enqueue(_ out: Data) {
        queue.async {
            self.buffer.append(out)
            let limit = Self.maxBuffered * Self.bytesPerFrame
            if self.buffer.count > limit { self.buffer.removeFirst(self.buffer.count - limit) }
        }
    }

    /// Accepts float PCM at any sample rate (for example a video's 48 kHz
    /// track) and resamples it to 44.1 kHz. `channels` holds one pointer per
    /// channel; mono is sent to both sides.
    func appendFloat(channels: [UnsafePointer<Float>], frames: Int, sampleRate: Double) {
        guard !muted, frames > 0, !channels.isEmpty, sampleRate > 0 else { return }
        let ratio = sampleRate / Double(Self.sampleRate)
        let outFrames = Int(Double(frames) / ratio)
        guard outFrames > 0 else { return }
        let left = channels[0], right = channels.count > 1 ? channels[1] : channels[0]
        var out = Data(count: outFrames * Self.bytesPerFrame)
        out.withUnsafeMutableBytes { dst in
            let d = dst.bindMemory(to: UInt16.self)
            for i in 0..<outFrames {
                // Linear interpolation between neighbouring input samples.
                let pos = Double(i) * ratio
                let j = min(Int(pos), frames - 1), k = min(j + 1, frames - 1)
                let f = Float(pos - Double(j))
                let l = left[j] + (left[k] - left[j]) * f
                let r = right[j] + (right[k] - right[j]) * f
                d[i * 2] = UInt16(bitPattern: Int16(max(-1, min(1, l)) * 32767)).bigEndian
                d[i * 2 + 1] = UInt16(bitPattern: Int16(max(-1, min(1, r)) * 32767)).bigEndian
            }
        }
        enqueue(out)
    }
}
