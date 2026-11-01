import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct SendHandoff: Decodable {
        let paths: [String]
    }
    private static let maxHandoffBytes = 1024 * 1024

    private var statusItem: NSStatusItem?
    private var receiveItem: NSMenuItem?
    private var prefsItem: NSMenuItem?
    private var recentMenu: NSMenu?
    private var statusLine: NSMenuItem?
    private var engine = ShareEngine()
    private var consentQueue: [(transfer: TransferMetadata, device: RemoteDeviceInfo, accept: (Bool) -> Void)] = []
    private var consentActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "QuickShare")
            button.toolTip = "QuickShare-Mac — Mac <> Android"
        }

        let menu = NSMenu()
        let title = NSMenuItem(title: "QuickShare-Mac", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let receive = NSMenuItem(title: "Receive Mode: OFF", action: #selector(toggleReceive), keyEquivalent: "r")
        receive.target = self
        menu.addItem(receive)
        receiveItem = receive

        let send = NSMenuItem(title: "Send to Android…", action: #selector(openSend), keyEquivalent: "s")
        send.target = self
        menu.addItem(send)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        prefsItem = prefs

        let recent = NSMenuItem(title: "Recent Transfers", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        recent.submenu = submenu
        recentMenu = submenu
        menu.addItem(recent)

        menu.addItem(.separator())
        let status = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit QuickShare-Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        refresh()
        if CommandLine.arguments.contains("--window-test") {
            WindowLifecycleTest.run(engine: engine)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleIncomingURLs(urls)
    }

    func handleIncomingURLs(_ urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "quickshare" {
            guard url.host?.lowercased() == "send" || url.path == "/send" else { continue }
            let files = handoffPaths(from: url).map { URL(fileURLWithPath: $0) }
            SendWindow.show(engine: engine, files: files)
        }
    }

    private func handoffPaths(from url: URL) -> [String] {
        guard let handoff = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "handoff" })?
            .value else { return [] }
        let handoffURL = URL(fileURLWithPath: handoff).standardizedFileURL
        let tmpDir = FileManager.default.temporaryDirectory.standardizedFileURL
        guard handoffURL.path.hasPrefix(tmpDir.path + "/") else { return [] }
        defer { try? FileManager.default.removeItem(at: handoffURL) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: handoffURL.path),
              let size = attrs[.size] as? NSNumber, size.intValue <= AppDelegate.maxHandoffBytes,
              let data = FileManager.default.contents(atPath: handoffURL.path),
              let payload = try? JSONDecoder().decode(SendHandoff.self, from: data) else { return [] }
        return payload.paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    @objc private func toggleReceive() {
        if engine.isReceiving {
            engine.stopReceiving()
        } else {
            engine.startReceiving()
        }
        refresh()
    }

    @objc private func openSend() {
        SendWindow.show(engine: engine)
    }

    @objc private func openPrefs() {
        PrefsWindow.show(engine: engine)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func refresh() {
        receiveItem?.title = engine.isReceiving ? "Receive Mode: ON" : "Receive Mode: OFF"
        statusLine?.title = engine.statusText
        rebuildRecent()
    }

    private func rebuildRecent() {
        recentMenu?.removeAllItems()
        let entries = HistoryStore.shared.entries.prefix(10)
        if entries.isEmpty {
            let item = NSMenuItem(title: "No transfers yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentMenu?.addItem(item)
            return
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        for e in entries {
            let arrow = e.direction == .sent ? "↑" : "↓"
            let item = NSMenuItem(title: "\(arrow) \(e.deviceName) — \(e.fileCount) file(s) — \(fmt.string(from: e.date))", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentMenu?.addItem(item)
        }
    }
}

extension AppDelegate: ShareEngineDelegate {
    func engineDidUpdateStatus() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func engineRequestsConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, accept: @escaping (Bool) -> Void) {
        consentQueue.append((transfer, device, accept))
        pumpConsent()
    }

    private func pumpConsent() {
        guard !consentActive, !consentQueue.isEmpty else { return }
        consentActive = true
        let item = consentQueue.removeFirst()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                item.accept(false)
                return
            }
            if item.transfer.files.isEmpty && item.transfer.textDescription == nil {
                item.accept(false)
                self.consentActive = false
                self.pumpConsent()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Incoming file from \(item.device.name)"
            let names: String
            if item.transfer.files.isEmpty {
                names = item.transfer.textDescription ?? "Shared text/link"
            } else {
                names = item.transfer.files.map { "\($0.name) (\($0.size) bytes)" }.joined(separator: "\n")
            }
            let when = DispatchTime.now() + 60
            alert.informativeText = "\(names)\n\nPIN: \(item.transfer.pinCode ?? "—")"
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Decline")
            var answered = false
            DispatchQueue.main.asyncAfter(deadline: when) {
                if !answered {
                    answered = true
                    NSApp.abortModal()
                    item.accept(false)
                    NearbyConnectionManager.shared.submitUserConsent(transferID: item.transfer.id, accept: false)
                    self.consentActive = false
                    self.pumpConsent()
                }
            }
            let resp = alert.runModal()
            if !answered {
                answered = true
                item.accept(resp == .alertFirstButtonReturn)
                self.consentActive = false
                self.pumpConsent()
            }
        }
    }
}
