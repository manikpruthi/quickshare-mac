import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/QuickShare-Mac.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// Matches the menu-bar icon: arrow.left.arrow.right.circle — two opposing
// arrows inside a circle, drawn in the same blue family.
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

    let blue = NSColor(srgbRed: 0.13, green: 0.55, blue: 0.85, alpha: 1)
    let deepBlue = NSColor(srgbRed: 0.08, green: 0.42, blue: 0.70, alpha: 1)

    let circle = NSBezierPath(ovalIn: NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88))
    let gradient = NSGradient(colors: [blue, deepBlue])
    gradient?.draw(in: circle, angle: -90)
    blue.setStroke()
    circle.lineWidth = max(1, s * 0.012)
    circle.stroke()

    NSColor.white.setFill()
    let barH = s * 0.11
    let arrowLen = s * 0.52
    let headW = s * 0.16
    let headH = s * 0.24
    let cx = s * 0.5

    let rightBar = NSBezierPath(rect: NSRect(x: cx - arrowLen / 2, y: s * 0.60 - barH / 2, width: arrowLen, height: barH))
    rightBar.fill()
    let rightHead = NSBezierPath()
    let rx = cx + arrowLen / 2
    rightHead.move(to: NSPoint(x: rx + headW, y: s * 0.60))
    rightHead.line(to: NSPoint(x: rx, y: s * 0.60 + headH / 2))
    rightHead.line(to: NSPoint(x: rx, y: s * 0.60 - headH / 2))
    rightHead.close()
    rightHead.fill()

    let leftBar = NSBezierPath(rect: NSRect(x: cx - arrowLen / 2, y: s * 0.40 - barH / 2, width: arrowLen, height: barH))
    leftBar.fill()
    let leftHead = NSBezierPath()
    let lx = cx - arrowLen / 2
    leftHead.move(to: NSPoint(x: lx - headW, y: s * 0.40))
    leftHead.line(to: NSPoint(x: lx, y: s * 0.40 + headH / 2))
    leftHead.line(to: NSPoint(x: lx, y: s * 0.40 - headH / 2))
    leftHead.close()
    leftHead.fill()

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
