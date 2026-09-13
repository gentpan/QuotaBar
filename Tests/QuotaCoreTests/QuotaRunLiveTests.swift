import CryptoKit
import XCTest
@testable import QuotaCore

/// The app's client against a real Quota Run server, end to end: join, upload
/// a run, see it ranked and on the profile, pair a second Mac, leave.
///
/// Skipped unless `QUOTABAR_RUN_E2E` names a server, e.g.
/// `QUOTABAR_RUN_E2E=http://127.0.0.1:8799/api/run/v1 swift test --filter QuotaRunLiveTests`
/// with `server/run/run_server.py` running on a throwaway database.
final class QuotaRunLiveTests: XCTestCase {
    func testJoinUploadRankProfilePairLeave() async throws {
        guard let raw = ProcessInfo.processInfo.environment["QUOTABAR_RUN_E2E"], let base = URL(string: raw) else {
            throw XCTSkip("QUOTABAR_RUN_E2E not set")
        }
        let username = "e2e" + String(UUID().uuidString.prefix(8)).lowercased()
        var client = QuotaRunClient(base: base, signer: SoftwareRunSigner())
        let joined = try await client.register(username: username, displayName: "End To End", region: .global, deviceName: "Test Mac", appVersion: "0.0.0")
        XCTAssertTrue(joined.ranked, "the first Mac is the ranked one")
        client.deviceId = joined.deviceId

        // A 5-hour window that started four hours ago and was run to 100% in
        // 2h 40m, read every ten minutes, with work in the logs meanwhile.
        let now = Int(Date().timeIntervalSince1970)
        let resetsAt = now + 3_600
        let start = resetsAt - 18_000
        let digest = RunAccountDigest.digest(provider: "claude", account: "\(username)@example.com")
        var snapshots: [RunSnapshotPayload] = []
        for step in 0...16 {
            let used = min(100, Double(step) * 6.25)
            snapshots.append(RunSnapshotPayload(RunReading(
                provider: "claude", plan: "Max 20x", accountDigest: digest,
                windowKey: "18000:", windowTitle: "5-hour window", windowSeconds: 18_000,
                usedPercent: used, resetsAt: resetsAt, observedAt: start + 60 + step * 600, source: "api")))
        }
        let activity = (0..<160).map { RunActivityPayload(minute: (start / 60 + $0) * 60, source: "claude", tokens: 1_000) }
        let receipt = try await client.upload(RunUploadBody(snapshots: snapshots, activity: activity))
        XCTAssertEqual(receipt.accepted, snapshots.count, "rejected: \(receipt.rejected)")

        let board = try await json(base, "leaderboard?provider=claude&plan=max20x&window=18000:&metric=speed&season=all")
        let entries = board["entries"] as? [[String: Any]] ?? []
        let mine = try XCTUnwrap(entries.first { $0["username"] as? String == username })
        XCTAssertEqual(mine["tier"] as? String, "verified")
        XCTAssertEqual(mine["value"] as? Double ?? (mine["value"] as? Int).map(Double.init), 60 + 16 * 600)

        _ = try await client.updateProfile(.init(displayName: "E2E Runner", bio: "Testing", region: .global, links: RunLinks(github: "gentpan")))
        _ = try await client.updateProjects([RunProject(name: "Quota", url: "https://quota.bar", description: "Tracker", github: "gentpan/QuotaBar", builtWith: ["claude"])])
        let profile = try await json(base, "users/\(username)")
        XCTAssertEqual(profile["displayName"] as? String, "E2E Runner")
        XCTAssertEqual((profile["projects"] as? [[String: Any]])?.first?["github"] as? String, "https://github.com/gentpan/QuotaBar")
        XCTAssertFalse((profile["bests"] as? [Any] ?? []).isEmpty)

        let code = try await client.pair()
        var second = QuotaRunClient(base: base, signer: SoftwareRunSigner())
        let paired = try await second.register(pairCode: code.code, deviceName: "Second Mac", appVersion: "0.0.0")
        XCTAssertFalse(paired.ranked)
        second.deviceId = paired.deviceId
        let me = try await second.me()
        XCTAssertEqual(me.devices.count, 2)

        try await client.deleteAccount()
        let gone = try await HTTP.get(base.appendingPathComponent("users/\(username)"))
        XCTAssertEqual(gone.status, 404)
    }

    private func json(_ base: URL, _ path: String) async throws -> [String: Any] {
        let url = URL(string: base.absoluteString + "/" + path)!
        let response = try await HTTP.get(url)
        XCTAssertEqual(response.status, 200, String(decoding: response.data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
    }
}
