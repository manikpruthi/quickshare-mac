import AppKit
import CoreImage
import Foundation

/// Renders a scannable QR code using CoreImage's built-in generator.
/// Shared with SelfTest so the render path is covered without a display.
func qrImage(from string: String, size: CGFloat) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(rep)
    return image
}

final class SendWindow: NSObject {
    static func show(engine: ShareEngine) {
        _ = engine
        SendController.show()
    }
}

final class SendController: NSObject, NSTableViewDataSource, NSTableViewDelegate, ShareExtensionDelegate {
    private static var shared: SendController?

    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var devices: [RemoteDeviceInfo] = []
    private var selectedURLs: [URL] = []
    private var currentDeviceID: String?

    private var tableView: NSTableView!
    private var fileCountLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var pinLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var qrImageView: NSImageView!
    private var qrLinkField: NSTextField!
    private var qrURL: String = ""
    private var sendButton: NSButton?
    private var cancelButton: NSButton?
    private var doneButton: NSButton?

    static func show() {
        NSApp.setActivationPolicy(.regular)
        if shared == nil {
            let controller = SendController()
            shared = controller
            controller.openWindow()
        } else {
            shared?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static var screenshotWindow: NSWindow? { shared?.window }

    static func closeWindow() {
        shared?.window?.close()
    }

    private func openWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Send to Android"
        window.center()
        buildViews(into: window)
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.teardown() }
        NearbyConnectionManager.shared.addShareExtensionDelegate(self)
        NearbyConnectionManager.shared.startDeviceDiscovery()
        refreshQR()
        setStatus("Searching for nearby Android devices…")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildViews(into window: NSWindow) {
        guard let content = window.contentView else { return }

        let instruction = NSTextField(labelWithString: "Open Quick Share on the Android phone so it appears here, or scan the QR code below.")
        instruction.frame = NSRect(x: 20, y: 566, width: 440, height: 44)
        instruction.lineBreakMode = .byWordWrapping
        content.addSubview(instruction)

        fileCountLabel = NSTextField(labelWithString: "No files chosen")
        fileCountLabel.frame = NSRect(x: 20, y: 536, width: 280, height: 22)
        content.addSubview(fileCountLabel)

        let chooseButton = NSButton(title: "Choose Files…", target: self, action: #selector(pickFiles))
        chooseButton.frame = NSRect(x: 310, y: 530, width: 150, height: 32)
        chooseButton.bezelStyle = .rounded
        content.addSubview(chooseButton)

        let devLabel = NSTextField(labelWithString: "Nearby Android devices:")
        devLabel.frame = NSRect(x: 20, y: 504, width: 440, height: 20)
        content.addSubview(devLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 352, width: 440, height: 146))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tableView = NSTableView(frame: scroll.bounds)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("device"))
        column.title = "Device"
        column.width = 430
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(deviceDoubleClicked)
        scroll.documentView = tableView
        content.addSubview(scroll)

        sendButton = NSButton(title: "Send", target: self, action: #selector(send))
        sendButton?.frame = NSRect(x: 20, y: 312, width: 150, height: 32)
        sendButton?.bezelStyle = .rounded
        sendButton?.keyEquivalent = "\r"
        content.addSubview(sendButton!)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTransfer))
        cancelButton?.frame = NSRect(x: 180, y: 312, width: 110, height: 32)
        cancelButton?.bezelStyle = .rounded
        content.addSubview(cancelButton!)

        doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton?.frame = NSRect(x: 20, y: 312, width: 150, height: 32)
        doneButton?.bezelStyle = .rounded
        doneButton?.keyEquivalent = "\r"
        doneButton?.isHidden = true
        content.addSubview(doneButton!)

        pinLabel = NSTextField(labelWithString: "")
        pinLabel.frame = NSRect(x: 20, y: 282, width: 440, height: 24)
        pinLabel.font = NSFont.boldSystemFont(ofSize: 13)
        content.addSubview(pinLabel)

        progressBar = NSProgressIndicator(frame: NSRect(x: 20, y: 258, width: 440, height: 16))
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false
        content.addSubview(progressBar)

        let qrLabel = NSTextField(labelWithString: "Scan with the Android phone to connect instantly:")
        qrLabel.frame = NSRect(x: 20, y: 228, width: 440, height: 20)
        content.addSubview(qrLabel)

        qrImageView = NSImageView(frame: NSRect(x: 20, y: 58, width: 160, height: 160))
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(qrImageView)

        qrLinkField = NSTextField(labelWithString: "")
        qrLinkField.frame = NSRect(x: 192, y: 118, width: 268, height: 92)
        qrLinkField.lineBreakMode = .byWordWrapping
        qrLinkField.isSelectable = true
        content.addSubview(qrLinkField)

        let copyButton = NSButton(title: "Copy Link", target: self, action: #selector(copyLink))
        copyButton.frame = NSRect(x: 192, y: 58, width: 150, height: 30)
        copyButton.bezelStyle = .rounded
        content.addSubview(copyButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 18, width: 440, height: 24)
        content.addSubview(statusLabel)
    }

    private func teardown() {
        NearbyConnectionManager.shared.stopDeviceDiscovery()
        NearbyConnectionManager.shared.clearQrCodeKey()
        NearbyConnectionManager.shared.removeShareExtensionDelegate(self)
        NSApp.setActivationPolicy(.accessory)
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        window = nil
        SendController.shared = nil
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    private func refreshQR() {
        let key = NearbyConnectionManager.shared.generateQrCodeKey()
        qrURL = "https://quickshare.google/qrcode#key=\(key)"
        qrImageView?.image = qrImage(from: qrURL, size: 160)
        qrLinkField?.stringValue = qrURL
    }

    @objc private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        selectedURLs = panel.urls
        fileCountLabel?.stringValue = "\(selectedURLs.count) file(s) chosen"
        setStatus("Now pick a device and press Send")
    }

    @objc private func send() {
        let row = tableView.selectedRow
        guard row >= 0, row < devices.count else {
            setStatus("Pick a device from the list first")
            return
        }
        guard !selectedURLs.isEmpty else {
            setStatus("Choose files first")
            return
        }
        guard let id = devices[row].id else {
            setStatus("That device is not ready yet — wait a moment")
            return
        }
        beginTransfer(deviceID: id)
    }

    private func beginTransfer(deviceID: String) {
        currentDeviceID = deviceID
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        pinLabel.stringValue = ""
        setStatus("Connecting… confirm the PIN on both screens")
        NearbyConnectionManager.shared.startOutgoingTransfer(deviceID: deviceID, delegate: self, urls: selectedURLs)
    }

    @objc private func cancelTransfer() {
        if let id = currentDeviceID {
            NearbyConnectionManager.shared.cancelOutgoingTransfer(id: id)
            currentDeviceID = nil
        }
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.doubleValue = 0
        pinLabel.stringValue = ""
        setStatus("Cancelled")
    }

    @objc private func copyLink() {
        guard !qrURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qrURL, forType: .string)
        setStatus("Link copied — open it on the phone if the camera won't scan")
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        devices.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < devices.count else { return nil }
        let device = devices[row]
        return "\(device.name) (\(deviceTypeLabel(device.type)))"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier("DeviceCell")
        var cell = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = cellID
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell?.addSubview(field)
            cell?.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }
        if row >= 0, row < devices.count {
            let device = devices[row]
            cell?.textField?.stringValue = "\(device.name) (\(deviceTypeLabel(device.type)))"
        }
        return cell
    }

    @objc private func deviceDoubleClicked() {
        send()
    }

    private func deviceTypeLabel(_ type: RemoteDeviceInfo.DeviceType) -> String {
        switch type {
        case .phone: return "phone"
        case .tablet: return "tablet"
        case .computer: return "computer"
        case .unknown: return "device"
        }
    }

    // MARK: - ShareExtensionDelegate

    func addDevice(device: RemoteDeviceInfo) {
        DispatchQueue.main.async {
            if let id = device.id {
                guard !self.devices.contains(where: { $0.id == id }) else { return }
            }
            self.devices.append(device)
            self.tableView.reloadData()
            self.setStatus("\(self.devices.count) device(s) nearby — pick one and press Send")
        }
    }

    func removeDevice(id: String) {
        DispatchQueue.main.async {
            self.devices.removeAll { $0.id == id }
            self.tableView.reloadData()
            if self.devices.isEmpty {
                self.setStatus("Searching for nearby Android devices…")
            }
        }
    }

    func startTransferWithQrCode(device: RemoteDeviceInfo) {
        DispatchQueue.main.async {
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            guard let id = device.id else { return }
            if self.selectedURLs.isEmpty {
                self.setStatus("Phone found via QR — choose files, then press Send")
            } else {
                self.setStatus("Phone found via QR — sending…")
                self.beginTransfer(deviceID: id)
            }
        }
    }

    func connectionWasEstablished(pinCode: String) {
        DispatchQueue.main.async {
            self.progressBar.stopAnimation(nil)
            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = 0
            self.pinLabel.stringValue = "Confirm on phone — PIN: \(pinCode)"
            self.setStatus("Connected — waiting for the phone to accept…")
        }
    }

    func connectionFailed(with error: Error) {
        DispatchQueue.main.async {
            self.progressBar.stopAnimation(nil)
            self.progressBar.isIndeterminate = false
            self.currentDeviceID = nil
            self.pinLabel.stringValue = ""
            self.setStatus("Failed: \(error.localizedDescription)")
        }
    }

    func transferAccepted() {
        DispatchQueue.main.async {
            self.setStatus("Accepted — sending…")
        }
    }

    func transferProgress(progress: Double) {
        DispatchQueue.main.async {
            self.progressBar.doubleValue = progress * 100
            self.setStatus(String(format: "Sending… %.0f%%", progress * 100))
        }
    }

    func transferFinished() {
        DispatchQueue.main.async {
            self.progressBar.stopAnimation(nil)
            self.progressBar.isIndeterminate = false
            self.progressBar.doubleValue = 100
            self.pinLabel.stringValue = ""
            self.currentDeviceID = nil
            self.setStatus("Complete — files delivered to the Android phone")
            self.sendButton?.isHidden = true
            self.cancelButton?.isHidden = true
            self.doneButton?.isHidden = false
            self.window?.makeFirstResponder(self.doneButton)
        }
    }

    @objc private func done() {
        SendController.closeWindow()
    }
}
