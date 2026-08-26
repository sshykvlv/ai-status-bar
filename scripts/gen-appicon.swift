// Генератор плоской иконки приложения и всех web-размеров: один знак «AI»
// остаётся единым в Finder, hero, CTA, favicon и Apple Touch Icon.
// Запуск: swift scripts/gen-appicon.swift
import AppKit

let logicalSize: CGFloat = 1024
let neutral = NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
let warn = NSColor(srgbRed: 1, green: 176 / 255, blue: 64 / 255, alpha: 1)
let danger = NSColor(srgbRed: 224 / 255, green: 92 / 255, blue: 79 / 255, alpha: 1)

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: logicalSize, height: logicalSize)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let tile = NSBezierPath(
        roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976),
        xRadius: 220,
        yRadius: 220
    )
    NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1).setFill()
    tile.fill()

    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: logicalSize - y)
    }

    func stroke(from start: NSPoint, to end: NSPoint, width: CGFloat, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    stroke(from: point(270, 760), to: point(400, 264), width: 112, color: neutral)
    stroke(from: point(400, 264), to: point(530, 760), width: 112, color: warn)
    stroke(from: point(319, 596), to: point(481, 596), width: 76, color: danger)
    stroke(from: point(730, 276), to: point(730, 760), width: 112, color: danger)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writeIcon(pixels: Int, path: String) throws {
    let rep = renderIcon(pixels: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png fail: \(path)")
    }
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: output)
    print("written: \(output.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
}

try writeIcon(pixels: 1024, path: "icon/AppIcon-1024.png")
try writeIcon(pixels: 512, path: "site/assets/icon.png")
try writeIcon(pixels: 180, path: "site/apple-touch-icon.png")
try writeIcon(pixels: 32, path: "site/favicon-32.png")
try writeIcon(pixels: 16, path: "site/favicon-16.png")
