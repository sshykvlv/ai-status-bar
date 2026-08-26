import AppKit
import XCTest

final class AppIconGeneratorTests: XCTestCase {
    func testGeneratorRendersApprovedFlatAIMark() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-status-bar-appicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let script = repositoryRoot.appendingPathComponent("scripts/gen-appicon.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [script.path]
        process.currentDirectoryURL = outputDirectory
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorText)

        let output = outputDirectory.appendingPathComponent("icon/AppIcon-1024.png")
        let data = try Data(contentsOf: output)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 1024)
        XCTAssertEqual(bitmap.pixelsHigh, 1024)

        assertPixel(bitmap, x: 512, y: 100, hex: 0xF5F5F7) // flat tile
        assertPixel(bitmap, x: 335, y: 512, hex: 0x8E8E93) // neutral leg
        assertPixel(bitmap, x: 465, y: 512, hex: 0xFFB040) // warn leg
        assertPixel(bitmap, x: 400, y: 596, hex: 0xE05C4F) // lowered crossbar
        assertPixel(bitmap, x: 730, y: 512, hex: 0xE05C4F) // danger I
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
