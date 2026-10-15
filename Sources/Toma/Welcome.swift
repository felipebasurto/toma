import AppKit
import ServiceManagement

/// The one window Toma has: shown on first launch and whenever the app is opened again from
/// Finder, Launchpad or Spotlight. It answers "where did it go?" for a menu-bar app (the icon
/// may even hide behind the notch) and offers the three things a newcomer needs: record,
/// grant permission, open at login.
final class Welcome: NSObject, NSWindowDelegate {
    /// Called by "Grabar zona"; Toma starts a selection.
    var onRecord: () -> Void = {}

    private var window: NSWindow?
    private var permissionRow: NSView?
    private var loginBox: NSButton?

    private static let seenKey = "bienvenidaVista"

    /// First launch only. Login-item launches after that stay silent.
    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        show()
    }

    func show() {
        if window == nil { window = build() }
        refresh()
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.orderOut(nil) }

    // MARK: building

    private func build() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 470),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.delegate = self

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = label("Toma", font: .systemFont(ofSize: 26, weight: .bold), color: .labelColor)
        let subtitle = label("Vive en la barra de menús.\nGraba una zona de la pantalla con un atajo.",
                             font: .systemFont(ofSize: 13), color: .secondaryLabelColor)

        let keys = NSStackView(views: ["⌥", "⇧", "⌘", "4"].map(keycap))
        keys.spacing = 6

        let record = NSButton(title: "Grabar zona", target: self, action: #selector(recordNow))
        record.bezelStyle = .push
        record.controlSize = .large
        record.keyEquivalent = "\r"
        record.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let permission = NSStackView()
        permission.orientation = .horizontal
        permission.spacing = 8
        let warning = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)!)
        warning.contentTintColor = .systemOrange
        permission.addArrangedSubview(warning)
        permission.addArrangedSubview(label("Falta el permiso de Grabación de pantalla.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        let grant = NSButton(title: "Permitir…", target: self, action: #selector(grantPermission))
        grant.bezelStyle = .inline
        grant.controlSize = .small
        permission.addArrangedSubview(grant)
        permissionRow = permission

        let login = NSButton(checkboxWithTitle: "Abrir al iniciar sesión", target: self, action: #selector(toggleLogin(_:)))
        login.font = .systemFont(ofSize: 12)
        loginBox = login

        let stack = NSStackView(views: [icon, title, subtitle, keys, record, permission, login])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(26, after: subtitle)
        stack.setCustomSpacing(28, after: keys)
        stack.setCustomSpacing(20, after: record)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: 8),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 32),
        ])
        window.contentView = content
        return window
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = .center
        field.isSelectable = false
        return field
    }

    /// A key with a white face and a grey hairline, like the keys on the landing page. The colours
    /// are fixed, not system colours: in dark mode the system ones turned the keys black on black.
    private func keycap(_ glyph: String) -> NSView {
        let key = NSTextField(labelWithString: glyph)
        key.font = .systemFont(ofSize: 17, weight: .medium)
        key.textColor = NSColor(srgbRed: 0x37 / 255, green: 0x35 / 255, blue: 0x2F / 255, alpha: 1)
        key.alignment = .center
        key.wantsLayer = true
        key.layer?.cornerRadius = 8
        key.layer?.cornerCurve = .continuous
        key.layer?.borderWidth = 1
        key.layer?.borderColor = NSColor(srgbRed: 0xE9 / 255, green: 0xE9 / 255, blue: 0xE7 / 255, alpha: 1).cgColor
        key.layer?.backgroundColor = NSColor.white.cgColor
        key.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor(srgbRed: 0xD3 / 255, green: 0xD1 / 255, blue: 0xCB / 255, alpha: 1).cgColor  // the bottom edge
        box.addSubview(key)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 40),
            box.heightAnchor.constraint(equalToConstant: 40),
            key.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            key.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            key.topAnchor.constraint(equalTo: box.topAnchor),
            key.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        // Centre the glyph vertically inside the cap.
        key.cell?.usesSingleLineMode = true
        let inset = NSLayoutConstraint(item: key, attribute: .height, relatedBy: .equal, toItem: nil,
                                       attribute: .notAnAttribute, multiplier: 1, constant: 38)
        inset.priority = .defaultHigh
        key.addConstraint(inset)
        return box
    }

    private func refresh() {
        permissionRow?.isHidden = CGPreflightScreenCaptureAccess()
        loginBox?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: actions

    @objc private func recordNow() {
        close()
        onRecord()
    }

    @objc private func grantPermission() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        let service = SMAppService.mainApp
        try? sender.state == .on ? service.register() : service.unregister()
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}
