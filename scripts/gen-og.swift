// Генератор og.png 1280×640: плоский AI-знак, wordmark и слоган лендинга.
// Запуск: swift scripts/gen-og.swift → site/assets/og.png
import AppKit
import CoreText

let W: CGFloat = 1280, H: CGFloat = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let background = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
let neutral = NSColor(srgbRed: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
let warn = NSColor(srgbRed: 1, green: 176 / 255, blue: 64 / 255, alpha: 1)
let danger = NSColor(srgbRed: 224 / 255, green: 92 / 255, blue: 79 / 255, alpha: 1)
let graphite = NSColor(srgbRed: 35 / 255, green: 36 / 255, blue: 42 / 255, alpha: 1)

background.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: H - y)
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

// Тот же AI-знак, что на app icon, без тайла — чистый wordmark для соцсетей.
stroke(from: point(220, 430), to: point(290, 220), width: 52, color: neutral)
stroke(from: point(290, 220), to: point(360, 430), width: 52, color: warn)
stroke(from: point(250, 355), to: point(330, 355), width: 34, color: danger)
stroke(from: point(410, 226), to: point(410, 430), width: 52, color: danger)

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let soraURL = scriptDirectory.appendingPathComponent("assets/Sora[wght].ttf")
var registrationError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(soraURL as CFURL, .process, &registrationError) else {
    let message = registrationError?.takeRetainedValue().localizedDescription ?? "unknown error"
    fatalError("could not register Sora for OG rendering: \(message)")
}
let weightAxis = NSNumber(value: 0x77676874 as UInt32) // OpenType `wght`
let wordDescriptor = NSFontDescriptor(fontAttributes: [
    .name: "Sora",
    .variation: [weightAxis: NSNumber(value: 500)],
])
guard let wordFont = NSFont(descriptor: wordDescriptor, size: 90) else {
    fatalError("could not create Sora 500")
}
let wordAttrs: [NSAttributedString.Key: Any] = [
    .font: wordFont,
    .foregroundColor: graphite,
    .kern: -1.2,
]
let word = NSAttributedString(string: "Status Bar", attributes: wordAttrs)
let wordSize = word.size()
let wordCenterY: CGFloat = 315
word.draw(at: NSPoint(x: 490, y: H - wordCenterY - wordSize.height / 2))

let tagSize: CGFloat = 38
let tagPlain: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: tagSize, weight: .regular),
    .foregroundColor: neutral,
]
var serif = NSFont.systemFont(ofSize: tagSize, weight: .regular)
if let d = serif.fontDescriptor.withDesign(.serif),
   let f = NSFont(descriptor: d.withSymbolicTraits(.italic), size: tagSize) {
    serif = f
}
let tagAccent: [NSAttributedString.Key: Any] = [
    .font: serif,
    .foregroundColor: NSColor(srgbRed: 169 / 255, green: 104 / 255, blue: 0, alpha: 1),
]
let tagline = NSMutableAttributedString(string: "Your AI limits, ", attributes: tagPlain)
tagline.append(NSAttributedString(string: "always in sight.", attributes: tagAccent))
let taglineSize = tagline.size()
let taglineCenterY: CGFloat = 410
tagline.draw(at: NSPoint(x: 492, y: H - taglineCenterY - taglineSize.height / 2))

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
let out = URL(fileURLWithPath: "site/assets/og.png")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: out)
print("written: \(out.path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
