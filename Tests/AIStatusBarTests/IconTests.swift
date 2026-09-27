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
        XCTAssertEqual(levels[0].severity, .normal)
        XCTAssertNil(levels[1].used)                           // no data → empty track
        XCTAssertNil(levels[2].used)
    }

    func testWarnSeverityAboveSeventyPercentUsed() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 75, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        XCTAssertEqual(IconRenderer.barLevels(s)[0].severity, .warn)
    }

    func testWarnSeverityStartsAtSeventyPercentUsed() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 70, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        XCTAssertEqual(IconRenderer.barLevels(s)[0].severity, .warn)
    }

    func testDangerSeverityAboveNinetyPercentUsed() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 95, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let level = IconRenderer.barLevels(s)[0]
        XCTAssertEqual(level.severity, .danger)
        XCTAssertEqual(level.used!, 0.95, accuracy: 0.001)
    }

    func testDangerSeverityStartsAtNinetyPercentUsed() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 90, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        XCTAssertEqual(IconRenderer.barLevels(s)[0].severity, .danger)
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

    func testImageNonTemplateWhenDanger() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 95, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertFalse(img.isTemplate)
    }

    func testImageNonTemplateWhenWarn() {
        let s: [AccountState] = [.ok(Usage(fiveHour: .init(utilization: 75, resetsAt: nil),
                                           sevenDay: nil), fetchedAt: .init())]
        let img = IconRenderer.image(levels: IconRenderer.barLevels(s))
        XCTAssertFalse(img.isTemplate)
    }

    /// Catches accidental rounding-up or a return to continuous fill: the icon
    /// represents only completed 25% blocks, while the tooltip keeps precision.
    func testFillHeightAdvancesOnlyAtCompletedTwentyFivePercentThresholds() {
        let cases: [(used: Double, height: CGFloat)] = [
            (0, 0), (0.249, 0),
            (0.25, 3), (0.499, 3),
            (0.5, 7), (0.749, 7),
            (0.75, 11), (0.999, 11),
            (1, 15),
        ]

        for sample in cases {
            XCTAssertEqual(IconRenderer.fillHeight(used: sample.used), sample.height,
                           accuracy: 0.001, "used=\(sample.used)")
        }
    }

    func testFillHeightClampsValuesOutsideTheUsageRange() {
        XCTAssertEqual(IconRenderer.fillHeight(used: -0.2), 0)
        XCTAssertEqual(IconRenderer.fillHeight(used: 1.2), 15)
    }

    /// Catches a visually continuous track: every 1pt separator must remain
    /// transparent even between filled blocks at actual menu-bar size.
    func testImageRendersFourSeparatedSegments() {
        let level = IconRenderer.BarLevel(used: 0.5, severity: .normal)
        let image = IconRenderer.image(levels: [level])
        let rep = bitmap(image)

        let visible = (0..<rep.pixelsHigh).map { alpha(atX: 2, y: $0, in: rep) > 0.1 }
        let sections = visible.enumerated().filter { index, shown in
            shown && (index == 0 || !visible[index - 1])
        }
        XCTAssertEqual(sections.count, 4, "the rendered bar must have four separate blocks")
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
    /// Run: `AISTATUSBAR_ICON_RENDER_DIR=/tmp/icons swift test --filter testRenderSegmentedIconExamples`
    func testRenderSegmentedIconExamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISTATUSBAR_ICON_RENDER_DIR"] else {
            throw XCTSkip("set AISTATUSBAR_ICON_RENDER_DIR to render icon previews")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for percent in [0, 20, 40, 60, 80, 100] {
            let severity: IconRenderer.Severity = percent >= 90 ? .danger : (percent >= 70 ? .warn : .normal)
            let image = IconRenderer.image(levels: [.init(used: Double(percent) / 100, severity: severity)])
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
}
