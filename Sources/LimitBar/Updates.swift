import AppKit

// Self-updater, ported from Lidless's checkUpdates()/downloadUpdate() (~/dev/mac-keep-awake/main.swift).
// Dependency-free: URLSession for network, FileManager + /usr/bin/ditto for unzip, Process for relaunch.
enum Updates {
    private static let owner = "sshykvlv"
    private static let repo = "limitbar"
    private static let expectedAssetName = "LimitBar.zip"
    private static let releasesURL = "https://github.com/\(owner)/\(repo)/releases"

    private static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    static func check(announce: Bool) {
        guard let api = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                guard let data, error == nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    if announce { alert("Couldn’t check for updates", "Please try again later.") }
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                guard isNewer(latest, than: currentVersion) else {
                    if announce { alert("You’re up to date", "LimitBar v\(currentVersion) is the latest version.") }
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
                    if announce { alert("Update failed", "Couldn’t find a downloadable release asset.") }
                    return
                }
                downloadAndInstall(zip, announce: announce)
            }
        }.resume()
    }

    // Componentwise numeric comparison — matches Lidless's isNewer(_:than:).
    private static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    private static func downloadAndInstall(_ zip: URL, announce: Bool) {
        URLSession.shared.downloadTask(with: zip) { tmp, _, error in
            DispatchQueue.main.async {
                guard let tmp, error == nil else {
                    fail(announce, "Download failed", "Opening the releases page instead.")
                    return
                }
                install(from: tmp, announce: announce)
            }
        }.resume()
    }

    // Unzips the downloaded archive, then swaps it in for the running bundle if the
    // install location is writable (e.g. /Applications for a normal admin user);
    // otherwise falls back to opening the releases page for a manual install
    // (covers brew-cask / read-only mounts).
    private static func install(from downloadedZip: URL, announce: Bool) {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("LimitBarUpdate-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            fail(announce, "Update failed", "Couldn’t prepare a temp folder.")
            return
        }
        defer { try? fm.removeItem(at: workDir) }

        // Keep the .zip extension so ditto -x -k recognizes the archive format.
        let zipPath = workDir.appendingPathComponent("LimitBar.zip")
        do {
            try fm.moveItem(at: downloadedZip, to: zipPath)
        } catch {
            fail(announce, "Update failed", "Couldn’t stage the downloaded archive.")
            return
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zipPath.path, workDir.path]
        do { try unzip.run(); unzip.waitUntilExit() } catch {
            fail(announce, "Update failed", "Couldn’t unzip the update.")
            return
        }
        guard unzip.terminationStatus == 0,
              let newApp = try? fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "app" }) else {
            fail(announce, "Update failed", "The downloaded archive looked malformed.")
            return
        }

        let currentApp = URL(fileURLWithPath: Bundle.main.bundlePath)
        let parentDir = currentApp.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parentDir.path) else {
            // Read-only install location (e.g. brew cask mount) — degrade gracefully.
            openReleasesPage()
            return
        }

        let backup = parentDir.appendingPathComponent(currentApp.lastPathComponent + ".old")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: currentApp, to: backup)
        } catch {
            fail(announce, "Update failed", "Couldn’t make way for the new version.")
            return
        }
        do {
            try fm.moveItem(at: newApp, to: currentApp)
        } catch {
            try? fm.moveItem(at: backup, to: currentApp)
            fail(announce, "Update failed", "Couldn’t install the new version.")
            return
        }
        try? fm.removeItem(at: backup)

        relaunch(at: currentApp)
    }

    private static func relaunch(at app: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [app.path]
        try? open.run()
        NSApp.terminate(nil)
    }

    private static func fail(_ announce: Bool, _ title: String, _ message: String) {
        if announce {
            alert(title, message)
            openReleasesPage()
        }
    }

    private static func openReleasesPage() {
        if let url = URL(string: releasesURL) { NSWorkspace.shared.open(url) }
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
