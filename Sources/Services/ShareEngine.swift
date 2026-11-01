import Foundation
import AppKit
import UserNotifications

protocol ShareEngineDelegate: AnyObject {
    func engineDidUpdateStatus()
    func engineRequestsConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, accept: @escaping (Bool) -> Void)
}

final class ShareEngine: NSObject {
    weak var delegate: ShareEngineDelegate?
    private(set) var isReceiving = false
    private var prefs = QSPreferences.load()
    private var autoOffWorkItem: DispatchWorkItem?

    var statusText: String {
        isReceiving ? "Status: discoverable by Android" : "Status: idle"
    }

    var preferences: QSPreferences { prefs }

    override init() {
        super.init()
        NearbyConnectionManager.shared.mainAppDelegate = self
        prefs = QSPreferences.load()
    }

    func startReceiving() {
        guard !isReceiving else { return }
        prefs = QSPreferences.load()
        NearbyConnectionManager.shared.becomeVisible()
        isReceiving = true
        scheduleAutoOff()
        delegate?.engineDidUpdateStatus()
    }

    func stopReceiving() {
        guard isReceiving else { return }
        NearbyConnectionManager.shared.stopVisible()
        NearbyConnectionManager.shared.clearQrCodeKey()
        autoOffWorkItem?.cancel()
        autoOffWorkItem = nil
        isReceiving = false
        delegate?.engineDidUpdateStatus()
    }

    func stopAll() {
        autoOffWorkItem?.cancel()
        autoOffWorkItem = nil
        if isReceiving {
            NearbyConnectionManager.shared.stopVisible()
            NearbyConnectionManager.shared.clearQrCodeKey()
            isReceiving = false
        }
    }

    func reloadPreferences() {
        let wasReceiving = isReceiving
        prefs = QSPreferences.load()
        if wasReceiving {
            NearbyConnectionManager.shared.stopVisible()
            NearbyConnectionManager.shared.becomeVisible()
            scheduleAutoOff()
        }
        delegate?.engineDidUpdateStatus()
    }

    private func scheduleAutoOff() {
        autoOffWorkItem?.cancel()
        autoOffWorkItem = nil
        let minutes = QSPreferences.load().autoOffMinutes
        guard minutes > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.stopReceiving()
        }
        autoOffWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(minutes * 60), execute: item)
    }
}

extension ShareEngine: MainAppDelegate {
    func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
        if QSPreferences.load().autoAcceptKnown {
            NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: true)
            return
        }
        delegate?.engineRequestsConsent(for: transfer, from: device) { accept in
            NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: accept)
        }
    }

    func incomingTransfer(id: String, didFinishWith error: Error?, files: [URL]) {
        if error == nil, !files.isEmpty {
            HistoryStore.shared.record(direction: .received, deviceName: nil, fileCount: files.count, bytes: -1, success: true)
            notifyReceived(files: files)
        }
        delegate?.engineDidUpdateStatus()
    }

    private func notifyReceived(files: [URL]) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        if files.count == 1 {
            content.title = "Received \(files[0].lastPathComponent)"
        } else {
            content.title = "Received \(files.count) files"
        }
        content.body = "Saved to \(QSPreferences.load().destination.lastPathComponent)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(req)
    }
}
