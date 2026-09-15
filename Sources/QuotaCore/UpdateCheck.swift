import Foundation

/// A newer release than the one running.
public struct AvailableUpdate: Sendable, Equatable {
    public let version: String
    public let url: URL
}

/// Checks GitHub Releases for a newer version.
///
/// Deliberately not Sparkle: that would add the project's first third-party
/// dependency, an appcast to host, and an EdDSA private key to keep. This
/// tells the user a release exists and sends them to it — `brew upgrade` or
/// the download page does the rest. Full in-place updating is a separate
/// decision, not a prerequisite for people knowing they are behind.
public enum UpdateCheck {
    public static let releasesURL = URL(string: "https://github.com/gentpan/QuotaBar/releases/latest")!
    private static let api = URL(
        string: "https://api.github.com/repos/gentpan/QuotaBar/releases/latest")!

    /// Returns the newer release, or nil when current, offline, or rate-limited.
    public static func latest(currentVersion: String) async -> AvailableUpdate? {
        guard let response = try? await HTTP.get(api, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "QuotaBar",
        ]), response.status == 200,
            let root = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
            let tag = root["tag_name"] as? String
        else { return nil }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard compare(latest, isNewerThan: currentVersion) else { return nil }
        let page = (root["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        return AvailableUpdate(version: latest, url: page)
    }

    /// Numeric component-wise comparison, so 0.2.10 sorts above 0.2.9 —
    /// a string compare would get that backwards. A pre-release sorts below
    /// the release it leads to: 0.5.0-beta.2 < 0.5.0, and beta.2 > beta.1.
    static func compare(_ lhs: String, isNewerThan rhs: String) -> Bool {
        let (leftCore, leftPre) = split(lhs)
        let (rightCore, rightPre) = split(rhs)
        for index in 0..<max(leftCore.count, rightCore.count) {
            let a = index < leftCore.count ? leftCore[index] : 0
            let b = index < rightCore.count ? rightCore[index] : 0
            if a != b { return a > b }
        }
        switch (leftPre, rightPre) {
        case (nil, nil): return false
        case (nil, _?): return true
        case (_?, nil): return false
        case let (a?, b?):
            for index in 0..<max(a.count, b.count) {
                let x = index < a.count ? a[index] : 0
                let y = index < b.count ? b[index] : 0
                if x != y { return x > y }
            }
            return false
        }
    }

    private static func split(_ version: String) -> ([Int], [Int]?) {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: "-", maxSplits: 1)
        let core = parts.first.map { numbers(String($0)) } ?? []
        let pre = parts.count > 1 ? numbers(String(parts[1])) : nil
        return (core, pre)
    }

    private static func numbers(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}
