import Foundation
import AppKit

protocol ShareEngineDelegate: AnyObject {
    func engineDidUpdateStatus()
    func engineRequestsConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo, accept: @escaping (Bool) -> Void)
}

final class ShareEngine: NSObject {
    weak var delegate: ShareEngineDelegate?
    private(set) var isReceiving = false

    var statusText: String {
        isReceiving ? "Status: discoverable by Android" : "Status: idle"
    }

    override init() {
        super.init()
        NearbyConnectionManager.shared.mainAppDelegate = self
    }

    func startReceiving() {
        guard !isReceiving else { return }
        NearbyConnectionManager.shared.becomeVisible()
        isReceiving = true
        delegate?.engineDidUpdateStatus()
    }

    func stopReceiving() {
        NearbyConnectionManager.shared.stopVisible()
        isReceiving = false
        delegate?.engineDidUpdateStatus()
    }

    func stopAll() {
        isReceiving = false
    }
}

extension ShareEngine: MainAppDelegate {
    func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
        delegate?.engineRequestsConsent(for: transfer, from: device) { accept in
            NearbyConnectionManager.shared.submitUserConsent(transferID: transfer.id, accept: accept)
        }
    }

    func incomingTransfer(id: String, didFinishWith error: Error?) {
        delegate?.engineDidUpdateStatus()
    }
}
