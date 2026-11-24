import AppKit
@preconcurrency import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import Synchronization

/// Everything Toma knows about ScreenCaptureKit and TCC lives here and nowhere else.
/// Public surface: `ensureAccess()`, `snapshot(_:)`, `start(_:)`, `stop()`, `clip`. Callers never
/// see SCStream, SCContentFilter, configurations, writers, or the temp files' location policy.
///
/// Encodes while it records: every captured frame (native pixels, up to 60 fps, sRGB, cursor
/// visible, sound per Preferences.audio) goes straight into hardware encoders that write the
/// deliverables themselves, so saving an MP4 or HEVC is a move, not a re-encode. One generation
/// of compression instead of two, and colours tagged as the sRGB they are. See `Clip`.
final class Recording {
    /// Pre-flight before the overlay ever appears, so the user never drags a region only to
    /// be told it can't be recorded. Returns true only when capture will actually work right now.
    static func ensureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first ask shows the system prompt and registers Toma in Settings; that prompt is
        // enough. Later asks get our alert, because macOS applies the grant only after a relaunch.
        let asked = "permisoSolicitado"
        guard UserDefaults.standard.bool(forKey: asked) else {
            UserDefaults.standard.set(true, forKey: asked)
            CGRequestScreenCaptureAccess()
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = tr("Toma needs permission to record the screen.")
        alert.informativeText = tr("Turn it on in Settings › Privacy & Security › Screen Recording, then reopen Toma.")
        alert.addButton(withTitle: tr("Open Settings"))
        alert.addButton(withTitle: tr("Quit"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        NSApp.terminate(nil)
        return false
    }

    /// A still of `region` exactly as the recording would see it now: same filter (Toma excluded),
    /// same crop, same pixel size. For the confirmation step; nil if it can't be taken.
    static func snapshot(_ region: ScreenRegion) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let filter = filter(for: region, in: content) else { return nil }
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        (config.width, config.height) = region.pixelSize
        config.scalesToFit = false
        config.captureResolution = .best
        config.showsCursor = false
        config.colorSpaceName = CGColorSpace.sRGB
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The region's display with Toma's own windows left out.
    private static func filter(for region: ScreenRegion, in content: SCShareableContent) -> SCContentFilter? {
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { return nil }
        let me = content.applications.filter { $0.processID == getpid() }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
    }


    /// Starts capturing `region`. Returns once the first frame is in the files, so the menu-bar
    /// timer starts at the real start of the recording.
    ///
    /// Toma's own app is excluded from the filter — this, not window sharingType, is what keeps
    /// the veil, frame and card out of the video.
    static func start(_ region: ScreenRegion) async throws(TomaError) -> Recording {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw .permissionDenied
        }
        guard let filter = filter(for: region, in: content) else { throw .displayUnavailable }

        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        let size = captureSize(region)
        (config.width, config.height) = (size.width, size.height)
        let scaled = size != region.pixelSize
        config.scalesToFit = scaled
        config.preservesAspectRatio = !scaled       // fills the frame exactly; the rounding is < 1 px
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        let audio = Preferences.audio
        config.capturesAudio = audio != .none
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = audio == .systemAndMicrophone
        config.sampleRate = 48_000
        config.channelCount = 2
        // sRGB BGRA in, sRGB-tagged video out: the encoder only changes RGB to YCbCr, never the
        // tone curve, so every player and every GIF shows the pixels that were on screen.
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = queueDepth

        try? FileManager.default.createDirectory(at: Library.scratch, withIntermediateDirectories: true)
        let engine: Engine
        do {
            engine = try Engine(region: region, audio: audio)
        } catch {
            throw .streamFailed(underlying: "\(error)")
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: engine)
        engine.configuration = config
        do {
            try stream.addStreamOutput(engine, type: .screen, sampleHandlerQueue: engine.queue)
            if audio != .none { try stream.addStreamOutput(engine, type: .audio, sampleHandlerQueue: engine.queue) }
            if audio == .systemAndMicrophone { try stream.addStreamOutput(engine, type: .microphone, sampleHandlerQueue: engine.queue) }
            try await stream.startCapture()
        } catch {
            engine.abandon()
            throw .streamFailed(underlying: error.localizedDescription)
        }
        // ScreenCaptureKit sends the first frame right away, even for a still screen.
        let first = Task { await engine.started.value }
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); engine.started.resolve(.ok) }
        let outcome = await first.value
        timeout.cancel()
        if case .failed(let reason) = outcome {
            try? await stream.stopCapture()
            engine.abandon()
            throw .streamFailed(underlying: reason)
        }
        return Recording(stream: stream, engine: engine)
    }

    /// Requests the end of the recording. Idempotent and non-blocking: the first call stops the
    /// stream, later calls do nothing. The result arrives through `clip`.
    ///
    /// The files are closed by Toma's own writers once the stream has stopped, so there is no
    /// system callback to wait for (SCRecordingOutput's finish callback was unreliable: skipped
    /// on Sequoia 15.3, and removing it early broke the file on macOS 26.6). The video ends at the
    /// moment of the stop, so a still screen at the end keeps its length.
    func stop() {
        guard !stopRequested else { return }
        stopRequested = true
        let stream = self.stream, engine = self.engine
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        Task {
            try? await stream.stopCapture()
            engine.finish(at: end)
        }
        Task {
            try? await Task.sleep(for: .seconds(3))
            engine.finish(at: end)          // no-op when the stream already stopped
        }
    }

    /// The finished files, available once they are closed — after `stop()`, or after the system
    /// ended the stream (display unplugged, user hit the system "stop sharing" control).
    /// Throws only if not a single frame was recorded. Awaiting it twice returns the same Clip.
    var clip: Clip {
        get async throws(TomaError) {
            try await engine.finished.value.get()
        }
    }

    /// Capture buffers ScreenCaptureKit cycles through (its maximum): room for the encoders to
    /// fall a few frames behind before any frame is lost.
    nonisolated static let queueDepth = 8

    /// The size the files are recorded at: native pixels, scaled down to fit 4096 × 4096 when
    /// larger. That is the most the H.264 hardware encoder takes on Apple silicon; past it,
    /// VideoToolbox silently falls back to a software encoder that can't keep up at 60 fps and
    /// rejects quality-targeted settings. Even in both axes.
    nonisolated static func captureSize(_ region: ScreenRegion) -> (width: Int, height: Int) {
        let (width, height) = region.pixelSize
        let fit = min(1, 4096 / Double(max(width, height)))
        guard fit < 1 else { return (width, height) }
        func even(_ v: Int) -> Int { max(2, Int(Double(v) * fit / 2) * 2) }
        return (even(width), even(height))
    }

    /// Pixels per frame up to which the HEVC and the GIF source are encoded live beside the MP4.
    /// All encodes share the Mac's media engine: three at 60 fps cost 180 × pixels per second, and
    /// an M4 sustains about 500 Mpx/s on screen content that changes every frame (earlier chips
    /// less). 1.6 Mpx (about 1700 × 950 px) leaves room for the slowest Apple silicon Mac. Larger
    /// recordings encode only the MP4 live and derive HEVC and GIF from it on save, and the engine
    /// sheds the extras anyway as soon as the encoders fall behind (see `Engine.relieve`).
    nonisolated static let extrasPixelLimit = 1_600_000

    /// True when this Mac encodes HEVC in hardware (every Apple silicon Mac, most recent Intel
    /// ones). Without it, live HEVC would cost real CPU during the recording, so it is derived on save.
    nonisolated static let hasHardwareHEVC: Bool = {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains {
            ($0[kVTVideoEncoderList_CodecType as String] as? UInt32) == kCMVideoCodecType_HEVC
                && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
        }
    }()

    /// How the engine adapted to this Mac: whether the HEVC and GIF source were encoded live,
    /// whether capture dropped to 30 fps, and how many frames the MP4 lost. For logs and tests.
    var adaptation: (extras: Bool, halvedFrameRate: Bool, droppedFrames: Int) {
        (!engine.shedExtras, engine.halvedFrameRate, engine.droppedFrames)
    }

    private let stream: SCStream
    private let engine: Engine
    private var stopRequested = false

    private init(stream: SCStream, engine: Engine) {
        self.stream = stream
        self.engine = engine
    }
}

/// A finished recording, not yet saved anywhere the user can see. Every file was encoded live
/// from the captured frames (one generation, no re-encode), tagged sRGB.
/// Invariant: all files are finalized and playable, in Toma's temp folder; Library consumes them
/// exactly once (save, copy or discard).
nonisolated struct Clip: Sendable {
    /// H.264 MP4 at delivery quality: what the card plays and what "MP4" saves.
    let master: URL
    /// HEVC MOV at delivery quality, when it was encoded live (hardware HEVC, a moderate size,
    /// and encoders that kept up); otherwise HEVC is derived from `source` on save.
    let hevc: URL?
    /// Near-lossless H.264 (quality 0.9): the source for GIFs and any re-encode. Clean input
    /// matters for GIFs: compression noise reads as change and makes them larger. The same file
    /// as `master` when there was no room to encode it live.
    let source: URL
    /// Seconds.
    let duration: Double
    let region: ScreenRegion
    /// Audio tracks in each video file (Mac sound, microphone); players often play only the first.
    let audioTracks: Int
    /// Pixel size of the video files (the region's, or less above 4096 px; see `captureSize`).
    let width: Int, height: Int

    var files: [URL] { [master] + (source == master ? [] : [source]) + (hevc.map { [$0] } ?? []) }
}

nonisolated enum Outcome: Sendable {
    case ok
    case failed(String)
}

/// Receives ScreenCaptureKit's samples on one serial queue and appends them to the live writers.
/// Frames that don't carry new pixels (SCK's idle and blank status frames) are skipped, so the
/// files have a variable frame rate: a still screen costs nothing.
///
/// Adapts to the Mac it runs on. The MP4 is the one file that must be smooth; the HEVC and the
/// GIF source are extras. When the encoders start refusing frames (an older chip, a large region
/// of fast-changing content, a video call sharing the media engine, heat), the extras are dropped
/// at once, and if the MP4 alone still can't keep up, capture goes to a steady 30 fps.
private nonisolated final class Engine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "toma.capture", qos: .userInteractive)
    let started = OneShot<Outcome>()
    let finished = OneShot<Result<Clip, TomaError>>()

    private let region: ScreenRegion
    private let width: Int, height: Int
    private let master: LiveFile
    private let audioTracks: Int
    /// Set once before capture starts; changed only to halve the frame rate under pressure.
    var configuration: SCStreamConfiguration?
    // Touched only on `queue`.
    private var hevc: LiveFile?, source: LiveFile?
    private var files: [LiveFile] { [master] + [source, hevc].compactMap { $0 } }
    private var sessionStart: CMTime?
    private var lastFrame: CMTime = .invalid
    private var finishing = false
    /// Recent frames that some encoder couldn't take, and when the last relief step may be judged.
    private var refusals: [CMTime] = []
    private var settledAt: CMTime = .zero
    private var halved = false
    private var dropped = 0
    /// The capture buffers seen so far: ScreenCaptureKit's pool, `queueDepth` of them at most.
    private var surfaces: [IOSurfaceID: IOSurfaceRef] = [:]

    init(region: ScreenRegion, audio: Preferences.Audio) throws {
        self.region = region
        let (width, height) = Recording.captureSize(region)
        (self.width, self.height) = (width, height)
        let id = UUID().uuidString
        let sources: [SCStreamOutputType] = switch audio {
        case .none: []
        case .system: [.audio]
        case .systemAndMicrophone: [.audio, .microphone]
        }
        audioTracks = sources.count
        func file(_ name: String, _ codec: AVVideoCodecType, quality: Double) throws -> LiveFile {
            let ext = codec == .hevc ? "mov" : "mp4"
            return try LiveFile(url: Library.scratch.appending(path: "\(id)-\(name).\(ext)"), codec: codec,
                                quality: quality, width: width, height: height, audio: sources)
        }
        master = try file("mp4", .h264, quality: 0.65)
        if width * height <= Recording.extrasPixelLimit {
            hevc = Recording.hasHardwareHEVC ? try? file("hevc", .hevc, quality: 0.6) : nil
            source = try? file("source", .h264, quality: 0.9)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, sample.isValid else { return }
        switch type {
        case .screen:
            guard Self.isNewFrame(sample) else { return }
            let time = sample.presentationTimeStamp
            if sessionStart == nil {
                sessionStart = time
                for file in files { file.startSession(at: time) }
                started.resolve(.ok)
            }
            guard time > lastFrame || !lastFrame.isValid else { return }
            lastFrame = time
            var strained = backlog(sample) >= Recording.queueDepth - 2
            for file in files where !file.appendVideo(sample) {
                strained = true
                if file === master { dropped += 1 }
            }
            if strained { relieve(at: time, stream: stream) }
        case .audio, .microphone:
            guard let start = sessionStart, sample.presentationTimeStamp >= start else { return }
            for file in files { file.appendAudio(sample, from: type) }
        @unknown default:
            break
        }
    }

    /// How many capture buffers are still held, this one included. Encoders keep a frame's buffer
    /// until it is encoded, and ScreenCaptureKit silently skips frames when all `queueDepth` are
    /// taken, so a backlog is the first sign of falling behind, before the encoders refuse
    /// anything. Measured: 1 with headroom (only 2 buffers ever rotate), 6–8 when saturated.
    private func backlog(_ sample: CMSampleBuffer) -> Int {
        guard let buffer = sample.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return 0 }
        if surfaces.count >= 2 * Recording.queueDepth { surfaces.removeAll() }    // the pool changed
        surfaces[IOSurfaceGetID(surface)] = surface
        return surfaces.values.count { IOSurfaceIsInUse($0) }
    }

    /// Called for every strained frame: a deep backlog or a refusal. Three within a second mean the
    /// media engine is saturated, not hiccuping: drop the extras (their files would stutter anyway, and
    /// HEVC and GIF are then derived from the MP4 on save). Still saturated a second later: 30 fps.
    private func relieve(at time: CMTime, stream: SCStream) {
        refusals.append(time)
        refusals.removeAll { (time - $0).seconds > 1 }
        guard refusals.count >= 3, time >= settledAt else { return }
        refusals.removeAll()
        settledAt = time + CMTime(value: 1, timescale: 1)
        if hevc != nil || source != nil {
            let dropped = UncheckedSendable([hevc, source].compactMap { $0 })
            hevc = nil
            source = nil
            DispatchQueue.global(qos: .utility).async { for file in dropped.value { file.cancel() } }
        } else if !halved, let configuration {
            halved = true
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            stream.updateConfiguration(configuration) { _ in }
        }
    }

    /// What the engine ended up doing, for diagnostics and tests.
    var shedExtras: Bool { queue.sync { hevc == nil && source == nil } }
    var halvedFrameRate: Bool { queue.sync { halved } }
    /// Frames the MP4 encoder refused.
    var droppedFrames: Int { queue.sync { dropped } }

    /// The system ended the stream (display gone, "stop sharing", permission revoked): keep what
    /// was recorded so far.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        started.resolve(.failed(error.localizedDescription))
        finish(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Closes every file at `end` (or just after the last frame, if `end` is earlier) and resolves
    /// `finished`. Idempotent.
    func finish(at end: CMTime) {
        queue.async { [self] in
            guard !finishing else { return }
            finishing = true
            surfaces.removeAll()
            guard let start = sessionStart, lastFrame.isValid else {
                abandon()
                finished.resolve(.failure(.streamFailed(underlying: "no frames")))
                return
            }
            let afterLast = lastFrame + CMTime(value: 1, timescale: 60)
            let stop = end.isValid && end > afterLast && (end - lastFrame).seconds < 3600 ? end : afterLast
            let group = DispatchGroup()
            for file in files { group.enter(); file.finish(at: stop) { group.leave() } }
            group.notify(queue: queue) { [self] in
                guard files.allSatisfy(\.succeeded) else {
                    abandon()
                    finished.resolve(.failure(.streamFailed(underlying: "writer failed")))
                    return
                }
                finished.resolve(.success(Clip(master: master.url, hevc: hevc?.url, source: source?.url ?? master.url,
                                               duration: (stop - start).seconds, region: region,
                                               audioTracks: audioTracks, width: width, height: height)))
            }
        }
    }

    /// Deletes every file; for starts that failed and recordings without a single frame.
    func abandon() {
        for file in files { file.cancel() }
    }

    private static func isNewFrame(_ sample: CMSampleBuffer) -> Bool {
        guard sample.imageBuffer != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }
}

/// One file being written live: a hardware video encode of the captured frames plus one AAC
/// track per audio source. Used only on Engine's queue.
private nonisolated final class LiveFile {
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private var audio: [SCStreamOutputType: AVAssetWriterInput] = [:]
    private(set) var succeeded = false

    init(url: URL, codec: AVVideoCodecType, quality: Double, width: Int, height: Int,
         audio sources: [SCStreamOutputType]) throws {
        self.url = url
        let writer = try AVAssetWriter(outputURL: url, fileType: codec == .hevc ? .mov : .mp4)
        self.writer = writer
        var compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        // Settings an encoder rejects raise an Objective-C exception that would kill the app.
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw TomaError.streamFailed(underlying: "\(codec.rawValue) \(width)×\(height) unsupported")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        for source in sources {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audio[source] = input
        }
        guard writer.startWriting() else {
            throw writer.error ?? TomaError.streamFailed(underlying: "writer")
        }
    }

    func startSession(at time: CMTime) { writer.startSession(atSourceTime: time) }

    /// Real time: a frame the encoder can't take right now is dropped rather than queued.
    /// Returns false only for that: the encoder refused it.
    func appendVideo(_ sample: CMSampleBuffer) -> Bool {
        guard writer.status == .writing else { return true }
        guard video.isReadyForMoreMediaData else { return false }
        video.append(sample)
        return true
    }

    func appendAudio(_ sample: CMSampleBuffer, from source: SCStreamOutputType) {
        guard writer.status == .writing, let input = audio[source], input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    func finish(at end: CMTime, done: @escaping @Sendable () -> Void) {
        guard writer.status == .writing else { done(); return }
        video.markAsFinished()
        for input in audio.values { input.markAsFinished() }
        writer.endSession(atSourceTime: end)
        let box = UncheckedSendable(self)
        writer.finishWriting {
            box.value.succeeded = box.value.writer.status == .completed
            done()
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

private nonisolated struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A value that is set once and awaited any number of times. Resolving twice is a no-op.
nonisolated final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }
    private let state = Mutex(State())

    func resolve(_ value: Value) {
        let waiters = state.withLock { s -> [CheckedContinuation<Value, Never>] in
            guard s.value == nil else { return [] }
            s.value = value
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    var value: Value {
        get async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { s -> Value? in
                    if let v = s.value { return v }
                    s.waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}
