import AppKit
import Foundation

final class SendWindow: NSObject {
    private static var window: NSWindow?
    private static var engine: ShareEngine?
    private static var deviceList: NSTextField?
    private static var qrField: NSTextField?

    static func show(engine: ShareEngine) {
        Self.engine = engine
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Send to Android"
            w.center()

            let label = NSTextField(labelWithString: "Open Quick Share on the Android phone so it appears here, or scan the QR code below.")
            label.frame = NSRect(x: 20, y: 320, width: 420, height: 40)
            label.lineBreakMode = .byWordWrapping
            w.contentView?.addSubview(label)

            let list = NSTextField(labelWithString: "Searching for nearby Android devices…")
            list.frame = NSRect(x: 20, y: 250, width: 420, height: 60)
            list.lineBreakMode = .byWordWrapping
            w.contentView?.addSubview(list)
            deviceList = list

            let qr = NSTextField(labelWithString: "")
            qr.frame = NSRect(x: 20, y: 120, width: 420, height: 110)
            qr.lineBreakMode = .byWordWrapping
            qr.isSelectable = true
            w.contentView?.addSubview(qr)
            qrField = qr

            let sendButton = NSButton(title: "Choose Files…", target: self, action: #selector(pickFiles))
            sendButton.frame = NSRect(x: 20, y: 20, width: 140, height: 32)
            sendButton.bezelStyle = .rounded
            w.contentView?.addSubview(sendButton)

            let qrButton = NSButton(title: "Show QR Code", target: self, action: #selector(showQR))
            qrButton.frame = NSRect(x: 170, y: 20, width: 140, height: 32)
            qrButton.bezelStyle = .rounded
            w.contentView?.addSubview(qrButton)

            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                NearbyConnectionManager.shared.stopDeviceDiscovery()
                NearbyConnectionManager.shared.clearQrCodeKey()
                NSApp.setActivationPolicy(.accessory)
                window = nil
            }
            window = w
        }
        NearbyConnectionManager.shared.startDeviceDiscovery()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private static func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        deviceList?.stringValue = "Selected \(panel.urls.count) file(s). Pick a device once it appears…"
    }

    @objc private static func showQR() {
        let key = NearbyConnectionManager.shared.generateQrCodeKey()
        let url = "https://quickshare.google/qrcode#key=\(key)"
        qrField?.stringValue = "Scan with the Android phone:\n\(url)"
    }
}
