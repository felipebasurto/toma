import AppKit
import ServiceManagement

/// The menu-bar presence. Pure rendering of `Toma.Phase` plus forwarding clicks; holds no state
/// of its own beyond the timer that redraws elapsed time.
///
/// - idle: a dashed rectangle. Click → menu: "Grabar zona ⌥⇧⌘4", then the three choices Toma
///   remembers (folder, GIF size, sound), "Abrir al iniciar sesión", "Salir de Toma".
/// - recording: a stop glyph + monospaced elapsed time, "■ 0:42". Click → stop (no menu:
///   when recording there is exactly one thing to do).
/// - saving: a ring that fills as the file is written; a checkmark flashes after a copy.
/// - busy / reviewing: the idle icon, dimmed.
final class StatusItem: NSObject {
    /// Set once by Toma. Called for "Grabar zona" and for any click while recording.
    var onPress: () -> Void = {}

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var ticker: Timer?
    private var phase: Toma.Phase = .idle

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
    }

    func render(_ phase: Toma.Phase) {
        self.phase = phase
        ticker?.invalidate()
        ticker = nil
        guard let button = item.button else { return }
        button.appearsDisabled = false
        button.title = ""
        button.imagePosition = .imageOnly

        switch phase {
        case .idle:
            button.image = symbol("rectangle.dashed", "Toma")
        case .busy, .reviewing:
            button.image = symbol("rectangle.dashed", "Toma")
            button.appearsDisabled = true
        case .saving(let progress):
            button.image = ring(progress)
        case .recording(_, let since):
            button.image = symbol("stop.fill", "Detener grabación", size: 9)
            button.imagePosition = .imageLeading
            let update: @MainActor @Sendable () -> Void = { [weak button] in
                guard let button else { return }
                let elapsed = Int((ContinuousClock.now - since).components.seconds)
                button.attributedTitle = NSAttributedString(
                    string: String(format: " %d:%02d", elapsed / 60, elapsed % 60),
                    attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
            }
            update()
            let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { update() } }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    @objc private func clicked() {
        switch phase {
        case .idle: showMenu()
        case .recording: onPress()
        case .busy, .reviewing, .saving: break
        }
    }

    private func showMenu() {
        guard let button = item.button else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let record = item("Grabar zona", #selector(record), key: "4")
        record.keyEquivalentModifierMask = [.option, .shift, .command]
        menu.addItem(record)
        menu.addItem(.separator())

        // Choices, each shown with its current value, Apple-style.
        let folder = NSMenuItem(title: "Guardar en", action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        let current = item(FileManager.default.displayName(atPath: Library.destination.path), nil)
        current.image = NSWorkspace.shared.icon(forFile: Library.destination.path)
        current.image?.size = CGSize(width: 16, height: 16)
        current.state = .on
        folderMenu.addItem(current)
        folderMenu.addItem(.separator())
        folderMenu.addItem(item("Otra carpeta…", #selector(chooseFolder)))
        if Preferences.folder != nil {
            folderMenu.addItem(item("Usar la carpeta de las capturas", #selector(resetFolder)))
        }
        folderMenu.addItem(item("Mostrar en Finder", #selector(revealFolder)))
        folder.submenu = folderMenu
        menu.addItem(folder)

        let gif = NSMenuItem(title: "Tamaño del GIF", action: nil, keyEquivalent: "")
        let gifMenu = NSMenu()
        for size in Preferences.GIFSize.allCases {
            let option = item(size.title, #selector(chooseGIFSize(_:)))
            option.representedObject = size.rawValue
            option.state = Preferences.gifSize == size ? .on : .off
            option.toolTip = size.detail
            option.subtitle = size.detail
            gifMenu.addItem(option)
        }
        gif.submenu = gifMenu
        menu.addItem(gif)

        let sound = NSMenuItem(title: "Sonido", action: nil, keyEquivalent: "")
        let soundMenu = NSMenu()
        for audio in Preferences.Audio.allCases {
            let option = item(audio.title, #selector(chooseAudio(_:)))
            option.representedObject = audio.rawValue
            option.state = Preferences.audio == audio ? .on : .off
            soundMenu.addItem(option)
        }
        sound.submenu = soundMenu
        menu.addItem(sound)

        menu.addItem(.separator())
        let login = item("Abrir al iniciar sesión", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Salir de Toma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = action != nil
        return item
    }

    @objc private func chooseFolder() { Preferences.chooseFolder() }
    @objc private func resetFolder() { Preferences.folder = nil }
    @objc private func revealFolder() { NSWorkspace.shared.open(Library.destination) }

    @objc private func chooseGIFSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = Preferences.GIFSize(rawValue: raw) {
            Preferences.gifSize = size
        }
    }

    @objc private func chooseAudio(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let audio = Preferences.Audio(rawValue: raw) {
            Preferences.choose(audio)
        }
    }

    /// A brief checkmark after copying to the clipboard: the only confirmation, and it's enough.
    func flash() {
        guard let button = item.button else { return }
        button.image = symbol("checkmark", "Copiado")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            render(phase)
        }
    }

    @objc private func record() { onPress() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    private func symbol(_ name: String, _ description: String, size: CGFloat = 14) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        image?.isTemplate = true
        return image
    }

    /// A thin ring with a filled arc: the only progress Toma ever shows.
    private func ring(_ progress: Double) -> NSImage {
        let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let track = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            track.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.25).setStroke()
            track.stroke()
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 6, startAngle: 90, endAngle: 90 - 360 * max(0.02, progress), clockwise: true)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Guardando GIF"
        return image
    }
}
