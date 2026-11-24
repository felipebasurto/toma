import Foundation
import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import Accelerate
import Synchronization

/// The things a user can get out of Toma.
nonisolated enum Format: String, CaseIterable, Sendable {
    /// H.264 in MP4: plays everywhere.
    case mp4
    /// HEVC in MOV: same look, about half the size; Apple devices and modern browsers.
    case hevc
    case gif

    var label: String {
        switch self {
        case .mp4: "MP4"
        case .hevc: "HEVC"
        case .gif: "GIF"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .hevc: "mov"
        case .gif: "gif"
        }
    }

    var type: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .hevc: .quickTimeMovie
        case .gif: .gif
        }
    }

    @MainActor var help: String {
        switch self {
        case .mp4: tr("H.264 video · works everywhere")
        case .hevc: tr("HEVC video · half the size, ideal on Apple")
        case .gif: tr("Animated GIF · %@", Preferences.gifSize.title.lowercased())
        }
    }
}

/// Where finished recordings go, what they are called, and how a Clip becomes a file.
/// The one module that knows the destination folder, the naming scheme, the remembered
/// format, and every encoding policy. Callers say "save this clip as GIF"; nothing else.
///
/// Recording already wrote the MP4 and (on Macs with hardware HEVC) the HEVC at delivery quality,
/// so saving those is a move. The only extra work is mixing Mac sound and microphone into one
/// audio track (the video is copied as is), HEVC on Macs without the hardware encoder, and GIF,
/// which `GIF` builds from the clip's near-lossless source. Library consumes the clip exactly
/// once, in `save`, `copy` or `discard`.
enum Library {
    /// The format the result card pre-selects. Written only by `save` (the last format the user
    /// actually saved), so there is no setting to manage: using GIF once makes GIF the default.
    static var preferredFormat: Format {
        Format(rawValue: UserDefaults.standard.string(forKey: "formato") ?? "") ?? .mp4
    }

    /// The folder the user chose, else `com.apple.screencapture location` (⇧⌘5 › Options),
    /// else the Desktop.
    static var destination: URL {
        let fm = FileManager.default
        func isFolder(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
        if let chosen = Preferences.folder, isFolder(chosen) { return chosen }
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            if isFolder(url) { return url }
        }
        return fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// The name a recording made now gets, without extension:
    /// "Screen Recording 2026-10-15 at 21.03.12" (Spanish: "Grabación de pantalla 2026-10-15 a las 21.03.12"),
    /// mirroring Apple's screenshots.
    static func fileName(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = tr("yyyy-MM-dd 'at' HH.mm.ss")
        return tr("Screen Recording %@", f.string(from: date))
    }

    /// Starts whatever work `format` still needs in the background while the user is still
    /// looking at the card, so the likely choice saves (nearly) instantly. Usually that is nothing:
    /// MP4 and HEVC were written during the recording. Calling it again is a no-op.
    static func prepare(_ clip: Clip, as format: Format) {
        guard prepared[clip.master] == nil, needsWork(clip, format) else { return }
        let relay = ProgressRelay()
        let policy = Preferences.gifSize.policy
        prepared[clip.master] = Prepared(format: format, relay: relay, task: Task.detached(priority: .userInitiated) {
            try await produce(clip, as: format, policy: policy, progress: relay.report)
        })
    }

    /// Turns the clip into a user-visible file and consumes the master.
    /// `to` is an exact destination (a drag-out file promise); nil means `destination` with a
    /// fresh name. Never overwrites; a partial file never appears.
    @discardableResult
    static func save(_ clip: Clip, as format: Format, to exact: URL? = nil,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws(TomaError) -> URL {
        let url = exact ?? uniqueURL(in: destination, base: fileName(), ext: format.fileExtension)
        do {
            let encoded = try await encode(clip, as: format, progress: progress)
            try FileManager.default.moveItem(at: encoded, to: url)
        } catch {
            throw .exportFailed(underlying: "\(error)")
        }
        discard(clip)
        UserDefaults.standard.set(format.rawValue, forKey: "formato")
        return url
    }

    /// Puts the clip on the clipboard as a file, ready to paste into Slack, Mail or Finder.
    /// The file lives in Toma's cache (cleared after a day), so copying doesn't clutter the folder.
    static func copy(_ clip: Clip, as format: Format,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws(TomaError) {
        let folder = clipboardFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try await save(clip, as: format, to: uniqueURL(in: folder, base: fileName(), ext: format.fileExtension),
                                 progress: progress)
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([url as NSURL])
    }

    /// Drops the clip: its files, and any background work started by `prepare`. Idempotent.
    static func discard(_ clip: Clip) {
        discardPrepared(clip)
        for url in clip.files { try? FileManager.default.removeItem(at: url) }
    }

    /// Launch housekeeping: masters and scratch files from a crashed run, day-old clipboard files.
    static func removeLeftovers() {
        let fm = FileManager.default
        try? fm.removeItem(at: scratch)
        let old = Date.now.addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: clipboardFolder, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            if let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, created < old {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Where Recording writes masters and Library writes intermediate files.
    nonisolated static var scratch: URL {
        FileManager.default.temporaryDirectory.appending(path: "Toma", directoryHint: .isDirectory)
    }

    // MARK: private

    private struct Prepared {
        let format: Format
        let relay: ProgressRelay
        let task: Task<URL, any Error>
    }

    private static var prepared: [URL: Prepared] = [:]

    private static var clipboardFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.toma/Portapapeles", directoryHint: .isDirectory)
    }

    /// A finished file in scratch as `format`, reusing prepared work when it matches. For a live
    /// MP4 or HEVC with at most one audio track, that is the clip's own file.
    private static func encode(_ clip: Clip, as format: Format,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let job = prepared[clip.master] {
            if job.format == format {
                prepared[clip.master] = nil
                job.relay.forward(to: progress)
                if let url = try? await job.task.value { return url }
            } else {
                discardPrepared(clip)
            }
        }
        return try await produce(clip, as: format, policy: Preferences.gifSize.policy, progress: progress)
    }

    /// Whether `format` takes more than moving a file that Recording already wrote.
    private static func needsWork(_ clip: Clip, _ format: Format) -> Bool {
        switch format {
        case .mp4: clip.audioTracks > 1
        case .hevc: clip.hevc == nil || clip.audioTracks > 1
        case .gif: true
        }
    }

    private nonisolated static func produce(_ clip: Clip, as format: Format, policy: GIFPolicy,
                                            progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let live: URL? = switch format {
        case .mp4: clip.master
        case .hevc: clip.hevc
        case .gif: nil
        }
        if let live, clip.audioTracks <= 1 { progress(1); return live }

        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        if let live {
            // Mac sound and microphone are separate tracks; many players only play the first.
            try await Transcoder.run(live, to: target, format: format, copyVideo: true, progress: progress)
        } else if format == .gif {
            try await GIFEncoder.encode(clip, policy: policy, to: target, progress: progress)
        } else {
            try await Transcoder.run(clip.source, to: target, format: format, copyVideo: false, progress: progress)
        }
        return target
    }

    private static func discardPrepared(_ clip: Clip) {
        guard let job = prepared.removeValue(forKey: clip.master) else { return }
        job.task.cancel()
        let owned = Set(clip.files)
        Task {
            if let url = try? await job.task.value, !owned.contains(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

/// The few numbers that decide whether a GIF looks good *and* stays shareable.
nonisolated struct GIFPolicy: Sendable {
    /// GIF delays are in 1/100 s; the encoder rounds cumulatively, so any rate keeps exact timing.
    var framesPerSecond: Int
    /// Longest edge in pixels; larger captures are downscaled (Lanczos) to fit.
    var maxLongEdge: Int
}

/// Rewrites a recording file. All audio tracks (Mac sound, microphone) are mixed into one AAC
/// track, because many players only play the first. With `copyVideo` the video is copied as is
/// (a live MP4/HEVC that only needs its audio mixed: about disk speed). Without it, the video is
/// re-encoded as `format` with the same quality-targeted hardware settings Recording uses live
/// (only for HEVC on Macs without the hardware encoder, from the near-lossless source).
private nonisolated enum Transcoder {
    static func run(_ source: URL, to url: URL, format: Format, copyVideo: Bool,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw TomaError.exportFailed(underlying: "no video track")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let size = try await video.load(.naturalSize)
        let description = try await video.load(.formatDescriptions).first
        let colors = description.map(colorProperties) ?? [:]

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: copyVideo ? nil : [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audio.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(out)
            audioOut = out
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: format == .hevc ? .mov : .mp4)
        var compression: [String: Any] = [
            AVVideoQualityKey: format == .hevc ? 0.6 : 0.65,
            AVVideoExpectedSourceFrameRateKey: 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if format == .mp4 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: format == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if !colors.isEmpty { videoSettings[AVVideoColorPropertiesKey] = colors }
        let videoIn = copyVideo
            ? AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: description)
            : AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading(), writer.startWriting() else {
            throw writer.error ?? reader.error ?? TomaError.exportFailed(underlying: "transcode start")
        }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader)
        let videoPair = UncheckedBox((videoOut as AVAssetReaderOutput, videoIn))
        let audioPair = audioOut.flatMap { out in audioIn.map { UncheckedBox((out as AVAssetReaderOutput, $0)) } }
        await withTaskCancellationHandler {
            async let v: Void = pump.drain(videoPair, label: "toma.video") { time in
                if duration > 0 { progress(min(1, time / duration)) }
            }
            async let a: Void = {
                if let audioPair { await pump.drain(audioPair, label: "toma.audio") { _ in } }
            }()
            _ = await (v, a)
        } onCancel: {
            pump.cancel()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? reader.error ?? TomaError.exportFailed(underlying: "transcode")
        }
        progress(1)
    }

    /// The master's colour tags, carried over so the re-encode looks identical.
    private static func colorProperties(_ description: CMFormatDescription) -> [String: String] {
        let pairs: [(CFString, String)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
            (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
            (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey),
        ]
        var out: [String: String] = [:]
        for (key, name) in pairs {
            if let value = CMFormatDescriptionGetExtension(description, extensionKey: key) as? String { out[name] = value }
        }
        return out.count == 3 ? out : [:]   // AVFoundation wants all three or none
    }

    /// Moves samples from reader outputs to writer inputs as fast as the inputs accept them.
    private final class Pump: @unchecked Sendable {
        private let reader: AVAssetReader
        init(reader: AVAssetReader) { self.reader = reader }

        func cancel() { reader.cancelReading() }

        func drain(_ box: UncheckedBox<(AVAssetReaderOutput, AVAssetWriterInput)>, label: String,
                   time: @escaping @Sendable (Double) -> Void) async {
            let input = box.value.1
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                // Only touched on this input's serial queue.
                let state = UncheckedBox(Finished())
                input.requestMediaDataWhenReady(on: DispatchQueue(label: label)) {
                    let (output, input) = box.value
                    while !state.value.done, input.isReadyForMoreMediaData {
                        let sample = output.copyNextSampleBuffer()
                        if let sample { time(sample.presentationTimeStamp.seconds) }
                        guard let sample, input.append(sample) else {
                            state.value.done = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                    }
                }
            }
        }
    }
}

private nonisolated final class Finished { var done = false }

/// Progress of background work that a save may adopt halfway: reports go nowhere until a save
/// takes the job over, then to that save's ring, starting with the latest value.
private nonisolated final class ProgressRelay: Sendable {
    private let state = Mutex<(latest: Double, target: (@Sendable (Double) -> Void)?)>((0, nil))

    func report(_ value: Double) {
        let target = state.withLock { s in s.latest = value; return s.target }
        target?(value)
    }

    func forward(to target: @escaping @Sendable (Double) -> Void) {
        let latest = state.withLock { s in s.target = target; return s.latest }
        target(latest)
    }
}

private nonisolated struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Reads the clip's near-lossless source sequentially and streams a looping GIF through `GIF`.
///
/// The source has a variable frame rate (frames only when the screen changed). The encoder
/// samples it on a fixed 1/fps clock (latest frame at or before each tick); runs of identical
/// samples become one frame with a longer delay, so static screen time costs nothing. Delays are
/// rounded cumulatively, so any fps keeps exact total timing despite 1/100 s units.
///
/// Two stages overlap: the sequential one (decode, pixels, `GIF.Differ`) and the per-frame
/// encodes, which run in parallel in a sliding window and are written in order as they finish.
private nonisolated enum GIFEncoder {
    static func encode(_ clip: Clip, policy: GIFPolicy, to url: URL,
                       progress: @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: clip.source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TomaError.exportFailed(underlying: "no video track")
        }
        let natural = try await track.load(.naturalSize)
        let fit = min(1, CGFloat(policy.maxLongEdge) / max(natural.width, natural.height))
        let width = Int((natural.width * fit).rounded()), height = Int((natural.height * fit).rounded())

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TomaError.exportFailed(underlying: "reader") }
        defer { reader.cancelReading() }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let ci = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB, .cacheIntermediates: false])
        /// RGBA pixels at GIF size. At native size a vImage channel swap of the decoded BGRA
        /// frame; smaller, a Lanczos downscale.
        func render(_ buffer: CVPixelBuffer) -> GIF.Frame {
            var pixels = [UInt32](repeating: 0, count: width * height)
            if fit == 1, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
               CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height {
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                pixels.withUnsafeMutableBytes { out in
                    var src = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
                    var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImagePermuteChannels_ARGB8888(&src, &dst, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
                }
            } else {
                var image = CIImage(cvPixelBuffer: buffer)
                if fit < 1 {
                    image = image.clampedToExtent()
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: fit, kCIInputAspectRatioKey: 1])
                }
                pixels.withUnsafeMutableBytes {
                    ci.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                              bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB)
                }
            }
            return GIF.Frame(pixels: pixels, width: width, height: height)
        }

        let fps = Double(policy.framesPerSecond)
        let ticks = max(1, Int((clip.duration * fps).rounded(.up)))
        func centiseconds(_ from: Int, _ to: Int) -> Int {
            Int((Double(to) * 100 / fps).rounded()) - Int((Double(from) * 100 / fps).rounded())
        }

        let writer = try GIF.Writer(url: url, width: width, height: height)
        // Encodes in flight, oldest first; written in order. The window bounds memory.
        var inFlight: [Task<Data, Never>] = []
        let window = max(4, 2 * ProcessInfo.processInfo.activeProcessorCount)
        defer { for task in inFlight { task.cancel() } }
        func submit(_ delta: GIF.Delta, centiseconds cs: Int) async throws {
            inFlight.append(Task.detached(priority: .userInitiated) { GIF.encode(delta, centiseconds: cs) })
            while inFlight.count >= window { try writer.append(await inFlight.removeFirst().value) }
        }

        var differ = GIF.Differ()
        var pending: (delta: GIF.Delta, start: Int)?
        var current: CVPixelBuffer?, drawn: CVPixelBuffer?
        var next = output.copyNextSampleBuffer()

        for tick in 0..<ticks {
            try Task.checkCancellation()
            let t = Double(tick) / fps
            while let sample = next, sample.presentationTimeStamp.seconds <= t + 0.0001 {
                if let buffer = sample.imageBuffer { current = buffer }
                next = output.copyNextSampleBuffer()
            }
            if current == nil, let sample = next, let buffer = sample.imageBuffer { current = buffer }
            guard let buffer = current, buffer !== drawn else { continue }
            drawn = buffer

            guard let delta = differ.delta(render(buffer)) else { continue }   // nothing visible changed
            if let p = pending { try await submit(p.delta, centiseconds: centiseconds(p.start, tick)) }
            pending = (delta, tick)
            if tick % 10 == 0 { progress(Double(tick) / Double(ticks)) }
        }
        if let p = pending { try await submit(p.delta, centiseconds: max(2, centiseconds(p.start, ticks))) }
        while !inFlight.isEmpty { try writer.append(await inFlight.removeFirst().value) }
        try writer.finish()
        progress(1)
    }
}
