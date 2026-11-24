import AppKit
import AVFoundation
import AVKit

/// After a recording: a floating thumbnail in the bottom-right corner of the screen where the
/// recording happened — the same place as the ⇧⌘4 thumbnail — playing the clip muted on loop,
/// with the formats under it: "MP4 · HEVC · GIF". The suggested one is emphasized.
///
/// - Click a word → save in that format.
/// - The copy glyph → the suggested format goes to the clipboard, ready to paste.
/// - Do nothing for 6 s, or swipe the card right → save in the suggested format.
///   (Like screenshots: ignoring it is the fast path, and it never loses a recording.)
/// - Drag the thumbnail into Finder, Mail, Slack… → the file is delivered there, in the
///   suggested format, and nowhere else.
/// - The "×" on hover → discard.
/// - Click the thumbnail → the clip opens big, with sound and a scrubber, and the same choices
///   (like the screenshot thumbnail opening into Markup). The countdown waits while it is open;
///   closing it without choosing (Esc) brings the card back.
///
/// It is the only place the user ever chooses a format, and they choose after seeing the clip.
final class ResultCard {
    enum Choice: Sendable, Equatable {
        case save(Format)
        case copy(Format)
        case discard
        /// Already written somewhere by a drag-out; nothing left to do.
        case delivered
    }

    private let clip: Clip
    private let suggested: Format
    private let decided = OneShot<Choice>()
    private var panel: NSPanel?
    private var timeout: Task<Void, Never>?
    private var hovering = false
    private var dragging = false
    private var swipe: CGFloat = 0
    private var resolved = false
    private var preview: PreviewWindow?
    /// Whoever was in front before the preview took focus; they get it back when it closes.
    private var previousApp: NSRunningApplication?

    private static let lifetime: Duration = .seconds(6)

    init(_ clip: Clip, suggesting suggested: Format) {
        self.clip = clip
        self.suggested = suggested
    }

    /// Shows the card and resolves exactly once; the window is gone before it returns.
    func choice() async -> Choice {
        show()
        let choice = await decided.value
        hide(sliding: choice != .discard)
        return choice
    }

    /// Saves in the suggested format now (the hotkey pressed while the card is up).
    func commit() { resolve(.save(suggested)) }

    private func resolve(_ choice: Choice) {
        timeout?.cancel()
        resolved = true
        closePreview()
        decided.resolve(choice)
    }

    private func restartTimeout() {
        timeout?.cancel()
        guard !hovering, !dragging, preview == nil else { return }
        timeout = Task { [weak self, suggested] in
            try? await Task.sleep(for: Self.lifetime)
            guard !Task.isCancelled else { return }
            self?.resolve(.save(suggested))
        }
    }

    // MARK: window

    private func show() {
        let pixel = clip.region.pixelSize
        let aspect = CGFloat(pixel.width) / CGFloat(pixel.height)
        let maxThumb = CGSize(width: 240, height: 160)
        var thumb = CGSize(width: maxThumb.width, height: maxThumb.width / aspect)
        if thumb.height > maxThumb.height { thumb = CGSize(width: maxThumb.height * aspect, height: maxThumb.height) }
        thumb.width = max(thumb.width, 204)            // room for the format row
        thumb.height = max(thumb.height, 60)

        let pad: CGFloat = 6, bar: CGFloat = 32
        let size = CGSize(width: thumb.width + 2 * pad, height: thumb.height + pad + bar)

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let card = CardView(frame: CGRect(origin: .zero, size: size), owner: self)
        card.build(thumb: CGRect(x: pad, y: bar, width: thumb.width, height: thumb.height),
                   bar: CGRect(x: 0, y: 0, width: size.width, height: bar),
                   clip: clip, suggested: suggested)
        panel.contentView = card
        self.panel = panel

        let screen = NSScreen.with(displayID: clip.region.displayID) ?? NSScreen.main!
        let resting = CGPoint(x: screen.visibleFrame.maxX - size.width - 16, y: screen.visibleFrame.minY + 16)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrameOrigin(reduceMotion ? resting : CGPoint(x: screen.visibleFrame.maxX + 8, y: resting.y))
        panel.alphaValue = reduceMotion ? 0 : 1
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(CGRect(origin: resting, size: size), display: true)
            panel.animator().alphaValue = 1
        }
        restartTimeout()
    }

    private func hide(sliding: Bool) {
        guard let panel else { return }
        self.panel = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if sliding && !reduceMotion {
                panel.animator().setFrame(panel.frame.offsetBy(dx: panel.frame.width + 24, dy: 0), display: true)
            }
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                (panel.contentView as? CardView)?.stop()
                panel.orderOut(nil)
            }
        }
    }

    // MARK: the big preview

    /// The thumbnail was clicked: the card steps aside for the preview window.
    fileprivate func expand() {
        guard !resolved, preview == nil, let panel else { return }
        timeout?.cancel()
        let screen = NSScreen.with(displayID: clip.region.displayID) ?? panel.screen ?? NSScreen.main!
        let window = PreviewWindow(clip: clip, suggested: suggested, owner: self, on: screen)
        preview = window
        (panel.contentView as? CardView)?.pause()
        panel.orderOut(nil)
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// The preview closed without a choice: the card comes back and its countdown starts over.
    fileprivate func collapse() {
        guard preview != nil else { return }    // closed by a choice: nothing to come back to
        closePreview()
        hovering = false
        if let panel {
            (panel.contentView as? CardView)?.resume()
            panel.orderFrontRegardless()
        }
        restartTimeout()
    }

    private func closePreview() {
        guard let window = preview else { return }
        preview = nil                           // first, so the window's close doesn't collapse
        window.dismiss()
        previousApp?.activate()
        previousApp = nil
    }

    // MARK: input from the card view

    fileprivate func hover(_ inside: Bool) {
        hovering = inside
        restartTimeout()
    }

    fileprivate func picked(_ format: Format) { resolve(.save(format)) }
    fileprivate func copy() { resolve(.copy(suggested)) }
    fileprivate func discard() { resolve(.discard) }

    fileprivate func scrolled(_ deltaX: CGFloat) {
        swipe += deltaX
        if swipe < -40 || swipe > 40 { commit() }   // either direction reads as "away"
    }

    fileprivate func dragBegan() {
        dragging = true
        restartTimeout()
    }

    fileprivate func dragEnded(delivered: Bool) {
        dragging = false
        if !delivered { restartTimeout() }
    }

    /// Called by the file promise: write the clip at exactly `url`.
    fileprivate func deliver(to url: URL) async throws {
        timeout?.cancel()
        try await Library.save(clip, as: suggested, to: url)
        resolve(.delivered)
    }

    fileprivate var promisedName: String { "\(Library.fileName()).\(suggested.fileExtension)" }
    fileprivate var promisedType: String { suggested.type.identifier }
}

/// The card's contents: a looping muted thumbnail and the format row.
private final class CardView: NSVisualEffectView {
    private weak var owner: ResultCard?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var closeButton: NSButton?
    private var thumb: ThumbView?

    init(frame: CGRect, owner: ResultCard) {
        self.owner = owner
        super.init(frame: frame)
        material = .popover
        state = .active
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func build(thumb frame: CGRect, bar: CGRect, clip: Clip, suggested: Format) {
        let item = AVPlayerItem(url: clip.master)
        let player = AVQueuePlayer()
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: item)
        self.player = player

        let thumb = ThumbView(frame: frame, owner: owner)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6                   // concentric with the card: 12 − 6 pt inset
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        let video = AVPlayerLayer(player: player)
        video.videoGravity = .resizeAspect
        video.frame = thumb.bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        thumb.layer?.addSublayer(video)
        addSubview(thumb)
        self.thumb = thumb
        player.play()
        Task { [weak thumb] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.master))
            generator.maximumSize = CGSize(width: frame.width * 2, height: frame.height * 2)
            guard let (image, _) = try? await generator.image(at: .zero) else { return }
            thumb?.poster = NSImage(cgImage: image, size: frame.size)
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 5
        for (i, format) in Format.allCases.enumerated() {
            if i > 0 { row.addArrangedSubview(label("·", color: .tertiaryLabelColor, size: 12)) }
            let button = TextButton(format.label, emphasized: format == suggested, target: self, action: #selector(pick(_:)))
            button.tag = i
            button.toolTip = format.help
            button.setAccessibilityLabel(tr("Save as %@", format.label))
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: tr("Copy"))!,
                            target: self, action: #selector(copyToClipboard))
        copy.isBordered = false
        copy.contentTintColor = .secondaryLabelColor
        copy.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        copy.toolTip = tr("Copy %@ to clipboard", suggested.label)
        copy.setAccessibilityLabel(tr("Copy %@ to clipboard", suggested.label))
        copy.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copy)

        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: leadingAnchor, constant: bar.midX),
            row.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -bar.midY),
            copy.trailingAnchor.constraint(equalTo: leadingAnchor, constant: frame.maxX - 2),
            copy.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        // Duration, quietly, in the thumbnail's corner: the one number worth knowing.
        let seconds = Int(clip.duration.rounded())
        let badge = label(String(format: "%d:%02d", seconds / 60, seconds % 60), color: .white, size: 10, mono: true)
        badge.wantsLayer = true
        badge.shadow = { let s = NSShadow(); s.shadowBlurRadius = 3; s.shadowColor = .black.withAlphaComponent(0.6); s.shadowOffset = .zero; return s }()
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge, positioned: .above, relativeTo: thumb)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: frame.minX + 6),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(frame.minY + 4)),
        ])

        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: tr("Discard"))!,
                             target: self, action: #selector(discard))
        close.isBordered = false
        close.contentTintColor = .white
        close.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        close.frame = CGRect(x: frame.minX + 4, y: frame.maxY - 22, width: 18, height: 18)
        close.isHidden = true
        addSubview(close)
        closeButton = close

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func label(_ text: String, color: NSColor, size: CGFloat, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size)
        field.textColor = color
        return field
    }

    func stop() {
        player?.pause()
        looper = nil
        player = nil
    }

    func pause() { player?.pause() }
    func resume() { closeButton?.isHidden = true; player?.play() }

    @objc private func pick(_ sender: NSButton) { owner?.picked(Format.allCases[sender.tag]) }
    @objc private func discard() { owner?.discard() }
    @objc private func copyToClipboard() { owner?.copy() }

    override func mouseEntered(with event: NSEvent) { closeButton?.isHidden = false; owner?.hover(true) }
    override func mouseExited(with event: NSEvent) { closeButton?.isHidden = true; owner?.hover(false) }
    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas { owner?.scrolled(event.scrollingDeltaX) }
    }
}

/// A format word. The suggested one is semibold; hovering any of them brings it to full contrast.
private final class TextButton: NSButton {
    private let text: String
    private let emphasized: Bool

    init(_ text: String, emphasized: Bool, target: AnyObject, action: Selector) {
        self.text = text
        self.emphasized = emphasized
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        style(hovering: false)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func style(hovering: Bool) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular),
            .foregroundColor: emphasized || hovering ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
    }

    override func mouseEntered(with event: NSEvent) { style(hovering: true) }
    override func mouseExited(with event: NSEvent) { style(hovering: false) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The thumbnail: a drag source that promises the file, like the screenshot thumbnail.
private final class ThumbView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private weak var owner: ResultCard?
    private var downAt: CGPoint?
    private var delivered = false

    init(frame: CGRect, owner: ResultCard?) {
        self.owner = owner
        super.init(frame: frame)
        toolTip = tr("Click to preview. Drag to share.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tr("Preview"))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    /// A click that never became a drag opens the preview.
    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        owner?.expand()
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.expand()
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, let owner else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        downAt = nil

        let provider = NSFilePromiseProvider(fileType: owner.promisedType, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: snapshot())
        owner.dragBegan()
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The first frame of the clip, loaded when the card appears; the drag image.
    var poster: NSImage?

    private func snapshot() -> NSImage {
        if let poster { return poster }
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.black.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: bounds.size), xRadius: 6, yRadius: 6).fill()
        image.unlockFocus()
        return image
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] { owner?.dragEnded(delivered: false) }
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        MainActor.assumeIsolated { owner?.promisedName ?? tr("Screen Recording") }
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        MainActor.assumeIsolated {
            guard let owner else { return completionHandler(CocoaError(.fileWriteUnknown)) }
            Task {
                do {
                    try await owner.deliver(to: url)
                    owner.dragEnded(delivered: true)
                    completionHandler(nil)
                } catch {
                    owner.dragEnded(delivered: false)
                    completionHandler(error)
                }
            }
        }
    }
}

/// The clip at a size you can judge it, with sound and a scrubber, and the card's choices:
/// Return saves in the suggested format, ⌘C copies it, ⌘⌫ discards, Esc goes back to the card.
private final class PreviewWindow: NSWindow, NSWindowDelegate {
    private weak var owner: ResultCard?
    private let player: AVPlayer
    private let playerView = AVPlayerView()

    init(clip: Clip, suggested: Format, owner: ResultCard, on screen: NSScreen) {
        self.owner = owner
        player = AVPlayer(url: clip.master)

        // Native size in points, shrunk to fit the screen; a tiny region grows to 480 pt at most.
        let bar: CGFloat = 52, minWidth: CGFloat = 560
        let pixel = clip.region.pixelSize
        let native = CGSize(width: CGFloat(pixel.width) / screen.backingScaleFactor,
                            height: CGFloat(pixel.height) / screen.backingScaleFactor)
        let file = (width: clip.width, height: clip.height)
        let room = CGSize(width: screen.visibleFrame.width * 0.8, height: screen.visibleFrame.height * 0.8 - bar - 32)
        let fit = min(room.width / native.width, room.height / native.height,
                      max(1, 480 / max(native.width, native.height)))
        let size = CGSize(width: max((native.width * fit).rounded(), minWidth),
                          height: max((native.height * fit).rounded(), 200) + bar)

        super.init(contentRect: CGRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = tr("Screen Recording")
        let seconds = Int(clip.duration.rounded())
        subtitle = String(format: "%d:%02d · %d × %d px", seconds / 60, seconds % 60, file.width, file.height)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentMinSize = CGSize(width: minWidth, height: 200 + bar)
        delegate = self

        let content = NSView()
        contentView = content
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        let discard = NSButton(title: tr("Discard"), image: symbol("trash"), target: self, action: #selector(discard))
        discard.imagePosition = .imageLeading
        discard.hasDestructiveAction = true
        discard.contentTintColor = .systemRed
        discard.keyEquivalent = "\u{8}"
        discard.keyEquivalentModifierMask = .command
        discard.toolTip = "⌘⌫"
        discard.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(discard)

        let copy = NSButton(title: tr("Copy"), image: symbol("doc.on.doc"), target: self, action: #selector(copyToClipboard))
        copy.imagePosition = .imageLeading
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        copy.toolTip = tr("Copy %@ to clipboard", suggested.label) + "  ⌘C"
        copy.setAccessibilityLabel(tr("Copy %@ to clipboard", suggested.label))

        let caption = NSTextField(labelWithString: tr("Save as:"))
        caption.textColor = .secondaryLabelColor
        let row = NSStackView(views: [copy, caption])
        row.orientation = .horizontal
        row.spacing = 8
        row.setCustomSpacing(20, after: copy)
        for (i, format) in Format.allCases.enumerated() {
            let button = NSButton(title: format.label, target: self, action: #selector(pick(_:)))
            button.tag = i
            button.toolTip = format.help
            button.setAccessibilityLabel(tr("Save as %@", format.label))
            if format == suggested { button.keyEquivalent = "\r" }      // the blue one, Return
            row.addArrangedSubview(button)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -bar),
            discard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            discard.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: -bar / 2),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: discard.centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: discard.trailingAnchor, constant: 16),
        ])
        initialFirstResponder = playerView                              // Space plays and pauses

        let frame = frameRect(forContentRect: CGRect(origin: .zero, size: size))
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded()))
        player.play()
    }

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    /// Closes it for good: a choice was made.
    func dismiss() {
        player.pause()
        playerView.player = nil
        close()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        owner?.collapse()
    }

    @objc private func pick(_ sender: NSButton) { owner?.picked(Format.allCases[sender.tag]) }
    @objc private func discard() { owner?.discard() }
    @objc private func copyToClipboard() { owner?.copy() }
}
