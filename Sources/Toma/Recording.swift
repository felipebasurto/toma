import AppKit
@preconcurrency import ScreenCaptureKit
import AVFoundation
import Synchronization

/// Everything Toma knows about ScreenCaptureKit and TCC lives here and nowhere else.
/// Public surface: `ensureAccess()`, `start(_:)`, `stop()`, `clip`. Callers never see
/// SCStream, SCContentFilter, configurations, delegates, or the temp file's location policy.
///
/// Records straight to an MP4 "master" with SCRecordingOutput (H.264, native pixels, up to
/// 60 fps, sRGB, cursor visible, sound per Preferences.audio). The master is the single source every export
/// derives from; nothing else is captured or buffered.
final class Recording {
    /// Pre-flight before the overlay ever appears, so the user never drags a region only to
    /// be told it can't be recorded. Returns true only when capture will actually work right now.
    static func ensureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // The first ask shows the system prompt and registers Toma in Ajustes; that prompt is
        // enough. Later asks get our alert, because macOS applies the grant only after a relaunch.
        let asked = "permisoSolicitado"
        guard UserDefaults.standard.bool(forKey: asked) else {
            UserDefaults.standard.set(true, forKey: asked)
            CGRequestScreenCaptureAccess()
            return false
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Toma necesita permiso para grabar la pantalla."
        alert.informativeText = "Actívalo en Ajustes › Privacidad y seguridad › Grabación de pantalla y vuelve a abrir Toma."
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Salir")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        NSApp.terminate(nil)
        return false
    }

    /// Starts capturing `region`. Returns once the file is being written, so the
    /// menu-bar timer starts at the real start of the file.
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
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw .displayUnavailable
        }
        let me = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

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
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6

        let master = Library.scratch.appending(path: "\(UUID().uuidString).mp4")
        try? FileManager.default.createDirectory(at: Library.scratch, withIntermediateDirectories: true)

        let sink = RecordingSink()
        let output = SCRecordingOutputConfiguration()
        output.outputURL = master
        output.videoCodecType = .h264
        output.outputFileType = .mp4

        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        let recordingOutput = SCRecordingOutput(configuration: output, delegate: sink)
        do {
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
        } catch {
            throw .streamFailed(underlying: error.localizedDescription)
        }
        if case .failed(let reason) = await sink.started.value {
            try? await stream.stopCapture()
            throw .streamFailed(underlying: reason)
        }
        return Recording(stream: stream, sink: sink, master: master, region: region)
    }

    /// Requests the end of the recording. Idempotent and non-blocking: the first call stops the
    /// stream, later calls do nothing. The result arrives through `clip`.
    func stop() {
        guard !stopRequested else { return }
        stopRequested = true
        let stream = self.stream, sink = self.sink
        Task {
            do { try await stream.stopCapture() } catch { sink.streamEnded() }
        }
    }

    /// The finished master, available once the file is finalized — after `stop()`, or after the
    /// system ended the stream (display unplugged, user hit the system "stop sharing" control).
    /// Throws only if nothing playable was written. Awaiting it twice returns the same Clip.
    var clip: Clip {
        get async throws(TomaError) {
            if let finished { return try finished.get() }
            let outcome = await sink.finished.value
            let result: Result<Clip, TomaError>
            if case .failed(let reason) = outcome, !FileManager.default.fileExists(atPath: master.path) {
                result = .failure(.streamFailed(underlying: reason))
            } else if let duration = try? await AVURLAsset(url: master).load(.duration), duration.seconds > 0 {
                result = .success(Clip(master: master, duration: duration.seconds, region: region))
            } else {
                result = .failure(.streamFailed(underlying: "empty file"))
            }
            finished = result
            return try result.get()
        }
    }

    private let stream: SCStream
    private let sink: RecordingSink
    private let master: URL
    private let region: ScreenRegion
    private var stopRequested = false
    private var finished: Result<Clip, TomaError>?

    private init(stream: SCStream, sink: RecordingSink, master: URL, region: ScreenRegion) {
        self.stream = stream
        self.sink = sink
        self.master = master
        self.region = region
    }
}

/// A finished recording, not yet saved anywhere the user can see.
/// Invariant: `master` is a finalized, playable MP4 in Toma's temp folder; Library consumes it
/// exactly once (save, copy or discard).
nonisolated struct Clip: Sendable {
    let master: URL
    /// Seconds.
    let duration: Double
    let region: ScreenRegion
}

nonisolated enum Outcome: Sendable {
    case ok
    case failed(String)
}

/// Private bridge from ScreenCaptureKit's delegate callbacks (arbitrary queues) to async.
private nonisolated final class RecordingSink: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, Sendable {
    let started = OneShot<Outcome>()
    let finished = OneShot<Outcome>()

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        started.resolve(.ok)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        started.resolve(.failed(error.localizedDescription))
        finished.resolve(.failed(error.localizedDescription))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished.resolve(.ok)
    }

    /// The system ended the stream (display gone, "stop sharing", permission revoked).
    /// SCRecordingOutput finalizes on its own; give it a moment, then settle with what exists.
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        started.resolve(.failed(error.localizedDescription))
        streamEnded()
    }

    func streamEnded() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [finished] in
            finished.resolve(.ok)
        }
    }
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
