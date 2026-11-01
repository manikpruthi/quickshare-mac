import AppKit
import Foundation

enum Screenshot {
    static func run(args: [String]) {
        let out: String
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            out = args[i + 1]
        } else {
            out = "/tmp/quickshare.png"
        }
        let w = SendWindowShot.make()
        w.orderFront(nil)
        NSApp.setActivationPolicy(.accessory)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        guard let shot = capture(window: w) else {
            print("screenshot failed")
            exit(1)
        }
        try? shot.write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }

    private static func capture(window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

enum SendWindowShot {
    static func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Send to Android"
        w.center()
        let label = NSTextField(labelWithString: "Open Quick Share on the Android phone so it appears here, or scan the QR code below.")
        label.frame = NSRect(x: 20, y: 566, width: 440, height: 44)
        label.lineBreakMode = .byWordWrapping
        w.contentView?.addSubview(label)
        let devLabel = NSTextField(labelWithString: "Nearby Android devices:")
        devLabel.frame = NSRect(x: 20, y: 504, width: 440, height: 20)
        w.contentView?.addSubview(devLabel)
        let list = NSTextField(labelWithString: "Searching for nearby Android devices…")
        list.frame = NSRect(x: 20, y: 352, width: 440, height: 146)
        list.lineBreakMode = .byWordWrapping
        w.contentView?.addSubview(list)
        let qrLabel = NSTextField(labelWithString: "Scan with the Android phone to connect instantly:")
        qrLabel.frame = NSRect(x: 20, y: 228, width: 440, height: 20)
        w.contentView?.addSubview(qrLabel)
        let qrView = NSImageView(frame: NSRect(x: 20, y: 58, width: 160, height: 160))
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.image = qrImage(from: "https://quickshare.google/qrcode#key=PREVIEW", size: 160)
        w.contentView?.addSubview(qrView)
        return w
    }
}
