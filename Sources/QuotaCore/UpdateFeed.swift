import Foundation

/// A release the updater can install.
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    /// Direct download for the zipped app bundle.
    public let downloadURL: URL
    /// Page to send the user to when installing in place is not appropriate.
    public let pageURL: URL
    public let notes: String?
    /// The same zip on quota.bar, tried when `downloadURL` cannot be reached.
    public var mirrorURL: URL?

    public init(version: String, downloadURL: URL, pageURL: URL, notes: String? = nil, mirrorURL: URL? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.pageURL = pageURL
        self.notes = notes
        self.mirrorURL = mirrorURL
    }
}

/// Where to look for releases.
public enum UpdateFeed: Sendable, Equatable {
    /// GitHub's releases API for `owner/repo`.
    case github(repo: String)
    /// A JSON endpoint you host:
    /// `{"version":"0.3.0","url":"https://…/QuotaBar-0.3.0.zip","notes":"…"}`
    case custom(URL)

    public static let `default` = UpdateFeed.github(repo: "gentpan/quotabar")

    /// The copy of every release on quota.bar, uploaded by
    /// Scripts/publish_release.sh — for networks where GitHub is slow or
    /// blocked. A custom feed in its own right.
    public static let mirror = UpdateFeed.custom(URL(string: "https://quota.bar/download/latest.json")!)

    static func mirrorDownload(version: String) -> URL {
        URL(string: "https://quota.bar/download/QuotaBar-\(version).zip")!
    }

    /// This project's own releases, which quota.bar mirrors. Someone else's
    /// repository or server has no copy there.
    var isMirrored: Bool {
        if case let .github(repo) = self { return repo.lowercased() == "gentpan/quotabar" }
        return false
    }

    var requestURL: URL {
        switch self {
        case let .github(repo):
            URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        case let .custom(url):
            url
        }
    }

    /// Every recent release, pre-releases included — for the beta channel.
    var listURL: URL? {
        switch self {
        case let .github(repo): URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=15")
        case .custom: nil
        }
    }

    /// The newest non-draft release in a GitHub list, pre-release or not.
    static func newest(in data: Data, page: URL) -> UpdateRelease? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let releases = list
            .filter { ($0["draft"] as? Bool) != true }
            .compactMap { item -> UpdateRelease? in
                guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
                return parseGitHub(data, page: page)
            }
        return releases.max { UpdateCheck.compare($1.version, isNewerThan: $0.version) }
    }

    var fallbackPage: URL {
        switch self {
        case let .github(repo):
            URL(string: "https://github.com/\(repo)/releases/latest")!
        case let .custom(url):
            url
        }
    }

    /// Serialised form for the config file: a bare `owner/repo` means GitHub,
    /// anything with a scheme is a custom endpoint.
    public var configValue: String {
        switch self {
        case let .github(repo): repo
        case let .custom(url): url.absoluteString
        }
    }

    public init?(configValue: String) {
        let trimmed = configValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed) else { return nil }
            self = .custom(url)
        } else {
            // Must look like owner/repo, or a typo silently becomes a feed
            // that always fails.
            let parts = trimmed.split(separator: "/")
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            self = .github(repo: trimmed)
        }
    }

    /// Parses whichever shape this feed returns.
    func parse(_ data: Data) -> UpdateRelease? {
        switch self {
        case .github: Self.parseGitHub(data, page: fallbackPage)
        case .custom: Self.parseCustom(data, page: fallbackPage)
        }
    }

    static func parseGitHub(_ data: Data, page: URL) -> UpdateRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // The zip, not the dmg: installing in place unpacks a bundle, and
        // mounting a disk image to do that would be gratuitous.
        let assets = root["assets"] as? [[String: Any]] ?? []
        let zip = assets.first {
            ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true
        }
        guard let download = (zip?["browser_download_url"] as? String)
            .flatMap(URL.init(string:))
        else { return nil }
        return UpdateRelease(
            version: version,
            downloadURL: download,
            pageURL: (root["html_url"] as? String).flatMap(URL.init(string:)) ?? page,
            notes: root["body"] as? String)
    }

    static func parseCustom(_ data: Data, page: URL) -> UpdateRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String,
              let download = (root["url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        return UpdateRelease(
            version: version,
            downloadURL: download,
            pageURL: (root["page"] as? String).flatMap(URL.init(string:)) ?? page,
            notes: root["notes"] as? String)
    }
}
