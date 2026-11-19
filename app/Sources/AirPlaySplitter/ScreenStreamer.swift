import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AppKit
import CoreText
import CoreImage

/// Captures one display with ScreenCaptureKit, hardware-encodes it to H.264
/// and sends it as RTP to localhost for doubletake to fan out.
///
/// ScreenCaptureKit only delivers frames when the screen changes. A static
/// slide would otherwise produce no video at all, so the last frame is
/// re-encoded on a steady cadence.
final class ScreenStreamer: NSObject, SCStreamOutput {
    private let fps: Int32 = 30
    private let maxWidth = 1920, maxHeight = 1080
    private let rtp: RTPSender
    private let queue = DispatchQueue(label: "splitter.capture")

    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var repeatTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0

    /// The Mac's sound, when capture includes audio.
    let audio: AudioPump
    /// A small image of what's being sent, about three times a second while
    /// `previewEnabled` is on (the menu is open).
    var onPreview: ((CGImage) -> Void)?
    var previewEnabled = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var config: SCStreamConfiguration?

    init(rtpPort: UInt16, audioPort: UInt16) {
        rtp = RTPSender(port: rtpPort)
        audio = AudioPump(port: audioPort)
    }

    static func displays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    func start(display: SCDisplay, sourceRect: CGRect? = nil, captureAudio: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let size = sourceRect?.size ?? CGSize(width: display.width, height: display.height)
        try await start(filter: filter, contentSize: size, sourceRect: sourceRect, captureAudio: captureAudio)
    }

    /// Starts capture for any filter: a display, part of one, or a window
    /// chosen with the system sharing picker.
    func start(filter: SCContentFilter, contentSize: CGSize, sourceRect: CGRect? = nil,
               captureAudio: Bool) async throws {
        stop()
        let scale = CGFloat(filter.pointPixelScale)
        let (w, h) = fit(Int(contentSize.width * max(1, scale)), Int(contentSize.height * max(1, scale)))
        try makeEncoder(width: w, height: h)

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        if let sourceRect { cfg.sourceRect = sourceRect }
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        cfg.showsCursor = true
        cfg.queueDepth = 4
        cfg.capturesAudio = true                  // always on; the pump mutes
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = AudioPump.sampleRate
        cfg.channelCount = 2
        config = cfg
        audio.muted = !captureAudio

        let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
        audio.start()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(Int(1000 / fps)))
        t.setEventHandler { [weak self] in self?.repeatIfIdle() }
        t.resume()
        repeatTimer = t
    }

    /// Streams a moving test card. Needs no Screen Recording permission, so it
    /// checks the TVs and network on its own.
    func startTestPattern() throws {
        stop()
        let (w, h) = (1920, 1080)
        try makeEncoder(width: w, height: h)
        audio.muted = true      // keep a silent audio track running
        audio.start()
        let started = Date()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Int(1000 / fps)))
        t.setEventHandler { [weak self] in
            guard let self, let pb = Self.testCard(width: w, height: h, t: Date().timeIntervalSince(started)) else { return }
            self.lastBuffer = pb
            self.encode(pb)
        }
        t.resume()
        repeatTimer = t
    }

    private static func testCard(width: Int, height: Int, t: Double) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let bars: [(CGFloat, CGFloat, CGFloat)] = [(1,1,1),(1,1,0),(0,1,1),(0,1,0),(1,0,1),(1,0,0),(0,0,1)]
        let bw = CGFloat(width) / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0 * 0.75, green: c.1 * 0.75, blue: c.2 * 0.75, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * bw, y: 0, width: bw, height: CGFloat(height)))
        }
        // A bar that sweeps once every 2 s makes frozen video obvious.
        let x = CGFloat(t.truncatingRemainder(dividingBy: 2) / 2) * CGFloat(width)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: 24, height: CGFloat(height)))
        ctx.fill(CGRect(x: CGFloat(width) * 0.25, y: CGFloat(height) * 0.42, width: CGFloat(width) * 0.5, height: CGFloat(height) * 0.16))
        let label = NSAttributedString(string: "AirPlay Splitter test", attributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(label)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2, y: CGFloat(height) / 2 - bounds.height / 3)
        CTLineDraw(line, ctx)
        return pb
    }

    func stop() {
        audio.stop()
        repeatTimer?.cancel(); repeatTimer = nil
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        queue.sync {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            lastBuffer = nil
        }
    }

    // MARK: capture

    /// Turns sending the Mac's sound on or off without restarting capture.
    func setAudio(_ on: Bool) { audio.muted = !on }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sb.isValid { audio.append(sb) }
            return
        }
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        lastBuffer = pb
        encode(pb)
    }

    private func repeatIfIdle() {
        guard let pb = lastBuffer else { return }
        if CFAbsoluteTimeGetCurrent() - lastFrameTime >= 0.9 / Double(fps) { encode(pb) }
    }

    // MARK: encode

    private func encode(_ pb: CVPixelBuffer) {
        guard let session else { return }
        lastFrameTime = CFAbsoluteTimeGetCurrent()
        let pts = CMTime(value: frameIndex, timescale: fps)
        frameIndex += 1
        if previewEnabled, frameIndex % 10 == 0, let onPreview { makePreview(pb).map(onPreview) }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: CMTime(value: 1, timescale: fps),
                                        frameProperties: nil, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.packetize(sample)
        }
    }

    /// A 320-pixel-wide copy of the frame for the menu's preview.
    private func makePreview(_ pb: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pb)
        let scale = 320 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(small, from: small.extent)
    }

    private func makeEncoder(width: Int, height: Int) throws {
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let rc = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard rc == noErr, let s else {
            throw NSError(domain: "AirPlaySplitter", code: Int(rc),
                          userInfo: [NSLocalizedDescriptionKey: "Could not start the hardware H.264 encoder (\(rc))"])
        }
        // Local hop only, so spend bits generously: doubletake re-encodes once
        // for the TVs and we want that second generation to stay sharp.
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps),
            kVTCompressionPropertyKey_ExpectedFrameRate: Int(fps),
            kVTCompressionPropertyKey_AverageBitRate: 16_000_000,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    private func packetize(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var nals: [Data] = []

        let notSync = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?
            .first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync, let fmt = CMSampleBufferGetFormatDescription(sample) {
            // Send SPS + PPS in-band ahead of every keyframe.
            for i in 0..<2 {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    nals.append(Data(bytes: ptr, count: size))
                }
            }
        }

        var length = 0
        var base: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &base) == noErr,
              let base else { return }
        let bytes = UnsafeRawPointer(base)
        var offset = 0
        while offset + 4 <= length {   // AVCC: 4-byte big-endian lengths
            let n = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian)
            offset += 4
            guard n > 0, offset + n <= length else { break }
            nals.append(Data(bytes: bytes + offset, count: n))
            offset += n
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let ts = UInt32(truncatingIfNeeded: Int64(CMTimeGetSeconds(pts) * 90_000))
        rtp.send(nals: nals, timestamp: ts)
    }

    private func fit(_ w: Int, _ h: Int) -> (Int, Int) {
        let scale = min(1.0, min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h)))
        return (Int(Double(w) * scale) & ~1, Int(Double(h) * scale) & ~1)
    }
}
