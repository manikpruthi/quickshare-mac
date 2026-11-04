import AppKit
import CoreImage
import Foundation

/// Renders a scannable QR code using CoreImage's built-in generator.
/// Shared with SelfTest so the render path is covered without a display.
private let sharedQRContext = CIContext(options: [.cacheIntermediates: false])

func qrImage(from string: String, size: CGFloat) -> NSImage? {
    guard let data = string.data(using: .utf8),
          let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(data, forKey: "inputMessage")
    filter.setValue("H", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scale = size / output.extent.width
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let cg = sharedQRContext.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
}

final class SendWindow: NSObject {
    static func show(engine: ShareEngine, files: [URL] = []) {
        _ = engine
        SendController.show(files: files)
    }
}

final class SendController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, ShareExtensionDelegate, NSDraggingDestination {
    private static var shared: SendController?

    private var window: NSWindow?
    private var devices: [RemoteDeviceInfo] = []
    private var selectedURLs: [URL] = []
    private var stagedZips: [URL] = []
    private var selectedFiles: [URL] = []
    private var currentDeviceID: String?
    private var messageText: String = ""
    private var sendMode: SendMode = .files
    private var isTornDown = true
    private var didRegisterDelegate = false
    private var didStartDiscovery = false
    private var reloadWorkItem: DispatchWorkItem?
    private var transferStart: Date?
    private var lastProgressAt = Date()
    private var lastProgressValue = 0.0

    private enum SendMode { case files, message }

    private var tableView: NSTableView!
    private var fileListView: NSTableView!
    private var fileCountLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var pinLabel: NSTextField!
    private var progressBar: NSProgressIndicator!
    private var speedLabel: NSTextField!
    private var qrImageView: NSImageView!
    private var qrLinkField: NSTextField!
    private var qrURL: String = ""
    private var qrCacheKey: String = ""
    private var sendButton: NSButton?
    private var doneButton: NSButton?
    private var messageField: NSTextField?
    private var modeSeg: NSSegmentedControl?

    static func show(files: [URL] = []) {
        if let controller = shared {
            controller.present(files: files)
        } else {
            let controller = SendController()
            shared = controller
            controller.openWindow(files: files)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static var screenshotWindow: NSWindow? { shared?.window }

    static var windowIsVisible: Bool { shared?.window?.isVisible ?? false }

    static var selectedFileCount: Int { shared?.selectedURLs.count ?? 0 }

    static var discoveredDeviceNames: [String] { shared?.devices.map(\.name) ?? [] }

    static func closeWindow() {
        shared?.window?.close()
    }

    private func openWindow(files: [URL]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Send to Android"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildViews(into: window)
        self.window = window
        activateDiscovery()
        resetTransferUI()
        if !files.isEmpty {
            setSelectedFiles(files)
        }
        refreshQR()
        setStatus(devices.isEmpty ? "Searching for nearby Android devices…" : "\(devices.count) device(s) nearby — pick one and press Send")
        window.makeKeyAndOrderFront(nil)
    }

    private func present(files: [URL]) {
        isTornDown = false
        activateDiscovery()
        resetTransferUI()
        if !files.isEmpty {
            setSelectedFiles(files)
        }
        refreshQR()
        setStatus(devices.isEmpty ? "Searching for nearby Android devices…" : "\(devices.count) device(s) nearby — pick one and press Send")
        window?.makeKeyAndOrderFront(nil)
    }

    private func activateDiscovery() {
        isTornDown = false
        if !didRegisterDelegate {
            NearbyConnectionManager.shared.addShareExtensionDelegate(self)
            didRegisterDelegate = true
        }
        if !didStartDiscovery {
            NearbyConnectionManager.shared.startDeviceDiscovery()
            didStartDiscovery = true
        }
    }

    private func buildViews(into window: NSWindow) {
        guard let content = window.contentView else { return }
        content.registerForDraggedTypes([.fileURL, .URL, .string])

        let instruction = NSTextField(labelWithString: "Open Quick Share on the Android phone so it appears here, or scan the QR code below. Drag files onto this window too.")
        instruction.frame = NSRect(x: 20, y: 646, width: 440, height: 44)
        instruction.lineBreakMode = .byWordWrapping
        content.addSubview(instruction)

        let seg = NSSegmentedControl(labels: ["Files", "Message"], trackingMode: .selectOne, target: self, action: #selector(switchMode(_:)))
        seg.frame = NSRect(x: 20, y: 612, width: 200, height: 24)
        seg.selectedSegment = 0
        content.addSubview(seg)
        modeSeg = seg

        fileCountLabel = NSTextField(labelWithString: "No files chosen")
        fileCountLabel.frame = NSRect(x: 20, y: 586, width: 280, height: 22)
        content.addSubview(fileCountLabel)

        let chooseButton = NSButton(title: "Choose Files…", target: self, action: #selector(pickFiles))
        chooseButton.frame = NSRect(x: 310, y: 580, width: 150, height: 32)
        chooseButton.bezelStyle = .rounded
        content.addSubview(chooseButton)

        let fileScroll = NSScrollView(frame: NSRect(x: 20, y: 500, width: 440, height: 80))
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder
        fileListView = NSTableView(frame: fileScroll.bounds)
        let fcol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        fcol.title = "Selected"
        fcol.width = 430
        fileListView.addTableColumn(fcol)
        fileListView.headerView = nil
        fileListView.dataSource = self
        fileListView.delegate = self
        fileScroll.documentView = fileListView
        content.addSubview(fileScroll)

        messageField = NSTextField(string: "")
        messageField?.frame = NSRect(x: 20, y: 500, width: 440, height: 80)
        messageField?.placeholderString = "Type a link or message to send…"
        messageField?.isHidden = true
        if let mf = messageField { content.addSubview(mf) }

        let devLabel = NSTextField(labelWithString: "Nearby Android devices:")
        devLabel.frame = NSRect(x: 20, y: 474, width: 440, height: 20)
        content.addSubview(devLabel)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 352, width: 440, height: 116))
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

        speedLabel = NSTextField(labelWithString: "")
        speedLabel.frame = NSRect(x: 20, y: 236, width: 440, height: 18)
        speedLabel.font = NSFont.systemFont(ofSize: 11)
        speedLabel.textColor = .secondaryLabelColor
        content.addSubview(speedLabel)

        qrImageView = NSImageView(frame: NSRect(x: 20, y: 68, width: 160, height: 160))
        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(qrImageView)

        qrLinkField = NSTextField(labelWithString: "")
        qrLinkField.frame = NSRect(x: 192, y: 138, width: 268, height: 90)
        qrLinkField.lineBreakMode = .byWordWrapping
        qrLinkField.maximumNumberOfLines = 4
        qrLinkField.isSelectable = true
        content.addSubview(qrLinkField)

        let copyButton = NSButton(title: "Copy Link", target: self, action: #selector(copyLink))
        copyButton.frame = NSRect(x: 192, y: 98, width: 150, height: 30)
        copyButton.bezelStyle = .rounded
        content.addSubview(copyButton)

        let qrLabel = NSTextField(labelWithString: "Scan with the Android phone to connect instantly:")
        qrLabel.frame = NSRect(x: 20, y: 44, width: 440, height: 20)
        content.addSubview(qrLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 18, width: 440, height: 24)
        content.addSubview(statusLabel)
    }

    // MARK: - Window lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        beginTeardown()
        DispatchQueue.main.async { [weak self] in self?.finishTeardown() }
        return false
    }

    private func beginTeardown() {
        guard !isTornDown else { return }
        isTornDown = true
        if let id = currentDeviceID {
            NearbyConnectionManager.shared.cancelOutgoingTransfer(id: id)
            currentDeviceID = nil
        }
        cleanupStagedZips()
        progressBar?.stopAnimation(nil)
        progressBar?.isIndeterminate = false
        if didRegisterDelegate {
            NearbyConnectionManager.shared.removeShareExtensionDelegate(self)
            didRegisterDelegate = false
        }
        if didStartDiscovery {
            NearbyConnectionManager.shared.stopDeviceDiscovery()
            didStartDiscovery = false
        }
        NearbyConnectionManager.shared.clearQrCodeKey()
        qrCacheKey = ""
        devices.removeAll()
        tableView?.reloadData()
        window?.orderOut(nil)
    }

    private func finishTeardown() {
        guard isTornDown, let window else { return }
        window.delegate = nil
        self.window = nil
        if SendController.shared === self {
            SendController.shared = nil
        }
    }

    private func resetTransferUI() {
        currentDeviceID = nil
        transferStart = nil
        lastProgressValue = 0
        progressBar?.stopAnimation(nil)
        progressBar?.isIndeterminate = false
        progressBar?.doubleValue = 0
        speedLabel?.stringValue = ""
        pinLabel?.stringValue = ""
        sendButton?.isHidden = false
        doneButton?.isHidden = true
        setStatus("Searching for nearby Android devices…")
    }

    private func cleanupStagedZips() {
        for url in stagedZips {
            try? FileManager.default.removeItem(at: url)
        }
        stagedZips.removeAll()
    }

    private func setSelectedFiles(_ urls: [URL]) {
        var expanded: [URL] = []
        for url in urls {
            var isDir = ObjCBool(false)
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let zip = zipDirectory(url) {
                    stagedZips.append(zip)
                    expanded.append(zip)
                }
            } else if FileManager.default.fileExists(atPath: url.path) {
                expanded.append(url)
            }
        }
        selectedURLs = expanded
        selectedFiles = expanded
        fileListView?.reloadData()
        fileCountLabel?.stringValue = selectedURLs.isEmpty
            ? "No files chosen"
            : "\(selectedURLs.count) file(s) chosen"
        if !selectedURLs.isEmpty {
            setStatus("Now pick a device and press Send")
        }
    }

    private func zipDirectory(_ dir: URL) -> URL? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShare-\(UUID().uuidString).zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--sequesterRsrc", dir.path, tmp.path]
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        return tmp
    }

    private func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    private func refreshQR() {
        let key = NearbyConnectionManager.shared.generateQrCodeKey()
        if key == qrCacheKey, qrImageView?.image != nil { return }
        qrCacheKey = key
        qrURL = "https://quickshare.google/qrcode#key=\(key)"
        qrImageView?.image = qrImage(from: qrURL, size: 160)
        qrLinkField?.stringValue = qrURL
    }

    @objc private func switchMode(_ sender: NSSegmentedControl) {
        sendMode = sender.selectedSegment == 1 ? .message : .files
        messageField?.isHidden = sendMode == .files
        fileListView?.enclosingScrollView?.isHidden = sendMode == .message
    }

    @objc private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        setSelectedFiles(panel.urls)
        setStatus("Now pick a device and press Send")
    }

    @objc private func send() {
        let row = tableView.selectedRow
        guard row >= 0, row < devices.count else {
            setStatus("Pick a device from the list first")
            return
        }
        guard let id = devices[row].id else {
            setStatus("That device is not ready yet — wait a moment")
            return
        }
        if sendMode == .message {
            guard let text = messageField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                setStatus("Type a message or link first")
                return
            }
            messageText = text
        } else {
            guard !selectedURLs.isEmpty else {
                setStatus("Choose files first")
                return
            }
        }
        beginTransfer(deviceID: id)
    }

    private func beginTransfer(deviceID: String) {
        currentDeviceID = deviceID
        transferStart = Date()
        lastProgressAt = Date()
        lastProgressValue = 0
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        pinLabel.stringValue = ""
        setStatus("Connecting… confirm the PIN on both screens")
        let urls: [URL]
        if sendMode == .message, let url = URL(string: messageText), url.scheme == "http" || url.scheme == "https" {
            urls = [url]
        } else if sendMode == .message {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("QuickShare-msg-\(UUID().uuidString).txt")
            guard (try? messageText.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
                setStatus("Could not stage message")
                return
            }
            stagedZips.append(tmp)
            selectedURLs = [tmp]
            urls = [tmp]
        } else {
            urls = selectedURLs
        }
        NearbyConnectionManager.shared.startOutgoingTransfer(deviceID: deviceID, delegate: self, urls: urls)
    }

    @objc private func copyLink() {
        guard !qrURL.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qrURL, forType: .string)
        setStatus("Link copied — open it on the phone if the camera won't scan")
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === fileListView {
            return selectedFiles.count
        }
        return devices.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView === fileListView {
            guard row >= 0, row < selectedFiles.count else { return nil }
            return selectedFiles[row].lastPathComponent
        }
        guard row >= 0, row < devices.count else { return nil }
        let device = devices[row]
        return "\(device.name) (\(deviceTypeLabel(device.type)))"
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cellID = NSUserInterfaceItemIdentifier(tableView === fileListView ? "FileCell" : "DeviceCell")
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
        if tableView === fileListView {
            if row >= 0, row < selectedFiles.count {
                cell?.textField?.stringValue = selectedFiles[row].lastPathComponent
            }
        } else if row >= 0, row < devices.count {
            let device = devices[row]
            cell?.textField?.stringValue = "\(device.name) (\(deviceTypeLabel(device.type)))"
        }
        return cell
    }

    // MARK: - NSDraggingDestination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            sendMode = .files
            modeSeg?.selectedSegment = 0
            switchModeForDrag(files: true)
            setSelectedFiles(urls)
            return true
        }
        if let strings = pb.readObjects(forClasses: [NSString.self], options: nil) as? [String],
           let first = strings.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            sendMode = .message
            modeSeg?.selectedSegment = 1
            switchModeForDrag(files: false)
            messageField?.stringValue = first
            return true
        }
        return false
    }

    private func switchModeForDrag(files: Bool) {
        messageField?.isHidden = files
        fileListView?.enclosingScrollView?.isHidden = !files
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            if let id = device.id {
                guard !self.devices.contains(where: { $0.id == id }) else { return }
            }
            self.devices.append(device)
            self.scheduleReload()
            self.setStatus("\(self.devices.count) device(s) nearby — pick one and press Send")
        }
    }

    func removeDevice(id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.devices.removeAll { $0.id == id }
            self.scheduleReload()
            if self.devices.isEmpty {
                self.setStatus("Searching for nearby Android devices…")
            }
        }
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.tableView?.reloadData()
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func startTransferWithQrCode(device: RemoteDeviceInfo) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
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
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.progressBar?.stopAnimation(nil)
            self.progressBar?.isIndeterminate = false
            self.progressBar?.doubleValue = 0
            self.pinLabel?.stringValue = "Confirm on phone — PIN: \(pinCode)"
            self.setStatus("Connected — waiting for the phone to accept…")
        }
    }

    func connectionFailed(with error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.progressBar?.stopAnimation(nil)
            self.progressBar?.isIndeterminate = false
            self.currentDeviceID = nil
            self.pinLabel?.stringValue = ""
            self.setStatus("Failed: \(error.localizedDescription)")
        }
    }

    func transferAccepted() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.transferStart = Date()
            self.setStatus("Accepted — sending…")
        }
    }

    func transferProgress(progress: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            let now = Date()
            let dt = now.timeIntervalSince(self.lastProgressAt)
            if dt >= 0.5 {
                let dp = progress - self.lastProgressValue
                let total = self.estimatedTotalBytes
                let bps = total > 0 ? dp * Double(total) / max(dt, 0.01) : 0
                if bps > 0 {
                    let remaining = total > 0 ? Double(total) * (1 - progress) / bps : 0
                    self.speedLabel?.stringValue = "\(Self.formatBytes(bps))/s — ETA \(Self.formatETA(remaining))"
                }
                self.lastProgressAt = now
                self.lastProgressValue = progress
            }
            self.progressBar?.doubleValue = progress * 100
            self.setStatus(String(format: "Sending… %.0f%%", progress * 100))
        }
    }

    private var estimatedTotalBytes: Int64 {
        var total: Int64 = 0
        for url in selectedURLs {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber {
                total += size.int64Value
            }
        }
        return total
    }

    private static func formatBytes(_ bps: Double) -> String {
        if bps >= 1_000_000_000 { return String(format: "%.1f GB", bps / 1_000_000_000) }
        if bps >= 1_000_000 { return String(format: "%.1f MB", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB", bps / 1_000) }
        return String(format: "%.0f B", bps)
    }

    private static func formatETA(_ s: Double) -> String {
        if s.isNaN || s.isInfinite { return "—" }
        if s < 60 { return "\(Int(s))s" }
        return "\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s"
    }

    func transferFinished() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isTornDown else { return }
            self.cleanupStagedZips()
            self.selectedFiles.removeAll()
            self.fileListView?.reloadData()
            self.fileCountLabel?.stringValue = "No files chosen"
            self.progressBar?.stopAnimation(nil)
            self.progressBar?.isIndeterminate = false
            self.progressBar?.doubleValue = 100
            self.speedLabel?.stringValue = ""
            self.pinLabel?.stringValue = ""
            self.currentDeviceID = nil
            self.setStatus("Complete — files delivered to the Android phone")
            self.sendButton?.isHidden = true
            self.doneButton?.isHidden = false
            if let doneButton = self.doneButton {
                self.window?.makeFirstResponder(doneButton)
            }
        }
    }

    @objc private func done() {
        SendController.closeWindow()
    }
}
