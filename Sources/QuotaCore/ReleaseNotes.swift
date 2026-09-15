import Foundation

/// A release's notes, cut into what the update card shows: this language's
/// half of the body, grouped under its headings.
///
/// Scripts/publish_release.sh writes a release's body as the English section
/// of CHANGELOG.en.md, a `---` line, then the Chinese section of CHANGELOG.md.
/// Older releases carry a single hand-written body, in either language.
public struct ReleaseNotes: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, style, fixed, removed, other
    }

    public struct Group: Equatable, Sendable, Identifiable {
        public var kind: Kind
        /// The heading as written — "新增", "Fixed", "下拉面板".
        public var title: String
        public var items: [String]
        public var id: String { title }
    }

    /// A paragraph before the first heading, where the body has one.
    public var intro: String?
    public var groups: [Group]

    public var isEmpty: Bool { intro == nil && groups.allSatisfy(\.items.isEmpty) }
    public var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    public init(intro: String? = nil, groups: [Group] = []) {
        self.intro = intro
        self.groups = groups
    }

    public static func parse(_ body: String?, chinese: Bool = L10n.isChinese) -> ReleaseNotes {
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ReleaseNotes() }
        return parseSection(section(of: body, chinese: chinese))
    }

    /// The half written in the wanted language: of the parts between `---`
    /// lines, the one with the most (or, for English, the fewest) Chinese
    /// characters.
    static func section(of body: String, chinese: Bool) -> String {
        var parts: [String] = [""]
        for line in body.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                parts.append("")
            } else {
                parts[parts.count - 1] += line + "\n"
            }
        }
        let filled = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard filled.count > 1 else { return filled.first ?? body }
        let ranked = filled.sorted { hanCount($0) < hanCount($1) }
        return chinese ? ranked.last! : ranked.first!
    }

    private static func hanCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
    }

    static func parseSection(_ text: String) -> ReleaseNotes {
        var notes = ReleaseNotes()
        var introLines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                // A dated day heading ("### 2026-09-13") is not a group.
                if title.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { continue }
                notes.groups.append(Group(kind: kind(of: title), title: title, items: []))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = String(line.dropFirst(2))
                if notes.groups.isEmpty {
                    notes.groups.append(Group(kind: .other, title: "", items: []))
                }
                notes.groups[notes.groups.count - 1].items.append(item)
            } else if notes.groups.isEmpty {
                introLines.append(line)
            } else if let last = notes.groups.indices.last, !notes.groups[last].items.isEmpty {
                // A wrapped bullet.
                notes.groups[last].items[notes.groups[last].items.count - 1] += " " + line
            }
        }
        notes.groups.removeAll { $0.items.isEmpty }
        notes.intro = introLines.isEmpty ? nil : introLines.joined(separator: " ")
        return notes
    }

    /// "#12" in an entry: the GitHub issue the change fixes or answers. The
    /// changelogs write the number bare and each reader links it — GitHub's
    /// release page by itself, the site and the READMEs through
    /// Scripts/sync_changelog.py, the update card here. Not the `#` of an
    /// HTML entity or a URL fragment.
    public static func issueLinks(in item: String) -> [(range: Range<String.Index>, url: URL)] {
        // Swift's regexes have no lookbehind: the character before is matched
        // and left out of the link.
        item.matches(of: #/(?:^|[^\w&/])(#(\d+))\b/#).compactMap { match in
            URL(string: "https://github.com/gentpan/QuotaBar/issues/\(match.2)")
                .map { (match.1.startIndex..<match.1.endIndex, $0) }
        }
    }

    static func kind(of heading: String) -> Kind {
        switch heading.lowercased() {
        case "新增", "added", "new": .added
        case "样式", "style", "changed": .style
        case "修复", "fixed": .fixed
        case "删除", "移除", "removed": .removed
        default: .other
        }
    }
}
