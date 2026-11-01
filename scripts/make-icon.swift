import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/QuickShare.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func makeIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let s = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: s, height: s)

    NSColor.clear.setFill()
    bounds.fill()

    let back = NSBezierPath(
        roundedRect: NSRect(x: s * 0.06, y: s * 0.18, width: s * 0.88, height: s * 0.58),
        xRadius: s * 0.07,
        yRadius: s * 0.07
    )
    NSColor(srgbRed: 0.13, green: 0.55, blue: 0.85, alpha: 1).setFill()
    back.fill()

    let tab = NSBezierPath(
        roundedRect: NSRect(x: s * 0.06, y: s * 0.62, width: s * 0.40, height: s * 0.20),
        xRadius: s * 0.06,
        yRadius: s * 0.06
    )
    NSColor(srgbRed: 0.20, green: 0.60, blue: 0.90, alpha: 1).setFill()
    tab.fill()

    let front = NSBezierPath(
        roundedRect: NSRect(x: s * 0.06, y: s * 0.14, width: s * 0.88, height: s * 0.52),
        xRadius: s * 0.06,
        yRadius: s * 0.06
    )
    NSColor(srgbRed: 0.30, green: 0.68, blue: 0.95, alpha: 1).setFill()
    front.fill()

    let highlight = NSBezierPath(
        roundedRect: NSRect(x: s * 0.10, y: s * 0.16, width: s * 0.80, height: s * 0.08),
        xRadius: s * 0.03,
        yRadius: s * 0.03
    )
    NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.75).setFill()
    highlight.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in files {
    if let data = makeIcon(pixels: pixels) {
        try? data.write(to: URL(fileURLWithPath: outputDir).appendingPathComponent(name))
    }
}
