import Foundation
import AppKit
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

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
        case .mp4: "Vídeo H.264 · funciona en todas partes"
        case .hevc: "Vídeo HEVC · la mitad de peso, ideal en Apple"
        case .gif: "GIF animado · \(Preferences.gifSize.title.lowercased())"
        }
    }
}

/// Where finished recordings go, what they are called, and how a Clip becomes a file.
/// The one module that knows the destination folder, the naming scheme, the remembered
/// format, and every encoding policy. Callers say "save this clip as GIF"; nothing else.
///
/// The master from Recording is a high-quality, high-bitrate MP4. Every deliverable is derived
/// from it: MP4 and HEVC are re-encoded with tuned quality (2–4× lighter, text stays crisp),
/// GIF goes through `GIF`. Library consumes the master exactly once, in `save`, `copy` or `discard`.
enum Library {
    /// The format the result card pre-selects. Written only by `save` (the last format the user
    /// actually saved), so there is no setting to manage: using GIF once makes GIF the default.
    static var preferredFormat: Format {
        Format(rawValue: UserDefaults.standard.string(forKey: "formato") ?? "") ?? .mp4
    }

    /// The folder the user chose, else `com.apple.screencapture location` (⇧⌘5 › Opciones),
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
    /// "Grabación de pantalla 2026-10-15 a las 21.03.12", mirroring Apple's screenshots.
    static func fileName(_ date: Date = .now) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "yyyy-MM-dd 'a las' HH.mm.ss"
        return "Grabación de pantalla \(f.string(from: date))"
    }

    /// Starts encoding the clip in `format` in the background while the user is still looking at
    /// the card, so the likely choice saves (nearly) instantly. Calling it again is a no-op.
    static func prepare(_ clip: Clip, as format: Format) {
        guard format != .gif, prepared[clip.master] == nil else { return }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        prepared[clip.master] = (format, Task.detached(priority: .userInitiated) {
            try await Transcoder.run(clip.master, to: target, format: format, progress: { _ in })
            return target
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

    /// Drops the clip: master, and any background encode started by `prepare`. Idempotent.
    static func discard(_ clip: Clip) {
        if let (_, task) = prepared.removeValue(forKey: clip.master) {
            task.cancel()
            Task { if let url = try? await task.value { try? FileManager.default.removeItem(at: url) } }
        }
        try? FileManager.default.removeItem(at: clip.master)
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

    private static var prepared: [URL: (Format, Task<URL, any Error>)] = [:]

    private static var clipboardFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.toma/Portapapeles", directoryHint: .isDirectory)
    }

    /// A finished file in scratch, encoded as `format`, reusing a prepared encode when it matches.
    private static func encode(_ clip: Clip, as format: Format,
                               progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        if let (preparedFormat, task) = prepared[clip.master] {
            if preparedFormat == format {
                prepared[clip.master] = nil
                if let url = try? await task.value { return url }
            } else {
                discardPrepared(clip)
            }
        }
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        switch format {
        case .gif:
            try await GIFEncoder.encode(clip, policy: Preferences.gifSize.policy, to: target, progress: progress)
        case .mp4, .hevc:
            try await Transcoder.run(clip.master, to: target, format: format, progress: progress)
        }
        return target
    }

    private static func discardPrepared(_ clip: Clip) {
        guard let (_, task) = prepared.removeValue(forKey: clip.master) else { return }
        task.cancel()
        Task { if let url = try? await task.value { try? FileManager.default.removeItem(at: url) } }
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

/// Re-encodes the master into a lighter video. Quality-targeted (not bitrate-targeted) hardware
/// encoding: static screens cost almost nothing, text stays sharp. Measured on a 4 s scrolling
/// test at 1120×720: master 2.5 MB → MP4 ≈ 1.1 MB, HEVC ≈ 0.7 MB. All audio tracks (Mac sound,
/// microphone) are mixed into one AAC track, because many players only play the first track.
private nonisolated enum Transcoder {
    static func run(_ source: URL, to url: URL, format: Format,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw TomaError.exportFailed(underlying: "no video track")
        }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        let size = try await video.load(.naturalSize)
        let colors = try await video.load(.formatDescriptions).first.map(colorProperties) ?? [:]

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
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
            AVVideoQualityKey: format == .hevc ? 0.55 : 0.6,
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
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
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

private nonisolated struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Reads the master sequentially and streams a looping GIF through `GIF`.
///
/// SCK writes frames only when the screen changes, so the master has a variable frame rate.
/// The encoder samples it on a fixed 1/fps clock (latest frame at or before each tick); runs of
/// identical samples become one frame with a longer delay, so static screen time costs nothing.
/// Delays are rounded cumulatively, so any fps keeps exact total timing despite 1/100 s units.
private nonisolated enum GIFEncoder {
    static func encode(_ clip: Clip, policy: GIFPolicy, to url: URL,
                       progress: @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: clip.master)
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
        func render(_ buffer: CVPixelBuffer) -> GIF.Frame {
            var image = CIImage(cvPixelBuffer: buffer)
            if fit < 1 {
                image = image.clampedToExtent()
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: fit, kCIInputAspectRatioKey: 1])
            }
            var pixels = [UInt32](repeating: 0, count: width * height)
            pixels.withUnsafeMutableBytes {
                ci.render(image, toBitmap: $0.baseAddress!, rowBytes: width * 4,
                          bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: sRGB)
            }
            return GIF.Frame(pixels: pixels, width: width, height: height)
        }

        let fps = Double(policy.framesPerSecond)
        let ticks = max(1, Int((clip.duration * fps).rounded(.up)))
        func centiseconds(_ from: Int, _ to: Int) -> Int {
            Int((Double(to) * 100 / fps).rounded()) - Int((Double(from) * 100 / fps).rounded())
        }

        let writer = try GIF.Writer(url: url, width: width, height: height)
        // Deltas are found in order, then encoded in parallel batches.
        var jobs: [(delta: GIF.Delta, cs: Int)] = []
        func flushJobs() async throws {
            let batch = jobs
            jobs = []
            let encoded = await withTaskGroup(of: (Int, Data).self) { group in
                for (i, job) in batch.enumerated() {
                    group.addTask { (i, GIF.encode(job.delta, centiseconds: job.cs)) }
                }
                var out = [Data](repeating: Data(), count: batch.count)
                for await (i, data) in group { out[i] = data }
                return out
            }
            for data in encoded { try writer.append(data) }
        }

        var differ = GIF.Differ()
        var pending: (delta: GIF.Delta, start: Int)?
        var current: CVPixelBuffer?, drawn: CVPixelBuffer?
        var next = output.copyNextSampleBuffer()
        let batchSize = max(2, ProcessInfo.processInfo.activeProcessorCount)

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
            if let p = pending { jobs.append((p.delta, centiseconds(p.start, tick))) }
            pending = (delta, tick)
            if jobs.count >= batchSize {
                try await flushJobs()
                progress(Double(tick) / Double(ticks))
            }
        }
        if let p = pending { jobs.append((p.delta, max(2, centiseconds(p.start, ticks)))) }
        try await flushJobs()
        try writer.finish()
        progress(1)
    }
}
