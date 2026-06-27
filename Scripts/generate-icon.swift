import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let iconset = assets.appendingPathComponent("Peek.iconset", isDirectory: true)
let preview = assets.appendingPathComponent("PeekIcon.png")

try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct Color {
    let r: CGFloat
    let g: CGFloat
    let b: CGFloat
    let a: CGFloat

    var ns: NSColor {
        NSColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

func drawIcon(size: CGFloat) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size),
        pixelsHigh: Int(size),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    else {
        throw NSError(domain: "PeekIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap"])
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    let scale = size / 1024
    func s(_ value: CGFloat) -> CGFloat { value * scale }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: s(x), y: s(y), width: s(w), height: s(h))
    }

    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: NSSize(width: size, height: size)).fill()

    let shadowPath = NSBezierPath(roundedRect: rect(64, 56, 896, 896), xRadius: s(210), yRadius: s(210))
    NSColor.black.withAlphaComponent(0.22).setFill()
    shadowPath.transform(using: {
        let transform = AffineTransform()
        return transform
    }())
    shadowPath.fill()

    let background = NSBezierPath(roundedRect: rect(64, 84, 896, 896), xRadius: s(210), yRadius: s(210))
    NSGradient(colors: [
        Color(r: 37, g: 99, b: 235, a: 1).ns,
        Color(r: 20, g: 184, b: 166, a: 1).ns,
        Color(r: 125, g: 211, b: 252, a: 1).ns,
    ])?.draw(in: background, angle: -42)

    NSColor.white.withAlphaComponent(0.12).setStroke()
    background.lineWidth = s(4)
    background.stroke()

    let backCardShadow = NSBezierPath(roundedRect: rect(262, 270, 476, 480), xRadius: s(64), yRadius: s(64))
    NSColor.black.withAlphaComponent(0.16).setFill()
    backCardShadow.fill()

    let backCard = NSBezierPath(roundedRect: rect(242, 302, 476, 480), xRadius: s(64), yRadius: s(64))
    Color(r: 219, g: 245, b: 255, a: 1).ns.withAlphaComponent(0.92).setFill()
    backCard.fill()

    let cardShadow = NSBezierPath(roundedRect: rect(190, 214, 560, 548), xRadius: s(78), yRadius: s(78))
    NSColor.black.withAlphaComponent(0.20).setFill()
    cardShadow.fill()

    let card = NSBezierPath(roundedRect: rect(174, 248, 560, 548), xRadius: s(78), yRadius: s(78))
    NSGradient(colors: [
        NSColor.white,
        Color(r: 236, g: 253, b: 245, a: 1).ns,
    ])?.draw(in: card, angle: -90)

    Color(r: 14, g: 116, b: 144, a: 1).ns.withAlphaComponent(0.14).setStroke()
    card.lineWidth = s(5)
    card.stroke()

    Color(r: 14, g: 165, b: 233, a: 1).ns.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: rect(246, 658, 164, 34), xRadius: s(17), yRadius: s(17)).fill()
    NSBezierPath(roundedRect: rect(246, 584, 326, 34), xRadius: s(17), yRadius: s(17)).fill()
    NSBezierPath(roundedRect: rect(246, 510, 250, 34), xRadius: s(17), yRadius: s(17)).fill()

    Color(r: 13, g: 148, b: 136, a: 1).ns.setFill()
    NSBezierPath(roundedRect: rect(246, 360, 62, 160), xRadius: s(31), yRadius: s(31)).fill()
    Color(r: 37, g: 99, b: 235, a: 1).ns.setFill()
    NSBezierPath(roundedRect: rect(342, 430, 62, 90), xRadius: s(31), yRadius: s(31)).fill()

    let lensShadow = NSBezierPath(ovalIn: rect(504, 276, 260, 260))
    NSColor.black.withAlphaComponent(0.18).setStroke()
    lensShadow.lineWidth = s(52)
    lensShadow.stroke()

    let lens = NSBezierPath(ovalIn: rect(496, 302, 260, 260))
    NSColor.white.withAlphaComponent(0.88).setFill()
    lens.fill()
    Color(r: 14, g: 116, b: 144, a: 1).ns.setStroke()
    lens.lineWidth = s(38)
    lens.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: s(700), y: s(320)))
    handle.line(to: NSPoint(x: s(818), y: s(202)))
    handle.lineCapStyle = .round
    handle.lineWidth = s(54)
    Color(r: 14, g: 116, b: 144, a: 1).ns.setStroke()
    handle.stroke()

    let highlight = NSBezierPath(ovalIn: rect(568, 426, 56, 56))
    Color(r: 125, g: 211, b: 252, a: 1).ns.withAlphaComponent(0.64).setFill()
    highlight.fill()

    NSColor.white.withAlphaComponent(0.84).setFill()
    NSBezierPath(roundedRect: rect(278, 698, 76, 18), xRadius: s(9), yRadius: s(9)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PeekIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    try png.write(to: url)
}

let outputs: [(String, CGFloat)] = [
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

for output in outputs {
    try writePNG(try drawIcon(size: output.1), to: iconset.appendingPathComponent(output.0))
}

try writePNG(try drawIcon(size: 1024), to: preview)
