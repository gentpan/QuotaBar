import Foundation

public enum UpdateError: LocalizedError, Sendable {
    case downloadFailed
    case extractionFailed
    case notSignedByUs(found: String?)
    case notNotarized
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            L10n.t("Could not download the update.", "无法下载更新。")
        case .extractionFailed:
            L10n.t("The downloaded archive could not be opened.", "无法解压下载的文件。")
        case let .notSignedByUs(found):
            L10n.t(
                "The download is not signed by this app's developer (found: \(found ?? "unsigned")).",
                "下载内容不是本应用开发者签名的（实际为：\(found ?? "无签名")）。")
        case .notNotarized:
            L10n.t(
                "The download is not notarized by Apple and was rejected.",
                "下载内容未通过 Apple 公证，已拒绝安装。")
        case let .installFailed(reason):
            L10n.t("Could not install the update: \(reason)", "安装更新失败：\(reason)")
        }
    }
}

/// Downloads, verifies and installs a newer build.
///
/// **Verification is the whole point.** An updater that installs whatever it
/// downloaded is a remote code execution path, so a staged bundle is only
/// installed when it is signed by this app's own Developer ID team *and*
/// notarized by Apple. That is a stronger guarantee than a self-managed
/// signing key: an attacker would need the developer's certificate, not just
/// control of the download URL.
public enum Updater {
    /// Where an update has got to.
    public enum Stage: Sendable, Equatable {
        case idle
        case checking
        case available(UpdateRelease)
        case downloading(UpdateRelease)
        case readyToInstall(UpdateRelease)
        case failed(String)
    }

    // MARK: Check

    public static func check(
        feed: UpdateFeed,
        currentVersion: String,
        includePrereleases: Bool = false) async -> UpdateRelease?
    {
        let url = includePrereleases ? feed.listURL ?? feed.requestURL : feed.requestURL
        guard let response = try? await HTTP.get(url, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "QuotaBar",
        ]), response.status == 200
        else { return nil }
        let release = includePrereleases && feed.listURL != nil
            ? UpdateFeed.newest(in: response.data, page: feed.fallbackPage)
            : feed.parse(response.data)
        guard let release, UpdateCheck.compare(release.version, isNewerThan: currentVersion) else { return nil }
        return release
    }

    // MARK: Download and verify

    /// Downloads the release, verifies it, and leaves the verified bundle in a
    /// staging directory. Returns its path.
    public static func stage(_ release: UpdateRelease) async throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let archive = work.appendingPathComponent("update.zip")
        guard let response = try? await HTTP.get(release.downloadURL),
              response.status == 200, !response.data.isEmpty
        else {
            try? FileManager.default.removeItem(at: work)
            throw UpdateError.downloadFailed
        }
        try response.data.write(to: archive)

        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]).ok,
              let bundle = try? FileManager.default
                  .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                  .first(where: { $0.pathExtension == "app" })
        else {
            try? FileManager.default.removeItem(at: work)
            throw UpdateError.extractionFailed
        }

        do {
            try verify(bundle)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
        return bundle
    }

    /// Refuses anything not signed by our own team and notarized.
    static func verify(_ bundle: URL) throws {
        let signature = run("/usr/bin/codesign", ["-dvvv", bundle.path])
        guard signature.ok else { throw UpdateError.notSignedByUs(found: nil) }
        let found = teamIdentifier(in: signature.output)
        guard let found, found == currentTeamIdentifier() else {
            throw UpdateError.notSignedByUs(found: found)
        }
        guard run("/usr/bin/codesign", ["--verify", "--strict", bundle.path]).ok else {
            throw UpdateError.notSignedByUs(found: found)
        }
        // Gatekeeper's own verdict, which covers notarization.
        let gate = run("/usr/sbin/spctl", ["-a", "-vv", bundle.path])
        guard gate.output.contains("accepted") else { throw UpdateError.notNotarized }
    }

    static func teamIdentifier(in codesignOutput: String) -> String? {
        for line in codesignOutput.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// The team that signed the running app — the only one an update may carry.
    static func currentTeamIdentifier() -> String? {
        let path = Bundle.main.bundleURL.path
        return teamIdentifier(in: run("/usr/bin/codesign", ["-dvvv", path]).output)
    }

    // MARK: Install

    /// True when Homebrew owns this install, in which case replacing the
    /// bundle behind its back would desync its metadata and the next
    /// `brew upgrade` would fight us. Owns, not once installed: the
    /// Caskroom keeps its folder after the app has been replaced by hand,
    /// so it counts only when it holds the version that is running.
    public static func isManagedByHomebrew(
        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        caskroots: [String] = ["/opt/homebrew/Caskroom/quotabar", "/usr/local/Caskroom/quotabar"]) -> Bool
    {
        guard let version, !version.isEmpty else { return false }
        return caskroots.contains { root in
            FileManager.default.fileExists(atPath: "\(root)/\(version)")
        }
    }

    /// Replaces the running bundle with the staged one and relaunches.
    ///
    /// The running process keeps its own file handles, so swapping the bundle
    /// underneath it is safe; the replaced copy is what the relaunch picks up.
    public static func install(staged: URL, relaunch: Bool = true) throws {
        let destination = Bundle.main.bundleURL
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).backup")

        let fm = FileManager.default
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: destination, to: backup)
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
        do {
            try fm.copyItem(at: staged, to: destination)
        } catch {
            // Put the working copy back rather than leaving nothing installed.
            try? fm.moveItem(at: backup, to: destination)
            throw UpdateError.installFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: backup)
        try? fm.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())

        guard relaunch else { return }
        _ = run("/usr/bin/open", ["-n", destination.path])
    }

    // MARK: Process helper

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> (ok: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(data: data, encoding: .utf8) ?? "")
    }
}
