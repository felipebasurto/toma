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
        (config.width, config.height) = region.pixelSize
        config.scalesToFit = false
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
        config.queueDepth = 8

        try? FileManager.default.createDirectory(at: Library.scratch, withIntermediateDirectories: true)
        let engine: Engine
        do {
            engine = try Engine(region: region, audio: audio)
        } catch {
            throw .streamFailed(underlying: "\(error)")
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: engine)
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
    /// HEVC MOV at delivery quality, when this Mac encodes HEVC in hardware.
    let hevc: URL?
    /// Near-lossless H.264 (quality 0.9): the source for GIFs and any re-encode. Clean input
    /// matters for GIFs: compression noise reads as change and makes them larger.
    let source: URL
    /// Seconds.
    let duration: Double
    let region: ScreenRegion
    /// Audio tracks in each video file (Mac sound, microphone); players often play only the first.
    let audioTracks: Int

    var files: [URL] { [master, source] + (hevc.map { [$0] } ?? []) }
}

nonisolated enum Outcome: Sendable {
    case ok
    case failed(String)
}

/// Receives ScreenCaptureKit's samples on one serial queue and appends them to the live writers.
/// Frames that don't carry new pixels (SCK's idle and blank status frames) are skipped, so the
/// files have a variable frame rate: a still screen costs nothing.
private nonisolated final class Engine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "toma.capture", qos: .userInteractive)
    let started = OneShot<Outcome>()
    let finished = OneShot<Result<Clip, TomaError>>()

    private let region: ScreenRegion
    private let master: LiveFile, hevc: LiveFile?, source: LiveFile
    private var files: [LiveFile] { [master, source] + (hevc.map { [$0] } ?? []) }
    private let audioTracks: Int
    // Touched only on `queue`.
    private var sessionStart: CMTime?
    private var lastFrame: CMTime = .invalid
    private var finishing = false

    init(region: ScreenRegion, audio: Preferences.Audio) throws {
        self.region = region
        let (width, height) = region.pixelSize
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
        hevc = Recording.hasHardwareHEVC ? try file("hevc", .hevc, quality: 0.6) : nil
        source = try file("source", .h264, quality: 0.9)
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
            for file in files { file.appendVideo(sample) }
        case .audio, .microphone:
            guard let start = sessionStart, sample.presentationTimeStamp >= start else { return }
            for file in files { file.appendAudio(sample, from: type) }
        @unknown default:
            break
        }
    }

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
                finished.resolve(.success(Clip(master: master.url, hevc: hevc?.url, source: source.url,
                                               duration: (stop - start).seconds, region: region,
                                               audioTracks: audioTracks)))
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
        writer = try AVAssetWriter(outputURL: url, fileType: codec == .hevc ? .mov : .mp4)
        var compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
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
    func appendVideo(_ sample: CMSampleBuffer) {
        guard writer.status == .writing, video.isReadyForMoreMediaData else { return }
        video.append(sample)
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
