import AppKit
import XCTest

final class SiteIdentityGeneratorTests: XCTestCase {
    func testEveryWebsiteBrandUsesApprovedSoraStatusBarLockup() throws {
        let site = repositoryRoot.appendingPathComponent("site")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: site,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        let htmlFiles = enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == "index.html"
        }
        XCTAssertFalse(htmlFiles.isEmpty)

        for file in htmlFiles {
            let html = try String(contentsOf: file, encoding: .utf8)
            guard html.contains("class=\"brand-text\"") else { continue }
            XCTAssertTrue(
                html.contains("<span class=\"brand-text\">Status Bar</span>"),
                file.path
            )
            XCTAssertFalse(html.contains("class=\"brand-accent\""), file.path)
            XCTAssertTrue(html.contains("family=Sora"), file.path)
        }

        let css = try String(
            contentsOf: site.appendingPathComponent("styles.css"),
            encoding: .utf8
        )
        XCTAssertTrue(css.contains("width: 24px; height: 24px"))
        XCTAssertTrue(css.contains("font-family: \"Sora\""))
        XCTAssertTrue(css.contains(".nav-links { display: none; }"))
    }

    func testAppIconGeneratorAlsoProducesEveryWebsiteIconSize() throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }

        try runScript("gen-appicon.swift", in: workspace)

        let expectations: [(String, Int)] = [
            ("site/assets/icon.png", 512),
            ("site/apple-touch-icon.png", 180),
            ("site/favicon-32.png", 32),
            ("site/favicon-16.png", 16),
        ]
        for (path, size) in expectations {
            let url = workspace.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("missing generated asset: \(path)")
                continue
            }
            let bitmap = try loadBitmap(url)
            XCTAssertEqual(bitmap.pixelsWide, size, path)
            XCTAssertEqual(bitmap.pixelsHigh, size, path)
        }

        let heroURL = workspace.appendingPathComponent("site/assets/icon.png")
        guard FileManager.default.fileExists(atPath: heroURL.path) else { return }
        let hero = try loadBitmap(heroURL)
        assertPixel(hero, x: 256, y: 50, hex: 0xF5F5F7)
        assertPixel(hero, x: 168, y: 256, hex: 0x8E8E93)
        assertPixel(hero, x: 233, y: 256, hex: 0xFFB040)
        assertPixel(hero, x: 200, y: 298, hex: 0xE05C4F)
        assertPixel(hero, x: 365, y: 256, hex: 0xE05C4F)
    }

    func testOpenGraphGeneratorUsesApprovedFlatAIMark() throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("site/assets"),
            withIntermediateDirectories: true
        )

        try runScript("gen-og.swift", in: workspace)

        let social = try loadBitmap(workspace.appendingPathComponent("site/assets/og.png"))
        XCTAssertEqual(social.pixelsWide, 1280)
        XCTAssertEqual(social.pixelsHigh, 640)
        assertPixel(social, x: 40, y: 40, hex: 0xF5F5F7)
        assertPixel(social, x: 257, y: 320, hex: 0x8E8E93)
        assertPixel(social, x: 327, y: 320, hex: 0xFFB040)
        assertPixel(social, x: 290, y: 355, hex: 0xE05C4F)
        assertPixel(social, x: 410, y: 355, hex: 0xE05C4F)
    }

    func testOpenGraphWordmarkDoesNotRepeatAIFromTheMark() throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("site/assets"),
            withIntermediateDirectories: true
        )

        try runScript("gen-og.swift", in: workspace)

        let social = try loadBitmap(workspace.appendingPathComponent("site/assets/og.png"))
        assertPixel(social, x: 950, y: 320, hex: 0xF5F5F7)
    }

    private func temporaryWorkspace() throws -> URL {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-status-bar-site-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    private func runScript(_ name: String, in workspace: URL) throws {
        let script = repositoryRoot.appendingPathComponent("scripts/\(name)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [script.path]
        process.currentDirectoryURL = workspace
        let stderr = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)
    }

    private func loadBitmap(_ url: URL) throws -> NSBitmapImageRep {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(NSBitmapImageRep(data: data), url.path)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func assertPixel(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        hex: UInt32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let source = bitmap.colorAt(x: x, y: y),
              let actual = source.usingColorSpace(.sRGB) else {
            XCTFail("missing sRGB pixel at \(x),\(y)", file: file, line: line)
            return
        }
        let expected = NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
        XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.03, file: file, line: line)
        XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01, file: file, line: line)
    }
}
