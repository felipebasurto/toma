import AppKit

/// All of Toma's on-screen chrome while capturing: the selection veil and the recording frame.
/// One module because both share the same knowledge — borderless, above-everything windows
/// per screen — and both must stay out of the recording (guaranteed by Recording's filter
/// excluding Toma's own app, not by window flags here).
enum Overlay {
    /// Shows a faint veil on every screen with a crosshair, like ⇧⌘4.
    /// Drag draws a clear rectangle with its size in pixels ("1280 × 720") beside the cursor.
    /// Release → region; Esc, right-click, or a drag smaller than ScreenRegion.minimumSide → nil.
    /// Modifiers are exactly ⇧⌘4's, so muscle memory transfers and nothing new is taught:
    /// Space (held) moves the rectangle, ⇧ locks one axis, ⌥ grows from the center.
    ///
    /// Invariant: all veil windows are closed before this returns, on every path.
    static func select() async -> ScreenRegion? {
        await withCheckedContinuation { continuation in
            Selection(done: { continuation.resume(returning: $0) }).begin()
        }
    }

    /// A 1-pt hairline drawn *just outside* the region (so it is never inside sourceRect even
    /// before exclusion applies), plus nothing else: no timer, no button — the menu bar has those.
    /// Click-through so the recorded content stays usable.
    static func frame(around region: ScreenRegion) -> FrameHandle {
        let window = chromeWindow(frame: region.frame.insetBy(dx: -2, dy: -2))
        window.ignoresMouseEvents = true
        window.contentView = HairlineView()
        window.orderFrontRegardless()
        return FrameHandle(window: window)
    }

    /// Owns the frame window. `close()` is idempotent; deinit also closes.
    final class FrameHandle {
        private var window: NSWindow?
        fileprivate init(window: NSWindow) { self.window = window }
        func close() { window?.orderOut(nil); window = nil }
        isolated deinit { window?.orderOut(nil) }
    }

    fileprivate static func chromeWindow(frame: CGRect) -> NSWindow {
        let window = KeyableWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return window
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class HairlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}

/// One selection gesture across all screens. Owns the drag state (in AppKit global points) and
/// the veil windows; each veil only draws. Resolves exactly once, closing every window first.
private final class Selection {
    private let done: (ScreenRegion?) -> Void
    private var windows: [NSWindow] = []
    private var finished = false
    private var screenObserver: NSObjectProtocol?

    // Drag state. `anchor` is where the drag began (or its center with ⌥).
    private(set) var screen: NSScreen?
    private var anchor: CGPoint = .zero
    private var pointer: CGPoint = .zero
    private var moving = false
    private var axisLock: AxisLock = .none
    private var fromCenter = false

    private enum AxisLock { case none, undecided(CGPoint), horizontal(CGFloat), vertical(CGFloat) }

    init(done: @escaping (ScreenRegion?) -> Void) { self.done = done }

    func begin() {
        NSApp.activate()
        for screen in NSScreen.screens {
            let window = Overlay.chromeWindow(frame: screen.frame)
            window.acceptsMouseMovedEvents = true
            window.contentView = VeilView(selection: self)
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        if let underPointer = windows.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            underPointer.makeKey()
        }
        NSCursor.crosshair.push()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.finish(nil) } }
    }

    /// The rectangle as drawn, clamped to the screen where the drag began. Nil before a drag.
    var rect: CGRect? {
        guard let screen else { return nil }
        let dx = abs(pointer.x - anchor.x), dy = abs(pointer.y - anchor.y)
        let raw = fromCenter
            ? CGRect(x: anchor.x - dx, y: anchor.y - dy, width: 2 * dx, height: 2 * dy)
            : CGRect(x: min(anchor.x, pointer.x), y: min(anchor.y, pointer.y), width: dx, height: dy)
        let clamped = raw.intersection(screen.frame)
        return clamped.isNull ? nil : clamped
    }

    /// What the recording would be, for the size label.
    var region: ScreenRegion? {
        guard let screen, let rect else { return nil }
        return ScreenRegion(dragged: rect, on: screen)
    }

    // MARK: events, forwarded by every veil

    func mouseDown(at point: CGPoint) {
        screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        anchor = point
        pointer = point
        fromCenter = NSEvent.modifierFlags.contains(.option)
        redraw()
    }

    func mouseDragged(to point: CGPoint) {
        guard screen != nil else { return }
        var point = point
        if moving {
            anchor.x += point.x - pointer.x
            anchor.y += point.y - pointer.y
        } else {
            switch axisLock {
            case .none: break
            case .undecided(let base):
                axisLock = abs(point.x - base.x) >= abs(point.y - base.y) ? .horizontal(base.y) : .vertical(base.x)
                return mouseDragged(to: point)
            case .horizontal(let y): point.y = y
            case .vertical(let x): point.x = x
            }
        }
        pointer = point
        redraw()
    }

    func mouseUp() {
        guard screen != nil else { return }
        finish(region)
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard screen != nil else { return }
        if flags.contains(.shift) {
            if case .none = axisLock { axisLock = .undecided(pointer) }
        } else {
            axisLock = .none
        }
        let center = flags.contains(.option)
        if center != fromCenter {
            // Keep the rectangle where it is visually: re-anchor at its center or its corner.
            if center {
                anchor = CGPoint(x: (anchor.x + pointer.x) / 2, y: (anchor.y + pointer.y) / 2)
            } else {
                anchor = CGPoint(x: 2 * anchor.x - pointer.x, y: 2 * anchor.y - pointer.y)
            }
            fromCenter = center
        }
        redraw()
    }

    func space(down: Bool) { moving = down && screen != nil }

    func cancel() { finish(nil) }

    private func redraw() {
        for window in windows { window.contentView?.needsDisplay = true }
    }

    private func finish(_ region: ScreenRegion?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        for window in windows { window.orderOut(nil); window.contentView = nil }
        windows = []
        done(region)
    }
}

/// One per screen. Draws the faint veil, the clear selection with a hairline, and the size.
private final class VeilView: NSView {
    private let selection: Selection   // strong: the veils keep the gesture alive until finish()

    init(selection: Selection) {
        self.selection = selection
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private func global(_ event: NSEvent) -> CGPoint {
        window!.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDown(with event: NSEvent) { selection.mouseDown(at: global(event)) }
    override func mouseDragged(with event: NSEvent) { selection.mouseDragged(to: global(event)) }
    override func mouseUp(with event: NSEvent) { selection.mouseUp() }
    override func rightMouseDown(with event: NSEvent) { selection.cancel() }
    override func flagsChanged(with event: NSEvent) { selection.modifiersChanged(event.modifierFlags) }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: selection.cancel()                                   // Esc
        case 49: if !event.isARepeat { selection.space(down: true) }  // Space
        default: break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { selection.space(down: false) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let origin = window.frame.origin
        let local = selection.rect.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }

        let veil = NSBezierPath(rect: bounds)
        veil.windingRule = .evenOdd
        if let local { veil.append(NSBezierPath(rect: local)) }
        NSColor(white: 0, alpha: local == nil ? 0.08 : 0.28).setFill()
        veil.fill()

        guard let local, local.intersects(bounds) else { return }
        let scale = window.backingScaleFactor
        let edge = NSBezierPath(rect: local.insetBy(dx: 0.5 / scale, dy: 0.5 / scale))
        edge.lineWidth = 1 / scale
        NSColor(white: 1, alpha: 0.9).setStroke()
        edge.stroke()

        guard let size = selection.region?.pixelSize, selection.screen == window.screen else { return }
        drawLabel("\(size.width) × \(size.height)", near: local)
    }

    /// A quiet capsule just below the bottom-right corner, flipped inside if it would leave the screen.
    private func drawLabel(_ text: String, near rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        var box = CGRect(x: rect.maxX - textSize.width - 12, y: rect.minY - textSize.height - 10,
                         width: textSize.width + 12, height: textSize.height + 4)
        if box.minY < bounds.minY + 4 { box.origin.y = rect.minY + 6 }
        if box.minX < bounds.minX + 4 { box.origin.x = rect.minX }
        NSColor(white: 0, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2))
    }
}
