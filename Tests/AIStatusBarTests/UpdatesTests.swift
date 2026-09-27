import XCTest
@testable import AIStatusBar

final class UpdatesTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(Updates.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(Updates.isNewer("1.0.0", than: "0.9.9"))
        XCTAssertTrue(Updates.isNewer("0.1.10", than: "0.1.2"))  // numeric, not lexical
        XCTAssertFalse(Updates.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(Updates.isNewer("0.1.0", than: "0.2.0"))
    }

    func testArchiveEntryPreflightAllowsOnlyTheExpectedAppTree() {
        XCTAssertTrue(Updates.archiveEntriesAreSafe([
            "AIStatusBar.app/",
            "AIStatusBar.app/Contents/",
            "AIStatusBar.app/Contents/MacOS/AIStatusBar",
        ]))

        XCTAssertFalse(Updates.archiveEntriesAreSafe(["../Library/LaunchAgents/payload.plist"]))
        XCTAssertFalse(Updates.archiveEntriesAreSafe(["/Applications/AIStatusBar.app/payload"]))
        XCTAssertFalse(Updates.archiveEntriesAreSafe(["AIStatusBar.app/../../payload"]))
        XCTAssertFalse(Updates.archiveEntriesAreSafe(["AIStatusBar.app\\..\\payload"]))
        XCTAssertFalse(Updates.archiveEntriesAreSafe(["unexpected.txt"]))
        XCTAssertFalse(Updates.archiveEntriesAreSafe(
            Array(repeating: "AIStatusBar.app/Contents/payload", count: 10_001)
        ))
    }

    func testArchiveSummaryPreflightBoundsEntryCountAndExpandedSize() {
        XCTAssertTrue(Updates.archiveSummaryIsSafe(
            "19 files, 1867452 bytes uncompressed, 872762 bytes compressed: 53.3%"
        ))
        XCTAssertFalse(Updates.archiveSummaryIsSafe(
            "10001 files, 1867452 bytes uncompressed, 872762 bytes compressed: 53.3%"
        ))
        XCTAssertFalse(Updates.archiveSummaryIsSafe(
            "19 files, 262144001 bytes uncompressed, 872762 bytes compressed: 99.9%"
        ))
        XCTAssertFalse(Updates.archiveSummaryIsSafe("not a zip summary"))
    }

    func testCodesignVerificationIncludesNestedCode() {
        let app = URL(fileURLWithPath: "/tmp/AIStatusBar.app")
        XCTAssertEqual(
            Updates.codesignVerificationArguments(for: app),
            ["--verify", "--deep", "--strict", "/tmp/AIStatusBar.app"]
        )
    }

    func testSubprocessTimeoutTerminatesHungTool() {
        let startedAt = Date()
        let result = Updates.runStatus("/bin/sleep", ["2"], timeout: 0.05)

        XCTAssertEqual(result.status, Updates.subprocessTimedOutStatus)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testStreamingHashRejectsFileBeforeReadingPastLimit() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-status-bar-hash-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertNil(Updates.sha256(ofFileAt: file, maxBytes: 4))
        XCTAssertEqual(
            Updates.sha256(ofFileAt: file, maxBytes: 5),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testSubprocessStopsAsSoonAsOutputExceedsLimit() {
        let startedAt = Date()
        let result = Updates.runStatus(
            "/usr/bin/yes",
            [],
            timeout: 5
        )

        XCTAssertEqual(result.status, Updates.subprocessOutputTooLargeStatus)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    }

    func testStagedUpdatePreservesExistingAppsAndPublishesToFreeVersionedName() throws {
        let fileManager = FileManager.default
        let downloads = fileManager.temporaryDirectory
            .appendingPathComponent("ai-status-bar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloads) }

        let downloadedArchive = downloads.appendingPathComponent("download.tmp")
        try Data("archive".utf8).write(to: downloadedArchive)

        let existingApp = downloads.appendingPathComponent("AIStatusBar.app", isDirectory: true)
        try fileManager.createDirectory(at: existingApp, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: existingApp.appendingPathComponent("marker"))

        let occupiedVersion = downloads.appendingPathComponent("AIStatusBar-v1.2.3.app", isDirectory: true)
        try fileManager.createDirectory(at: occupiedVersion, withIntermediateDirectories: true)
        try Data("also keep me".utf8).write(to: occupiedVersion.appendingPathComponent("marker"))

        let published = try Updates.stageAndPublishDownloadedArchive(
            downloadedArchive,
            version: "1.2.3",
            downloadsDirectory: downloads,
            extract: { _, destination in
                let app = destination.appendingPathComponent("AIStatusBar.app", isDirectory: true)
                try? fileManager.createDirectory(at: app, withIntermediateDirectories: true)
                try? Data("new app".utf8).write(to: app.appendingPathComponent("marker"))
                return true
            },
            authenticate: { _ in true }
        )

        XCTAssertEqual(published.lastPathComponent, "AIStatusBar-v1.2.3-2.app")
        XCTAssertEqual(try String(contentsOf: existingApp.appendingPathComponent("marker")), "keep me")
        XCTAssertEqual(try String(contentsOf: occupiedVersion.appendingPathComponent("marker")), "also keep me")
        XCTAssertEqual(try String(contentsOf: published.appendingPathComponent("marker")), "new app")
        XCTAssertFalse(fileManager.fileExists(atPath: downloadedArchive.path))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: downloads.path)
            .contains { $0.hasPrefix(".AIStatusBar-update-") })
    }

    func testRejectedStagedUpdateCleansTemporaryFilesWithoutTouchingExistingApp() throws {
        let fileManager = FileManager.default
        let downloads = fileManager.temporaryDirectory
            .appendingPathComponent("ai-status-bar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloads) }

        let downloadedArchive = downloads.appendingPathComponent("download.tmp")
        try Data("archive".utf8).write(to: downloadedArchive)

        let existingApp = downloads.appendingPathComponent("AIStatusBar.app", isDirectory: true)
        try fileManager.createDirectory(at: existingApp, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: existingApp.appendingPathComponent("marker"))

        XCTAssertThrowsError(try Updates.stageAndPublishDownloadedArchive(
            downloadedArchive,
            version: "1.2.3",
            downloadsDirectory: downloads,
            extract: { _, destination in
                let app = destination.appendingPathComponent("AIStatusBar.app", isDirectory: true)
                try? fileManager.createDirectory(at: app, withIntermediateDirectories: true)
                return true
            },
            authenticate: { _ in false }
        )) { error in
            guard case Updates.UpdateStagingError.authenticationFailed = error else {
                return XCTFail("Expected authentication failure, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: existingApp.appendingPathComponent("marker")), "keep me")
        XCTAssertFalse(fileManager.fileExists(atPath: downloadedArchive.path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: downloads.appendingPathComponent("AIStatusBar-v1.2.3.app").path
        ))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: downloads.path)
            .contains { $0.hasPrefix(".AIStatusBar-update-") })
    }

    func testStagedUpdateRejectsRootAppSymlink() throws {
        let fileManager = FileManager.default
        let downloads = fileManager.temporaryDirectory
            .appendingPathComponent("ai-status-bar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloads) }

        let downloadedArchive = downloads.appendingPathComponent("download.tmp")
        try Data("archive".utf8).write(to: downloadedArchive)
        let linkTarget = downloads.appendingPathComponent("existing-signed-app", isDirectory: true)
        try fileManager.createDirectory(at: linkTarget, withIntermediateDirectories: true)

        XCTAssertThrowsError(try Updates.stageAndPublishDownloadedArchive(
            downloadedArchive,
            version: "1.2.3",
            downloadsDirectory: downloads,
            extract: { _, destination in
                let appLink = destination.appendingPathComponent("AIStatusBar.app")
                try? fileManager.createSymbolicLink(at: appLink, withDestinationURL: linkTarget)
                return true
            },
            authenticate: { _ in true }
        ))

        XCTAssertTrue(fileManager.fileExists(atPath: linkTarget.path))
        XCTAssertFalse(fileManager.fileExists(
            atPath: downloads.appendingPathComponent("AIStatusBar-v1.2.3.app").path
        ))
    }

    func testUnsafeArchiveIsRejectedBeforeExtraction() throws {
        let fileManager = FileManager.default
        let downloads = fileManager.temporaryDirectory
            .appendingPathComponent("ai-status-bar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloads) }

        let downloadedArchive = downloads.appendingPathComponent("download.tmp")
        try Data("archive".utf8).write(to: downloadedArchive)
        var extractionStarted = false

        XCTAssertThrowsError(try Updates.stageAndPublishDownloadedArchive(
            downloadedArchive,
            version: "1.2.3",
            downloadsDirectory: downloads,
            preflight: { _ in false },
            extract: { _, _ in
                extractionStarted = true
                return true
            },
            authenticate: { _ in true }
        ))

        XCTAssertFalse(extractionStarted)
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: downloads.path)
            .contains { $0.hasPrefix(".AIStatusBar-update-") })
    }

    func testPublishRetriesAtomicallyWhenFirstDestinationWinsARace() throws {
        let fileManager = FileManager.default
        let downloads = fileManager.temporaryDirectory
            .appendingPathComponent("ai-status-bar-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: downloads) }

        let downloadedArchive = downloads.appendingPathComponent("download.tmp")
        try Data("archive".utf8).write(to: downloadedArchive)
        var attemptedNames: [String] = []

        let published = try Updates.stageAndPublishDownloadedArchive(
            downloadedArchive,
            version: "1.2.3",
            downloadsDirectory: downloads,
            extract: { _, destination in
                let app = destination.appendingPathComponent("AIStatusBar.app", isDirectory: true)
                try? fileManager.createDirectory(at: app, withIntermediateDirectories: true)
                return true
            },
            authenticate: { _ in true },
            publish: { source, destination in
                attemptedNames.append(destination.lastPathComponent)
                if attemptedNames.count == 1 {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.fileWriteFileExists.rawValue
                    )
                }
                try fileManager.moveItem(at: source, to: destination)
            }
        )

        XCTAssertEqual(attemptedNames, ["AIStatusBar-v1.2.3.app", "AIStatusBar-v1.2.3-2.app"])
        XCTAssertEqual(published.lastPathComponent, "AIStatusBar-v1.2.3-2.app")
        XCTAssertTrue(fileManager.fileExists(atPath: published.path))
    }
}
