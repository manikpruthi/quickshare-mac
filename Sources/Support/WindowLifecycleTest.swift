import AppKit
import Foundation

/// Exercises Send window open/close cycles plus the quickshare:// handoff path.
/// Run with `QuickShare-Mac --window-test`; exits non-zero on failure.
enum WindowLifecycleTest {
    static func run(engine: ShareEngine) {
        Task { @MainActor in
            var failures = 0
            func check(_ ok: Bool, _ name: String) {
                print(ok ? "PASS  \(name)" : "FAIL  \(name)")
                if !ok { failures += 1 }
            }

            for cycle in 1...5 {
                SendWindow.show(engine: engine)
                try? await Task.sleep(nanoseconds: 350_000_000)
                check(SendController.windowIsVisible, "cycle \(cycle): window opens with discovery")
                SendController.closeWindow()
                try? await Task.sleep(nanoseconds: 300_000_000)
                check(!SendController.windowIsVisible, "cycle \(cycle): window hides")
                check(NSApp.isRunning, "cycle \(cycle): app still running")
            }

            let early = FakeDeviceAdvertiser(name: "PixelEarly")
            early.publish(withTXT: true)
            try? await Task.sleep(nanoseconds: 900_000_000)
            SendWindow.show(engine: engine)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check(SendController.discoveredDeviceNames.contains("PixelEarly"), "device advertised before open is listed")
            SendController.closeWindow()
            try? await Task.sleep(nanoseconds: 300_000_000)
            early.stop()

            SendWindow.show(engine: engine)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let late = FakeDeviceAdvertiser(name: "PixelLate")
            late.publish(withTXT: false)
            try? await Task.sleep(nanoseconds: 800_000_000)
            late.updateTXT()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            check(SendController.discoveredDeviceNames.contains("PixelLate"), "device appearing after open is listed")
            SendController.closeWindow()
            try? await Task.sleep(nanoseconds: 300_000_000)
            late.stop()

            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShareWindowTest-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let html = directory.appendingPathComponent("network-vulnerability-report.html")
            try? Data("<html><body>report</body></html>".utf8).write(to: html)
            let handoff = directory.appendingPathComponent("handoff.json")
            try? JSONEncoder().encode(["paths": [html.path]]).write(to: handoff)

            var components = URLComponents()
            components.scheme = "quickshare"
            components.host = "send"
            components.queryItems = [URLQueryItem(name: "handoff", value: handoff.path)]
            if let url = components.url, let delegate = NSApp.delegate as? AppDelegate {
                delegate.handleIncomingURLs([url])
            } else {
                check(false, "handoff: deep link built")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            check(SendController.windowIsVisible, "handoff: send window opens")
            check(SendController.selectedFileCount == 1, "handoff: HTML file prefilled")
            SendController.closeWindow()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(!SendController.windowIsVisible, "handoff: window hides")
            check(NSApp.isRunning, "handoff: app still running")

            print(failures == 0 ? "\nWINDOW-TEST: PASS\n" : "\nWINDOW-TEST: FAIL\n")
            exit(failures == 0 ? 0 : 1)
        }
    }
}

private final class FakeDeviceAdvertiser: NSObject, NetServiceDelegate {
    private let service: NetService
    private let deviceName: String

    init(name: String) {
        deviceName = name
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let endpointID = String((0..<4).map { _ in alphabet.randomElement()! })
        let nameBytes: [UInt8] = [0x23] + Array(endpointID.utf8) + [0xFC, 0x9F, 0x5E, 0, 0]
        let encodedName = Data(nameBytes).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        service = NetService(domain: "local.", type: "_FC9F5ED42C8A._tcp.", name: encodedName, port: 12345)
        super.init()
        service.delegate = self
    }

    func publish(withTXT: Bool) {
        service.setTXTRecord(txtRecord(withTXT: withTXT))
        service.publish()
    }

    func updateTXT() {
        service.setTXTRecord(txtRecord(withTXT: true))
    }

    func stop() {
        service.stop()
    }

    private func txtRecord(withTXT: Bool) -> Data? {
        guard withTXT else { return NetService.data(fromTXTRecord: [:]) }
        var info: [UInt8] = [0x02]
        for _ in 0..<16 { info.append(UInt8.random(in: 0...255)) }
        let nameBytes = Array(deviceName.utf8)
        info.append(UInt8(min(nameBytes.count, 255)))
        info.append(contentsOf: nameBytes.prefix(255))
        let encoded = Data(info).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return NetService.data(fromTXTRecord: ["n": Data(encoded.utf8)])
    }
}
