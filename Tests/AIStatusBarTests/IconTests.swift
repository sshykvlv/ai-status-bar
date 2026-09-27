import XCTest
import AppKit
@testable import AIStatusBar

final class IconTests: XCTestCase {
    func testBarLevelsUsedFromWorstWindow() {
        let states: [AccountState] = [
            .ok(Usage(fiveHour: .init(utilization: 62, resetsAt: nil),
                      sevenDay: .init(utilization: 31, resetsAt: nil)), fetchedAt: .init()),
            .failed(badge: "re-login"),
            .pending,
        ]
        let levels = IconRenderer.barLevels(states)
        XCTAssertEqual(levels[0].used!, 0.62, accuracy: 0.001) // worst window utilization
        XCTAssertNil(levels[1].used)                           // no data → empty track
        XCTAssertNil(levels[2].used)
    }

    func testColorGradientKeepsGreenThroughFirstQuarterThenBlends() {
        assertColor(IconRenderer.fillColor(used: 0), red: 0.204, green: 0.780, blue: 0.349)
        assertColor(IconRenderer.fillColor(used: 0.25), red: 0.204, green: 0.780, blue: 0.349)
        assertColor(IconRenderer.fillColor(used: 0.5), red: 1, green: 0.839, blue: 0.039)
        assertColor(IconRenderer.fillColor(used: 0.75), red: 1, green: 0.584, blue: 0)
        assertColor(IconRenderer.fillColor(used: 1), red: 1, green: 0.231, blue: 0.188)

        // Halfway through the second quarter must be a blend, not a discrete jump.
        assertColor(IconRenderer.fillColor(used: 0.375),
                    red: (0.204 + 1) / 2,
                    green: (0.780 + 0.839) / 2,
                    blue: (0.349 + 0.039) / 2)
    }

    func testStaleUsesUsageToo() {
        let s: [AccountState] = [.stale(Usage(fiveHour: .init(utilization: 40, resetsAt: nil),
                                              sevenDay: nil), fetchedAt: .init(), badge: "offline")]
        XCTAssertEqual(IconRenderer.barLevels(s)[0].used!, 0.40, accuracy: 0.001)
    }

    func testImageIsColoredWhenHasData() {
        // Цветовое кодирование: даже спокойный (normal) значок цветной (зелёный),
        // поэтому не template.
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 20, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertTrue(img.size.width > 0 && img.size.height > 0)
        XCTAssertFalse(img.isTemplate)
    }

    func testImageTemplateWhenNoData() {
        let s: [AccountState] = [.pending, .failed(badge: "re-login")]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertTrue(img.isTemplate)
    }

    func testImageNonTemplateAtHighUsage() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 95, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertFalse(img.isTemplate)
    }

    func testImageNonTemplateAtMidUsage() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 75, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertFalse(img.isTemplate)
    }

    func testFillHeightIsContinuousAndProportional() {
        XCTAssertEqual(IconRenderer.fillHeight(used: 0), 0)
        XCTAssertEqual(IconRenderer.fillHeight(used: 0.25), IconRenderer.barHeight * 0.25,
                       accuracy: 0.001)
        XCTAssertEqual(IconRenderer.fillHeight(used: 0.5), IconRenderer.barHeight * 0.5,
                       accuracy: 0.001)
        XCTAssertEqual(IconRenderer.fillHeight(used: 0.75), IconRenderer.barHeight * 0.75,
                       accuracy: 0.001)
        XCTAssertEqual(IconRenderer.fillHeight(used: 1), IconRenderer.barHeight,
                       accuracy: 0.001)
    }

    func testFillHeightClampsValuesOutsideTheUsageRange() {
        XCTAssertEqual(IconRenderer.fillHeight(used: -0.2), 0)
        XCTAssertEqual(IconRenderer.fillHeight(used: 1.2), IconRenderer.barHeight)
    }

    func testImageRendersOneContinuousColumn() {
        let level = IconRenderer.BarLevel(used: 0.5)
        let image = IconRenderer.image(levels: [level])
        let rep = bitmap(image)

        // Every row inside the track has pixels: there are no segment gaps.
        for y in 2...16 {
            let value = alpha(atX: 2, y: y, in: rep)
            XCTAssertGreaterThan(value, 0.1, "unexpected gap at y=\(y)")
        }
    }

    /// Regression coverage for the "icon disappears" bug: with zero configured
    /// accounts, `image(levels:)` used to draw nothing at all (the fill loop
    /// iterates `levels`, which was empty) — a fully blank, invisible menu bar
    /// icon with nothing left to click to add an account back. It must still
    /// draw at least an empty placeholder track.
    func testImageDrawsPlaceholderTrackWhenNoAccountsConfigured() {
        let img = IconRenderer.image(levels: [])
        XCTAssertTrue(img.size.width > 0 && img.size.height > 0)
        XCTAssertTrue(img.isTemplate, "no data at all should still render as a template icon")
        XCTAssertTrue(hasAnyNonTransparentPixel(img), "expected a visible placeholder track, got a blank canvas")
    }

    /// Visual QA harness for inspecting threshold states at native 1x/2x sizes.
    /// Run: `AISTATUSBAR_ICON_RENDER_DIR=/tmp/icons swift test --filter testRenderContinuousIconExamples`
    func testRenderContinuousIconExamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISTATUSBAR_ICON_RENDER_DIR"] else {
            throw XCTSkip("set AISTATUSBAR_ICON_RENDER_DIR to render icon previews")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for percent in stride(from: 0, through: 100, by: 10) {
            let image = IconRenderer.image(levels: [.init(used: Double(percent) / 100)])
            for scale in [1, 2] {
                let rep = bitmap(image, scale: scale)
                let url = URL(fileURLWithPath: "\(dir)/usage-\(percent)-\(scale)x.png")
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            }
        }
    }

    private func hasAnyNonTransparentPixel(_ image: NSImage) -> Bool {
        let rep = bitmap(image)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if alpha(atX: x, y: y, in: rep) > 0.01 { return true }
            }
        }
        return false
    }

    private func bitmap(_ image: NSImage, scale: Int = 1) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(image.size.width) * scale,
                                   pixelsHigh: Int(image.size.height) * scale,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func alpha(atX x: Int, y: Int, in rep: NSBitmapImageRep) -> CGFloat {
        rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    private func assertColor(_ color: NSColor, red: CGFloat, green: CGFloat, blue: CGFloat,
                             accuracy: CGFloat = 0.005, file: StaticString = #filePath,
                             line: UInt = #line) {
        let rgb = color.usingColorSpace(.deviceRGB)!
        XCTAssertEqual(rgb.redComponent, red, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.greenComponent, green, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(rgb.blueComponent, blue, accuracy: accuracy, file: file, line: line)
    }
}
