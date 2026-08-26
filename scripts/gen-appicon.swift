// Генератор плоской иконки приложения: округлые штрихи складываются в «AI».
// Палитра повторяет графики приложения: neutral / warn / danger.
// Запуск: swift scripts/gen-appicon.swift → icon/AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Небольшой прозрачный край и системное скругление оставляют знаку воздух.
let tile = NSBezierPath(
    roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976),
    xRadius: 220,
    yRadius: 220
)
NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1).setFill()
tile.fill()

let neutral = NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
let warn = NSColor(srgbRed: 1, green: 176 / 255, blue: 64 / 255, alpha: 1)
let danger = NSColor(srgbRed: 224 / 255, green: 92 / 255, blue: 79 / 255, alpha: 1)

// Макет задан в привычных экранных координатах (y вниз); AppKit рисует y вверх.
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: size - y)
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

// A: нейтральная левая ножка, warn-правая, danger-перекладина чуть ниже центра.
stroke(from: point(270, 760), to: point(400, 264), width: 112, color: neutral)
stroke(from: point(400, 264), to: point(530, 760), width: 112, color: warn)
stroke(from: point(319, 596), to: point(481, 596), width: 76, color: danger)

// I: тот же danger-цвет, что у критического состояния графиков.
stroke(from: point(730, 276), to: point(730, 760), width: 112, color: danger)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("png fail")
}
let out = URL(fileURLWithPath: "icon/AppIcon-1024.png")
try FileManager.default.createDirectory(atPath: "icon", withIntermediateDirectories: true)
try png.write(to: out)
print("written: \(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
