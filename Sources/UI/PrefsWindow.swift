import AppKit

final class PrefsWindow: NSObject, NSWindowDelegate {
    private static var shared: PrefsWindow?
    private var window: NSWindow?
    private weak var engine: ShareEngine?
    private var prefs = QSPreferences.load()
    private var destLabel: NSTextField!
    private var nameField: NSTextField!
    private var autoOffField: NSTextField!
    private var autoAcceptBox: NSButton!

    static func show(engine: ShareEngine) {
        if let existing = shared {
            existing.engine = engine
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let p = PrefsWindow()
        p.engine = engine
        shared = p
        p.open()
    }

    private func open() {
        prefs = QSPreferences.load()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "QuickShare Preferences"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        guard let content = window.contentView else { return }

        let destTitle = NSTextField(labelWithString: "Download folder:")
        destTitle.frame = NSRect(x: 20, y: 252, width: 400, height: 20)
        content.addSubview(destTitle)

        destLabel = NSTextField(labelWithString: prefs.destination.path)
        destLabel.frame = NSRect(x: 20, y: 228, width: 280, height: 22)
        destLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(destLabel)

        let choose = NSButton(title: "Choose…", target: self, action: #selector(pickDestination))
        choose.frame = NSRect(x: 310, y: 224, width: 110, height: 30)
        choose.bezelStyle = .rounded
        content.addSubview(choose)

        let nameTitle = NSTextField(labelWithString: "Device name (shown to Android):")
        nameTitle.frame = NSRect(x: 20, y: 192, width: 400, height: 20)
        content.addSubview(nameTitle)

        nameField = NSTextField(string: prefs.deviceName)
        nameField.frame = NSRect(x: 20, y: 164, width: 400, height: 24)
        content.addSubview(nameField)

        let offTitle = NSTextField(labelWithString: "Auto-off receive mode after (minutes, 0 = never):")
        offTitle.frame = NSRect(x: 20, y: 132, width: 400, height: 20)
        content.addSubview(offTitle)

        autoOffField = NSTextField(string: "\(prefs.autoOffMinutes)")
        autoOffField.frame = NSRect(x: 20, y: 104, width: 100, height: 24)
        content.addSubview(autoOffField)

        autoAcceptBox = NSButton(checkboxWithTitle: "Auto-accept incoming transfers", target: nil, action: nil)
        autoAcceptBox.frame = NSRect(x: 20, y: 72, width: 400, height: 20)
        autoAcceptBox.state = prefs.autoAcceptKnown ? .on : .off
        content.addSubview(autoAcceptBox)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.frame = NSRect(x: 310, y: 16, width: 110, height: 32)
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        content.addSubview(save)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.destination = url
        _ = url.startAccessingSecurityScopedResource()
        destLabel?.stringValue = url.path
    }

    @objc private func save() {
        prefs.deviceName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "Mac")
            : nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        prefs.autoOffMinutes = max(0, Int(autoOffField.stringValue) ?? 15)
        prefs.autoAcceptKnown = autoAcceptBox.state == .on
        prefs.save()
        engine?.reloadPreferences()
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if PrefsWindow.shared === self {
            PrefsWindow.shared = nil
        }
    }
}
