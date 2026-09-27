import AppKit
import CryptoKit
import Darwin

// Self-updater, ported from Lidless's checkUpdates()/downloadUpdate() (~/dev/mac-keep-awake/main.swift),
// using the SAFE "verify-then-reveal" model: never auto-swaps the running app bundle and never
// relaunches. It verifies the release zip's SHA-256 when published, extracts into an isolated staging
// directory, then — as a mandatory, non-optional barrier — verifies the unzipped .app has a valid code
// signature AND was signed by AI Status Bar's own Developer ID Team ID. Only then does it move the app
// to a collision-safe, versioned name in Downloads and reveal it for manual installation.
// Dependency-free: URLSession for network, FileManager + /usr/bin/ditto for unzip, Process for
// codesign, CryptoKit for hashing.
enum Updates {
    private final class BoundedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var storage = Data()
        private(set) var exceeded = false

        init(maximumBytes: Int) {
            self.maximumBytes = maximumBytes
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !exceeded else { return false }
            guard chunk.count <= maximumBytes - storage.count else {
                exceeded = true
                return true
            }
            storage.append(chunk)
            return false
        }

        func snapshot() -> (data: Data, exceeded: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (storage, exceeded)
        }
    }

    static let subprocessTimedOutStatus: Int32 = -2
    static let subprocessOutputTooLargeStatus: Int32 = -3
    private static let maxArchiveBytes: Int64 = 100 * 1_024 * 1_024

    enum UpdateStagingError: Error {
        case unsafeArchive
        case extractionFailed
        case missingApp
        case authenticationFailed
        case noAvailableDestination
    }

    private static let repo = "https://github.com/sshykvlv/ai-status-bar"
    private static let expectedTeamID = "J2Q78NFXZX"
    private static let expectedAssetName = "AIStatusBar.zip"

    private static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func check(announce: Bool) {
        guard let api = URL(string: "https://api.github.com/repos/sshykvlv/ai-status-bar/releases/latest") else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            guard let data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if announce { DispatchQueue.main.async { alert("Couldn’t check for updates", "Please try again later.") } }
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isNewer(latest, than: currentVersion) else {
                if announce {
                    DispatchQueue.main.async { alert("You’re up to date", "AI Status Bar v\(currentVersion) is the latest version.") }
                }
                return
            }
            let assets = json["assets"] as? [[String: Any]] ?? []
            func assetURL(_ match: (String) -> Bool) -> URL? {
                for a in assets {
                    if let name = a["name"] as? String, match(name),
                       let s = a["browser_download_url"] as? String, let u = URL(string: s) { return u }
                }
                return nil
            }
            guard let zip = assetURL({ $0 == expectedAssetName }) ?? assetURL({ $0.hasSuffix(".zip") }) else {
                if announce { DispatchQueue.main.async { alert("Update failed", "Couldn’t find a downloadable release asset.") } }
                return
            }
            let sums = assetURL { $0 == "SHA256SUMS" }
            downloadAndVerify(zip, sums: sums, version: latest, announce: announce)
        }.resume()
    }

    // Componentwise numeric comparison — matches Lidless's isNewer(_:than:). Internal (not private)
    // so it's unit-testable via @testable import AIStatusBar.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<Swift.max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0, yi = i < y.count ? y[i] : 0
            if xi != yi { return xi > yi }
        }
        return false
    }

    static func archiveEntriesAreSafe(_ entries: [String]) -> Bool {
        guard !entries.isEmpty, entries.count <= 10_000 else { return false }

        for entry in entries {
            guard !entry.isEmpty,
                  !entry.hasPrefix("/"),
                  !entry.contains("\\"),
                  !entry.contains("\0"),
                  entry == "AIStatusBar.app" || entry.hasPrefix("AIStatusBar.app/") else {
                return false
            }

            var components = entry.split(separator: "/", omittingEmptySubsequences: false)
            if components.last?.isEmpty == true { components.removeLast() }
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                return false
            }
        }
        return true
    }

    static func archiveSummaryIsSafe(_ summary: String) -> Bool {
        let fields = summary.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
        guard fields.count >= 5,
              fields[1].hasPrefix("file"),
              fields[3] == "bytes",
              fields[4].hasPrefix("uncompressed"),
              let entryCount = Int(fields[0]),
              let expandedBytes = Int64(fields[2]) else {
            return false
        }
        return entryCount > 0 && entryCount <= 10_000 && expandedBytes <= 250 * 1_024 * 1_024
    }

    static func stageAndPublishDownloadedArchive(
        _ downloadedArchive: URL,
        version: String,
        downloadsDirectory: URL,
        preflight: (URL) -> Bool = { _ in true },
        extract: (URL, URL) -> Bool,
        authenticate: (URL) -> Bool,
        publish: (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws -> URL {
        let fileManager = FileManager.default
        let stagingDirectory = downloadsDirectory.appendingPathComponent(
            ".AIStatusBar-update-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let stagedArchive = stagingDirectory.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: downloadedArchive, to: stagedArchive)

        let archiveSize = try stagedArchive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let archiveSize, Int64(archiveSize) <= maxArchiveBytes else {
            throw UpdateStagingError.unsafeArchive
        }
        guard preflight(stagedArchive) else {
            throw UpdateStagingError.unsafeArchive
        }
        guard extract(stagedArchive, stagingDirectory) else {
            throw UpdateStagingError.extractionFailed
        }

        let stagedApp = stagingDirectory.appendingPathComponent("AIStatusBar.app", isDirectory: true)
        let stagedAppValues = try? stagedApp.resourceValues(forKeys: [.isSymbolicLinkKey])
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagedApp.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              stagedAppValues?.isSymbolicLink != true else {
            throw UpdateStagingError.missingApp
        }
        guard authenticate(stagedApp) else {
            throw UpdateStagingError.authenticationFailed
        }

        let baseName = "AIStatusBar-v\(safeVersion(version))"
        for attempt in 1...10_000 {
            let name = attempt == 1 ? "\(baseName).app" : "\(baseName)-\(attempt).app"
            let publishedApp = downloadsDirectory.appendingPathComponent(name, isDirectory: true)
            do {
                try publish(stagedApp, publishedApp)
                return publishedApp
            } catch {
                let cocoaError = error as NSError
                guard cocoaError.domain == NSCocoaErrorDomain,
                      cocoaError.code == CocoaError.fileWriteFileExists.rawValue else {
                    throw error
                }
            }
        }
        throw UpdateStagingError.noAvailableDestination
    }

    private static func downloadAndVerify(_ zip: URL, sums: URL?, version: String, announce: Bool) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        URLSession.shared.downloadTask(with: zip) { tmp, _, error in
            func fail(_ title: String, _ message: String) {
                DispatchQueue.main.async {
                    alert(title, message)
                    openReleasesPage()
                }
            }
            guard let tmp, error == nil else {
                fail("Download failed", "Opening the releases page instead.")
                return
            }
            defer { try? FileManager.default.removeItem(at: tmp) }

            // 1) Integrity (optional): SHA-256 against the published SHA256SUMS asset, if present.
            if let sums {
                let sumsText = fetchText(sums, timeout: 15) ?? ""
                guard let expected = expectedHash(in: sumsText, for: expectedAssetName),
                      let actual = sha256(ofFileAt: tmp, maxBytes: maxArchiveBytes) else {
                    fail("Update verification failed", "Couldn’t verify the download’s checksum. Grab it from the releases page.")
                    return
                }
                guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                    fail("Update verification failed", "Checksum mismatch — the download was not trusted and has been removed.")
                    return
                }
            }

            let publishedApp: URL
            do {
                publishedApp = try stageAndPublishDownloadedArchive(
                    tmp,
                    version: version,
                    downloadsDirectory: downloads,
                    preflight: { archive in
                        let summary = runStatus("/usr/bin/unzip", ["-Z", "-t", archive.path])
                        guard summary.status == 0, archiveSummaryIsSafe(summary.out) else { return false }

                        let listing = runStatus("/usr/bin/unzip", ["-Z", "-1", archive.path])
                        guard listing.status == 0 else { return false }
                        let entries = listing.out.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
                        return archiveEntriesAreSafe(entries)
                    },
                    extract: { archive, destination in
                        runStatus("/usr/bin/ditto", ["-x", "-k", archive.path, destination.path]).status == 0
                    },
                    authenticate: { app in
                        codesignValid(app) && teamID(of: app) == expectedTeamID
                    }
                )
            } catch UpdateStagingError.authenticationFailed {
                fail("Update rejected",
                     "The downloaded app isn’t signed by AI Status Bar’s Developer ID, so it was removed. Download manually from the releases page.")
                return
            } catch {
                fail("Update failed", "The downloaded archive looked malformed or couldn’t be staged safely.")
                return
            }

            // Verified → reveal the ready .app, never auto-swap the running bundle or relaunch.
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([publishedApp])
                if announce {
                    alert("Update verified", "Drag \(publishedApp.lastPathComponent) to /Applications to install.")
                }
            }
        }.resume()
    }

    // Name from tag_name is untrusted (API/MITM) — keep only safe characters to rule out
    // path traversal (`v../../…`) when building file paths.
    private static func safeVersion(_ v: String) -> String {
        let s = v.filter { ($0.isASCII && $0.isLetter) || $0.isNumber || $0 == "." || $0 == "-" }
        return s.isEmpty ? "update" : s
    }

    private static func openReleasesPage() {
        if let url = URL(string: "\(repo)/releases") { NSWorkspace.shared.open(url) }
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }

    // MARK: - Subprocess helpers

    // Merge stdout/stderr before draining so neither pipe can fill while the other is being read.
    @discardableResult
    static func runStatus(
        _ path: String,
        _ args: [String],
        timeout: TimeInterval = 30
    ) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        p.environment = environment
        let output = Pipe()
        p.standardOutput = output.fileHandleForWriting
        p.standardError = output.fileHandleForWriting
        let completed = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in completed.signal() }
        do {
            try p.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            return (-1, "", "")
        }
        try? output.fileHandleForWriting.close()

        let buffer = BoundedOutputBuffer(maximumBytes: 4 * 1_024 * 1_024)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { readerFinished.signal() }
            do {
                while let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1_024),
                      !chunk.isEmpty {
                    if buffer.append(chunk), p.isRunning {
                        p.terminate()
                    }
                }
            } catch {
                if p.isRunning { p.terminate() }
            }
        }

        let timedOut = completed.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            p.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(p.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
        }
        _ = readerFinished.wait(timeout: .now() + 2)
        try? output.fileHandleForReading.close()

        let captured = buffer.snapshot()
        guard !captured.exceeded else {
            return (subprocessOutputTooLargeStatus, "", "")
        }
        return (
            timedOut ? subprocessTimedOutStatus : p.terminationStatus,
            String(data: captured.data, encoding: .utf8) ?? "",
            ""
        )
    }

    static func sha256(ofFileAt url: URL, maxBytes: Int64) -> String? {
        guard maxBytes >= 0,
              let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(fileSize) <= maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                totalBytes += Int64(chunk.count)
                guard totalBytes <= maxBytes else { return nil }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Extracts the expected hash from SHA256SUMS text (lines like "<hash>␣␣<filename>").
    private static func expectedHash(in sumsText: String, for filename: String) -> String? {
        for line in sumsText.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).filter { !$0.isEmpty }
            if cols.count >= 2, cols.last.map(String.init) == filename { return String(cols[0]) }
        }
        return nil
    }

    // Code signature validity (strict bundle check, including nested code).
    static func codesignVerificationArguments(for app: URL) -> [String] {
        ["--verify", "--deep", "--strict", app.path]
    }

    private static func codesignValid(_ app: URL) -> Bool {
        runStatus("/usr/bin/codesign", codesignVerificationArguments(for: app)).status == 0
    }

    // Team ID from the signature: `codesign -dvvv` prints "TeamIdentifier=XX…" to stderr.
    private static func teamID(of app: URL) -> String? {
        let r = runStatus("/usr/bin/codesign", ["-dvvv", app.path])
        for line in (r.err + "\n" + r.out).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("TeamIdentifier=") {
                return String(line.dropFirst("TeamIdentifier=".count))
            }
        }
        return nil
    }

    // Fetch a small text asset (SHA256SUMS) with a hard timeout — don't block the
    // background download-task callback forever if the CDN stalls.
    private static func fetchText(_ url: URL, timeout: TimeInterval) -> String? {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = String(data: data, encoding: .utf8) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}
