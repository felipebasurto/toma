import AppKit
import AVFoundation

/// The few choices Toma remembers. One owner: the menu writes them, everything else reads.
/// (The suggested format is not here: it is a by-product of saving, owned by Library.)
enum Preferences {
    enum GIFSize: String, CaseIterable {
        case sharp, light

        var title: String {
            switch self {
            case .sharp: "Nítido"
            case .light: "Ligero"
            }
        }

        var detail: String {
            switch self {
            case .sharp: "Resolución completa, 20 fps"
            case .light: "640 px, 15 fps · para chats"
            }
        }

        var policy: GIFPolicy {
            switch self {
            case .sharp: GIFPolicy(framesPerSecond: 20, maxLongEdge: 1920)
            case .light: GIFPolicy(framesPerSecond: 15, maxLongEdge: 640)
            }
        }
    }

    enum Audio: String, CaseIterable {
        case none, system, systemAndMicrophone

        var title: String {
            switch self {
            case .none: "Sin sonido"
            case .system: "Sonido del Mac"
            case .systemAndMicrophone: "Sonido del Mac y micrófono"
            }
        }
    }

    /// nil → the folder macOS uses for screenshots.
    static var folder: URL? {
        get { UserDefaults.standard.url(forKey: "carpeta") }
        set { UserDefaults.standard.set(newValue, forKey: "carpeta") }
    }

    static var gifSize: GIFSize {
        get { GIFSize(rawValue: UserDefaults.standard.string(forKey: "tamañoGIF") ?? "") ?? .sharp }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "tamañoGIF") }
    }

    static var audio: Audio {
        get { Audio(rawValue: UserDefaults.standard.string(forKey: "sonido") ?? "") ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "sonido") }
    }

    /// Asks for the microphone when the user picks it, not in the middle of a recording.
    /// Falls back to system sound only if access is refused.
    static func choose(_ audio: Audio) {
        Preferences.audio = audio
        guard audio == .systemAndMicrophone else { return }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard !granted else { return }
            Task { @MainActor in Preferences.audio = .system }
        }
    }

    /// Lets the user pick the folder recordings go to.
    static func chooseFolder() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Elegir"
        panel.message = "Elige dónde guardar las grabaciones."
        panel.directoryURL = Library.destination
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}
