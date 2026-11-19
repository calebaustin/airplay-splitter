import AVFoundation
import CoreImage
import MediaToolbox

/// Plays a video file for the TVs. The Mac plays it as usual (so its sound
/// reaches the room's speakers); frames are pulled from the player and fitted
/// into 1080p, and the soundtrack is tapped for the TVs when Sound is on.
@MainActor
final class VideoSource: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var loop = UserDefaults.standard.object(forKey: "videoLoop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(loop, forKey: "videoLoop") }
    }

    let player = AVPlayer()
    private var endObserver: NSObjectProtocol?
    /// Frame state, read on the capture thread and set on the main thread.
    private nonisolated let lock = NSLock()
    nonisolated(unsafe) private var output: AVPlayerItemVideoOutput?
    nonisolated(unsafe) private var pool: CVPixelBufferPool?
    nonisolated(unsafe) private var last: CVPixelBuffer?
    private nonisolated let ci = CIContext(options: [.useSoftwareRenderer: false])
    /// Receives the soundtrack as float PCM (set by the model).
    nonisolated(unsafe) var onAudio: (([UnsafePointer<Float>], Int, Double) -> Void)?

    var currentTime: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }

    func load(_ url: URL) async throws {
        stop()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        item.add(out)
        lock.withLock { output = out; last = nil }
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            item.audioMix = makeTapMix(for: track)
        }
        duration = (try? await asset.load(.duration).seconds) ?? 0
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loop { self.player.seek(to: .zero); self.player.play() } else { self.isPlaying = false }
            }
        }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func restart() { player.seek(to: .zero); play() }

    func stop() {
        player.pause()
        isPlaying = false
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
        lock.withLock { output = nil; last = nil }
    }

    /// The newest video frame, fitted into 1920×1080 (called ~30 times a second).
    /// Safe to call from the capture thread.
    nonisolated func frame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return makeFrame()
    }

    private nonisolated func makeFrame() -> CVPixelBuffer? {
        guard let output else { return last }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let src = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return last }
        if pool == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        }
        var dst: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else { return last }
        let img = CIImage(cvPixelBuffer: src)
        let scale = min(1920 / img.extent.width, 1080 / img.extent.height)
        let fitted = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = fitted.transformed(by: CGAffineTransform(
            translationX: (1920 - fitted.extent.width) / 2, y: (1080 - fitted.extent.height) / 2))
        let canvas = placed.composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        ci.render(canvas, to: dst)
        last = dst
        return dst
    }

    // MARK: soundtrack tap

    private func makeTapMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(TapContext.shared).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: nil,
            prepare: { tap, _, format in
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                ctx.sampleRate = format.pointee.mSampleRate
                ctx.interleaved = format.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                ctx.channels = Int(format.pointee.mChannelsPerFrame)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr
                else { return }
                let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let list = UnsafeMutableAudioBufferListPointer(bufferList)
                let n = Int(framesOut.pointee)
                guard !ctx.interleaved, n > 0 else { return }   // AVFoundation taps are non-interleaved float
                let chans = list.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }.map { UnsafePointer($0) }
                ctx.onAudio?(chans, n, ctx.sampleRate)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        TapContext.shared.onAudio = { [weak self] c, n, r in self?.onAudio?(c, n, r) }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

/// State shared with the real-time audio tap callbacks (C function pointers
/// can't capture Swift values, so they reach it through the tap's storage).
final class TapContext: @unchecked Sendable {
    static let shared = TapContext()
    var sampleRate: Double = 44_100
    var interleaved = false
    var channels = 2
    var onAudio: (([UnsafePointer<Float>], Int, Double) -> Void)?
}
