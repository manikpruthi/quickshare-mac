import AppKit
import Foundation

enum Screenshot {
    static func run(args: [String]) {
        _ = NSApplication.shared
        let out: String
        if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count {
            out = args[i + 1]
        } else {
            out = "/tmp/quickshare.png"
        }
        SendController.show()
        if let window = SendController.screenshotWindow {
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        guard let window = SendController.screenshotWindow, let shot = capture(window: window) else {
            print("screenshot failed")
            exit(1)
        }
        try? shot.write(to: URL(fileURLWithPath: out))
        SendController.closeWindow()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
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
