import AppKit
import CoreGraphics

/// A rectangle of exactly one display that ScreenCaptureKit can record as-is.
///
/// Invariants (all established by the only initializer, so every value is capturable):
/// - lies entirely inside one display (`displayID`); a drag that crosses screens is clamped
///   to the display where it began, because one SCStream captures one display;
/// - snapped to that display's pixel grid, and its pixel size is even in both axes
///   (H.264 4:2:0 needs even dimensions; odd sizes get silently cropped by the encoder);
/// - at least `minimumSide` points per side, so a stray click is "cancel", never a 1-px video.
///
/// Stored once in AppKit global coordinates (what the overlay draws in); every other
/// coordinate system is *derived*, never stored, so they cannot drift apart.
nonisolated struct ScreenRegion: Sendable, Equatable {
    let displayID: CGDirectDisplayID
    /// AppKit global space: points, origin bottom-left of the primary display.
    let frame: CGRect
    /// The display's frame in the same AppKit global space.
    let displayFrame: CGRect
    /// Backing scale factor of the display (2 on Retina).
    let scale: CGFloat

    static let minimumSide: CGFloat = 8

    /// Builds a region from a raw drag rectangle on `screen`. Returns nil for drags that are
    /// too small after clamping — the caller treats that as "cancelled".
    @MainActor
    init?(dragged rect: CGRect, on screen: NSScreen) {
        guard let id = screen.displayID else { return nil }
        self.init(dragged: rect, displayFrame: screen.frame, scale: screen.backingScaleFactor, displayID: id)
    }

    init?(dragged rect: CGRect, displayFrame d: CGRect, scale: CGFloat, displayID: CGDirectDisplayID) {
        let clamped = rect.standardized.intersection(d)
        guard !clamped.isNull else { return nil }

        // Pixel edges, display-local, origin bottom-left.
        let limitX = (d.width * scale).rounded(), limitY = (d.height * scale).rounded()
        var x0 = ((clamped.minX - d.minX) * scale).rounded(.down)
        var x1 = ((clamped.maxX - d.minX) * scale).rounded(.up)
        var y0 = ((clamped.minY - d.minY) * scale).rounded(.down)
        var y1 = ((clamped.maxY - d.minY) * scale).rounded(.up)
        Self.makeEven(&x0, &x1, limit: limitX)
        Self.makeEven(&y0, &y1, limit: limitY)

        let frame = CGRect(x: d.minX + x0 / scale, y: d.minY + y0 / scale,
                           width: (x1 - x0) / scale, height: (y1 - y0) / scale)
        guard frame.width >= Self.minimumSide, frame.height >= Self.minimumSide else { return nil }

        self.displayID = displayID
        self.frame = frame
        self.displayFrame = d
        self.scale = scale
    }

    /// Grows the span by one pixel when its length is odd, toward whichever side has room.
    private static func makeEven(_ lo: inout CGFloat, _ hi: inout CGFloat, limit: CGFloat) {
        guard Int(hi - lo) % 2 != 0 else { return }
        if hi < limit { hi += 1 } else if lo > 0 { lo -= 1 } else { hi -= 1 }
    }

    /// `SCStreamConfiguration.sourceRect`: display-local points, origin top-left.
    var sourceRect: CGRect {
        CGRect(x: frame.minX - displayFrame.minX,
               y: displayFrame.maxY - frame.maxY,
               width: frame.width,
               height: frame.height)
    }

    /// Output pixel size at native resolution. Even in both axes by construction.
    var pixelSize: (width: Int, height: Int) {
        (Int((frame.width * scale).rounded()), Int((frame.height * scale).rounded()))
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func with(displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }
}
