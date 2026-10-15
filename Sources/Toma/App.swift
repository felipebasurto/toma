import AppKit
import Carbon.HIToolbox

// The thin shell. Everything here is wiring: no decisions live in this file.
// Default isolation is MainActor (Package.swift), so UI code needs no annotations;
// the few off-main types say `nonisolated` explicitly.

@main
enum TomaApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)          // LSUIElement: no Dock icon, no main menu
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var toma: Toma?
    private var hotkey: Hotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Library.removeLeftovers()                    // crash-halfway cleanup, day-old clipboard files
        let toma = Toma()
        self.toma = toma
        hotkey = Hotkey(.optionShiftCommand4) { toma.toggle() }
    }
}

/// A single system-wide shortcut, registered through Carbon's `RegisterEventHotKey`.
/// Chosen over `NSEvent.addGlobalMonitorForEvents` because it needs no Accessibility
/// permission and it *consumes* the keystroke instead of letting it leak to the front app.
/// Invariant: at most one live registration per `Hotkey` instance; deinit unregisters.
final class Hotkey {
    /// The only shortcut Toma has. ⌥⇧⌘4 reads as "⇧⌘4, but the other kind" and
    /// does not collide with any shortcut macOS ships. Not configurable on purpose.
    struct Chord: Sendable {
        let keyCode: UInt32
        let modifiers: UInt32

        static let optionShiftCommand4 = Chord(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(optionKey | shiftKey | cmdKey)
        )
    }

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// If another app owns the chord, registration fails quietly: the menu bar still works.
    init(_ chord: Chord, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }, 1, &spec, me, &handlerRef)
        RegisterEventHotKey(chord.keyCode, chord.modifiers, EventHotKeyID(signature: 0x546F_6D61 /* Toma */, id: 1),
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
