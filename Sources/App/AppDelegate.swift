import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var receiveItem: NSMenuItem?
    private var sendItem: NSMenuItem?
    private var statusLine: NSMenuItem?
    private var engine = ShareEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        engine.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "QuickShare")
            button.toolTip = "QuickShare — Mac <> Android"
        }

        let menu = NSMenu()
        let title = NSMenuItem(title: "QuickShare", action: nil, keyEquivalent: "")
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
        sendItem = send

        menu.addItem(.separator())
        let status = NSMenuItem(title: "Status: idle", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLine = status

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit QuickShare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopAll()
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

    private func refresh() {
        receiveItem?.title = engine.isReceiving ? "Receive Mode: ON" : "Receive Mode: OFF"
        statusLine?.title = engine.statusText
    }
}

extension AppDelegate: ShareEngineDelegate {
    func engineDidUpdateStatus() {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func engineRequestsConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, accept: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Incoming file from \(device.name)"
            let names = transfer.files.map { "\($0.name) (\($0.size) bytes)" }.joined(separator: "\n")
            alert.informativeText = "\(names)\n\nPIN: \(transfer.pinCode ?? "—")"
            alert.addButton(withTitle: "Accept")
            alert.addButton(withTitle: "Decline")
            let resp = alert.runModal()
            accept(resp == .alertFirstButtonReturn)
        }
    }
}
