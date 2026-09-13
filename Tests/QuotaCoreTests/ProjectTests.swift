import XCTest
@testable import QuotaCore

/// Projects from the logs: remotes, worktrees, folders, modes, and the archive.
final class ProjectTests: XCTestCase {
    private var root: URL!
    private var paths: CostPaths!
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:00Z")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quotabar-projects-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("claude/projects")
        let codex = root.appendingPathComponent("codex/sessions")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claude, codexSessions: codex)
        CostEstimator.resetCache()
        ProjectResolver.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
        ProjectResolver.resetCache()
    }

    private func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A checkout at `work/<name>` with an `origin` remote, or none.
    private func repository(_ name: String, remote: String?) throws -> String {
        let config = remote.map { "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = \($0)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
            ?? "[core]\n\tbare = false\n"
        try write(config, to: "work/\(name)/.git/config")
        return root.appendingPathComponent("work/\(name)").path
    }

    // MARK: Remotes

    func testRemoteSpellingsNormalise() {
        let cases: [(String, String?)] = [
            ("git@github.com:gentpan/QuotaBar.git", "github.com/gentpan/QuotaBar"),
            ("https://github.com/gentpan/QuotaBar", "github.com/gentpan/QuotaBar"),
            ("https://x-access-token:secret@github.com/gentpan/QuotaBar.git/", "github.com/gentpan/QuotaBar"),
            ("ssh://git@gitlab.example.com:2222/group/sub/app.git", "gitlab.example.com/group/sub/app"),
            ("git+https://github.com/a/b.git", "github.com/a/b"),
            ("/Users/peter/repos/local.git", nil),
            ("file:///Users/peter/x.git", nil),
            ("https://github.com/only-owner", nil),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(ProjectResolver.normalizeRemote(raw), expected, raw)
        }
    }

    func testOriginWinsOverOtherRemotes() {
        let config = "[remote \"upstream\"]\n\turl = https://github.com/up/stream\n[remote \"origin\"]\n\turl = git@github.com:me/fork.git\n"
        XCTAssertEqual(ProjectResolver.remoteURL(inConfig: config), "git@github.com:me/fork.git")
        XCTAssertEqual(ProjectResolver.remoteURL(inConfig: "[remote \"upstream\"]\n\turl = https://github.com/up/stream\n"),
                       "https://github.com/up/stream")
    }

    // MARK: Resolving directories

    func testSubdirectoryOfARepositoryIsThatRepository() throws {
        let checkout = try repository("quota", remote: "git@github.com:gentpan/QuotaBar.git")
        let ref = ProjectResolver.resolve(cwd: checkout + "/server/run")
        XCTAssertEqual(ref.key, "github.com/gentpan/quotabar")
        XCTAssertEqual(ref.name, "QuotaBar")
        XCTAssertEqual(ref.repo, "github.com/gentpan/QuotaBar")
    }

    func testLinkedWorktreeBelongsToItsRepository() throws {
        let checkout = try repository("main", remote: "https://github.com/gentpan/QuotaBar.git")
        try write("gitdir: \(checkout)/.git/worktrees/feature\n", to: "trees/feature/.git")
        try write("../..\n", to: "work/main/.git/worktrees/feature/commondir")
        let ref = ProjectResolver.resolve(cwd: root.appendingPathComponent("trees/feature").path)
        XCTAssertEqual(ref.key, "github.com/gentpan/quotabar")
        XCTAssertEqual(ref.root.map { ($0 as NSString).standardizingPath }, (checkout as NSString).standardizingPath)
    }

    func testRepositoryWithoutRemoteAndPlainFolder() throws {
        let checkout = try repository("scratch", remote: nil)
        let local = ProjectResolver.resolve(cwd: checkout)
        XCTAssertTrue(local.key.hasPrefix("local:scratch:"), local.key)
        XCTAssertNil(local.repo)
        let folder = root.appendingPathComponent("loose/notes").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let plain = ProjectResolver.resolve(cwd: folder)
        XCTAssertTrue(plain.key.hasPrefix("dir:notes:"), plain.key)
        XCTAssertEqual(ProjectResolver.resolve(cwd: nil), .unknown)
        XCTAssertEqual(ProjectResolver.resolve(cwd: FileManager.default.homeDirectoryForCurrentUser.path), .unknown)
        // A remote the log names is enough, even for a directory that is gone.
        XCTAssertEqual(ProjectResolver.resolve(cwd: "/nowhere/app", repositoryURL: "git@github.com:o/app.git").key, "github.com/o/app")
    }

    func testModes() {
        XCTAssertEqual(CodingMode.claude(entrypoint: nil), .cli)
        XCTAssertEqual(CodingMode.claude(entrypoint: "cli"), .cli)
        XCTAssertEqual(CodingMode.claude(entrypoint: "claude-desktop"), .desktop)
        XCTAssertEqual(CodingMode.claude(entrypoint: "claude-vscode"), .ide)
        XCTAssertEqual(CodingMode.claude(entrypoint: "sdk-ts"), .sdk)
        XCTAssertEqual(CodingMode.codex(originator: "Codex Desktop", source: "vscode"), .desktop)
        XCTAssertEqual(CodingMode.codex(originator: "codex_cli_rs", source: "cli"), .cli)
        XCTAssertEqual(CodingMode.codex(originator: "codex_vscode", source: "vscode"), .ide)
        XCTAssertEqual(CodingMode.codex(originator: "codex_exec", source: "exec"), .sdk)
        XCTAssertEqual(CodingMode.codex(originator: nil, source: "vscode"), .ide)
    }

    // MARK: Scan and archive

    func testScanSplitsTokensByProjectModeAndSession() throws {
        let quota = try repository("quota", remote: "git@github.com:gentpan/QuotaBar.git")
        let other = try repository("other", remote: "https://github.com/gentpan/Other")
        func claude(_ id: String, cwd: String, entry: String, session: String, time: String, output: Int) -> String {
            """
            {"type":"assistant","requestId":"r\(id)","timestamp":"\(time)","cwd":"\(cwd)","entrypoint":"\(entry)","sessionId":"\(session)",\
            "message":{"id":"m\(id)","model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":\(output),\
            "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """
        }
        try write([
            claude("1", cwd: quota, entry: "claude-desktop", session: "s1", time: "2026-08-26T09:00:00.000Z", output: 1_000_000),
            claude("2", cwd: quota + "/Sources", entry: "claude-desktop", session: "s1", time: "2026-08-26T09:00:30.000Z", output: 1_000_000),
            claude("3", cwd: quota, entry: "cli", session: "s2", time: "2026-08-26T09:05:00.000Z", output: 500_000),
            claude("4", cwd: other, entry: "claude-desktop", session: "s3", time: "2026-08-26T10:00:00.000Z", output: 200_000),
        ].joined(separator: "\n"), to: "claude/projects/-work-quota/s1.jsonl")
        try write([
            #"{"timestamp":"2026-08-26T08:00:00.000Z","type":"session_meta","payload":{"id":"codex-1","cwd":"/gone/QuotaBar","originator":"Codex Desktop","source":"vscode","git":{"repository_url":"https://github.com/gentpan/QuotaBar.git","branch":"main"}}}"#,
            #"{"timestamp":"2026-08-26T08:00:01.000Z","type":"turn_context","payload":{"cwd":"/gone/QuotaBar","model":"gpt-5-codex"}}"#,
            #"{"type":"event_msg","timestamp":"2026-08-26T08:01:00.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1000}}}}"#,
        ].joined(separator: "\n"), to: "codex/sessions/2026/08/26/rollout-a.jsonl")

        let scan = CostEstimator.archiveScan(paths: paths, since: .distantPast, now: now)
        let day = UsageArchive.dayKey(ISO8601DateFormatter().date(from: "2026-08-26T09:00:00Z")!)
        let quotaDay = try XCTUnwrap(scan.projects[day]?["github.com/gentpan/quotabar"])
        let desktop = try XCTUnwrap(quotaDay["claudeCode"]?["desktop"])
        XCTAssertEqual(desktop.sessions, 1)
        XCTAssertEqual(desktop.activeMinutes, 1)
        XCTAssertEqual(desktop.models["claude-opus-5"]?.output, 2_000_000)
        XCTAssertEqual(desktop.hours.reduce(0, +), 2_000_000)
        XCTAssertEqual(quotaDay["claudeCode"]?["cli"]?.models["claude-opus-5"]?.output, 500_000)
        XCTAssertEqual(quotaDay["codexCLI"]?["desktop"]?.models["gpt-5-codex"]?.output, 1_000)
        XCTAssertEqual(scan.projects[day]?["github.com/gentpan/other"]?["claudeCode"]?["desktop"]?.sessions, 1)

        var archive = ProjectArchive()
        archive.merge(scan.projects, infos: scan.projectRefs, scannedAt: now, full: true)
        let overview = archive.overview(from: now.addingTimeInterval(-86_400), to: now)
        XCTAssertEqual(overview.projects.map(\.info.name), ["QuotaBar", "Other"])
        let quotaSummary = overview.projects[0]
        XCTAssertEqual(quotaSummary.sessions, 3)
        XCTAssertEqual(quotaSummary.modes.map(\.mode), [.desktop, .cli])
        XCTAssertEqual(quotaSummary.daily.count, 2)
        XCTAssertEqual(overview.waysOfWorking, 3)   // Claude desktop, Claude terminal, Codex desktop

        // A smaller later reading of the same day does not shrink the archive.
        var smaller = scan.projects
        smaller[day]?["github.com/gentpan/quotabar"]?["claudeCode"]?["desktop"]?.models["claude-opus-5"]?.output = 1
        archive.merge(smaller, infos: scan.projectRefs, scannedAt: now, full: false)
        XCTAssertEqual(archive.days[day]?["github.com/gentpan/quotabar"]?["claudeCode"]?["desktop"]?.models["claude-opus-5"]?.output, 2_000_000)
    }

    func testFolderWithARepositoryNameIsFoldedIntoIt() {
        var archive = ProjectArchive()
        let entry = ProjectDay(sessions: 1, activeMinutes: 2, hours: Array(repeating: 0, count: 24),
                               models: ["claude-opus-5": ArchiveEntry(usd: 1, output: 10)])
        let day = UsageArchive.dayKey(now)
        archive.merge([day: [
            "github.com/me/app": ["claudeCode": ["desktop": entry]],
            "dir:app:1234abcd": ["claudeCode": ["desktop": entry]],
            "dir:notes:99999999": ["claudeCode": ["cli": entry]],
        ]], infos: [
            "github.com/me/app": ProjectRef(key: "github.com/me/app", name: "App", repo: "github.com/me/App"),
            "dir:app:1234abcd": ProjectRef(key: "dir:app:1234abcd", name: "app"),
            "dir:notes:99999999": ProjectRef(key: "dir:notes:99999999", name: "notes"),
        ], scannedAt: now, full: true)
        XCTAssertEqual(archive.aliases(), ["dir:app:1234abcd": "github.com/me/app"])
        let overview = archive.overview(from: now, to: now)
        XCTAssertEqual(overview.projects.map(\.info.key).sorted(), ["dir:notes:99999999", "github.com/me/app"])
        let app = overview.projects.first { $0.info.key == "github.com/me/app" }
        XCTAssertEqual(app?.sessions, 2)
        XCTAssertEqual(app?.usd ?? 0, 2, accuracy: 0.0001)
    }
}

/// What goes to quota.run: public projects under their id, the rest folded.
final class RunUsagePlanTests: XCTestCase {
    func testRowsFoldPrivateProjectsAndCountSessionsOnce() {
        let day = "2026-09-13"
        var archive = ProjectArchive()
        let opus = ArchiveEntry(usd: 25, input: 1, output: 1_000_000)
        let sonnet = ArchiveEntry(usd: 3, output: 200_000)
        archive.merge([day: [
            "github.com/me/app": ["claudeCode": ["desktop": ProjectDay(sessions: 2, activeMinutes: 30, models: ["claude-opus-5": opus, "claude-sonnet-5": sonnet])]],
            "github.com/me/secret": ["claudeCode": ["desktop": ProjectDay(sessions: 1, activeMinutes: 5, models: ["claude-opus-5": opus])]],
            "dir:notes:1": ["claudeCode": ["desktop": ProjectDay(sessions: 4, activeMinutes: 9, models: ["claude-opus-5": opus])],
                            "openCode": ["cli": ProjectDay(sessions: 1, activeMinutes: 1, models: ["opencode": ArchiveEntry(usd: 1.5, input: 10)])]],
        ]], infos: [
            "github.com/me/app": ProjectRef(key: "github.com/me/app", name: "App", repo: "github.com/me/App"),
            "github.com/me/secret": ProjectRef(key: "github.com/me/secret", name: "secret", repo: "github.com/me/secret"),
            "dir:notes:1": ProjectRef(key: "dir:notes:1", name: "notes"),
        ], scannedAt: Date(), full: true)
        var sharing = ProjectSharingPrefs()
        sharing.setPublic(true, info: archive.projects["github.com/me/app"]!)
        let id = sharing.projects["github.com/me/app"]!.id
        XCTAssertEqual(id, ProjectSharingPrefs.publicID(for: "github.com/me/app"))   // 同一个仓库在每台 Mac 上 id 相同
        XCTAssertTrue(id.hasPrefix("r") && id.count == 21)
        XCTAssertEqual(sharing.revision, 1)

        let body = RunUsagePlan.body(days: [day], archive: archive, sharing: sharing, timezone: TimeZone(identifier: "Asia/Shanghai")!)
        XCTAssertEqual(body.projects, [RunUsageProject(id: id, name: "App", repo: "github.com/me/App")])
        XCTAssertTrue(body.projectsComplete)
        let publicRows = body.rows.filter { $0.project == id }
        XCTAssertEqual(publicRows.map(\.model), ["claude-opus-5", "claude-sonnet-5"])
        XCTAssertEqual(publicRows.map(\.sessions), [2, 0])
        let folded = body.rows.first { $0.project == nil && $0.tool == "claude" }
        XCTAssertEqual(folded?.output, 2_000_000)      // secret + notes, no name
        XCTAssertEqual(folded?.sessions, 5)
        XCTAssertNil(folded?.costUSD)
        XCTAssertEqual(body.rows.first { $0.tool == "opencode" }?.costUSD, 1.5)

        sharing.setPublic(false, info: archive.projects["github.com/me/app"]!)
        XCTAssertEqual(sharing.revision, 2)
        XCTAssertTrue(RunUsagePlan.body(days: [day], archive: archive, sharing: sharing).projects.isEmpty)
        XCTAssertEqual(RunUsagePlan.allDays(in: archive, now: ISO8601DateFormatter().date(from: "2026-09-14T12:00:00Z")!), [day])
    }
}
