import CryptoKit
import XCTest
@testable import QuotaCore

/// The app's client against a real Quota Run server, end to end: sign up in a
/// web session, connect a Mac through the code, upload a run, see it ranked
/// and on the profile, connect and disconnect a second Mac, deny a third,
/// then disconnect and delete the account.
///
/// Skipped unless `QUOTABAR_RUN_E2E` names a server, e.g.
/// `QUOTABAR_RUN_E2E=http://127.0.0.1:8799/api/v1 swift test --filter QuotaRunLiveTests`
/// with `server/run/run_server.py` running on a throwaway database and
/// `QUOTA_RUN_DEV_LOGIN=1 QUOTA_RUN_INSECURE_COOKIES=1` in its environment.
/// The session's writes send `Origin`, which must equal the server's
/// `QUOTA_RUN_ORIGIN`: `QUOTABAR_RUN_E2E_ORIGIN`, by default the scheme, host
/// and port of `QUOTABAR_RUN_E2E`.
final class QuotaRunLiveTests: XCTestCase {
    func testConnectUploadRankProfileDisconnectDelete() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["QUOTABAR_RUN_E2E"], let base = URL(string: raw), let host = base.host else {
            throw XCTSkip("QUOTABAR_RUN_E2E not set")
        }
        let origin = environment["QUOTABAR_RUN_E2E_ORIGIN"]
            ?? "\(base.scheme ?? "http")://\(host)\(base.port.map { ":\($0)" } ?? "")"
        let username = "e2e" + String(UUID().uuidString.prefix(8)).lowercased()
        let email = "\(username)@example.com"

        // The person: signed in on quota.run as an email identity, then signed up.
        let web = WebSession(base: base, origin: origin)
        let login = try await web.send("POST", "auth/dev", json: ["email": email])
        XCTAssertTrue((200...299).contains(login.status), login.text)
        XCTAssertFalse(web.cookie.isEmpty, "no qr_session cookie from /auth/dev")
        let signup = try await web.send("POST", "signup", json: ["username": username, "displayName": "End To End", "region": "global"])
        XCTAssertEqual(signup.status, 201, signup.text)

        // The Mac: a code, approved in the session, polled to an approval.
        var client = QuotaRunClient(base: base, signer: SoftwareRunSigner())
        let start = try await client.connectStart(deviceName: "Test Mac", appVersion: "0.0.0", lang: "en")
        XCTAssertEqual(start.userCode.count, 9, "ABCD-EFGH")
        XCTAssertTrue(start.verifyURL.absoluteString.contains("connect?code="), start.verifyURL.absoluteString)
        XCTAssertFalse(start.verifyURL.path.hasPrefix("/zh/"))
        let early = try await client.connectPoll(requestId: start.requestId)
        XCTAssertEqual(early, .pending)

        let shown = try await web.send("GET", "connect/\(start.userCode)")
        XCTAssertEqual(shown.status, 200, shown.text)
        XCTAssertEqual(shown.json["deviceName"] as? String, "Test Mac")
        XCTAssertEqual(shown.json["appVersion"] as? String, "0.0.0")
        let approval = try await web.send("POST", "connect/\(start.userCode)/approve")
        XCTAssertEqual(approval.status, 200, approval.text)
        XCTAssertEqual(approval.json["ranked"] as? Bool, true)

        let registration = try await settle(client, start)
        XCTAssertEqual(registration.user.username, username)
        XCTAssertTrue(registration.ranked, "the first Mac is the ranked one")
        client.deviceId = registration.deviceId

        let me = try await client.me()
        XCTAssertEqual(me.devices.count, 1)
        XCTAssertEqual(me.currentDevice?.appVersion, "0.0.0")
        XCTAssertEqual(me.identities.map(\.provider), ["email"])
        XCTAssertEqual(me.identities.first?.email, email)

        // A 5-hour window that started four hours ago and was run to 100% in
        // 2h 40m, read every ten minutes, with work in the logs meanwhile.
        let now = Int(Date().timeIntervalSince1970)
        let resetsAt = now + 3_600
        let windowStart = resetsAt - 18_000
        let digest = RunAccountDigest.digest(provider: "claude", account: email)
        var snapshots: [RunSnapshotPayload] = []
        for step in 0...16 {
            let used = min(100, Double(step) * 6.25)
            snapshots.append(RunSnapshotPayload(RunReading(
                provider: "claude", plan: "Max 20x", accountDigest: digest,
                windowKey: "18000:", windowTitle: "5-hour window", windowSeconds: 18_000,
                usedPercent: used, resetsAt: resetsAt, observedAt: windowStart + 60 + step * 600, source: "api")))
        }
        let activity = (0..<160).map { RunActivityPayload(minute: (windowStart / 60 + $0) * 60, source: "claude", tokens: 1_000) }
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
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: profile), as: UTF8.self).contains(email), "the sign-in email is never public")

        // A second Mac joins the same account unranked, then leaves it.
        var second = QuotaRunClient(base: base, signer: SoftwareRunSigner())
        let secondStart = try await second.connectStart(deviceName: "Second Mac", appVersion: "0.0.0", lang: "zh")
        XCTAssertTrue(secondStart.verifyURL.path.hasPrefix("/zh/"), secondStart.verifyURL.absoluteString)
        let secondApproval = try await web.send("POST", "connect/\(secondStart.userCode.lowercased().replacingOccurrences(of: "-", with: ""))/approve")
        XCTAssertEqual(secondApproval.status, 200, "codes ignore case and the dash: \(secondApproval.text)")
        let secondRegistration = try await settle(second, secondStart)
        XCTAssertFalse(secondRegistration.ranked)
        second.deviceId = secondRegistration.deviceId
        let both = try await second.me()
        XCTAssertEqual(both.devices.count, 2)
        XCTAssertEqual(both.currentDevice?.deviceId, secondRegistration.deviceId)
        try await second.disconnectCurrentDevice()
        let one = try await client.me()
        XCTAssertEqual(one.devices.map(\.deviceId), [registration.deviceId])

        // A third is denied: no device, and its key is still nobody's.
        let third = QuotaRunClient(base: base, signer: SoftwareRunSigner())
        let thirdStart = try await third.connectStart(deviceName: "Third Mac", appVersion: "0.0.0", lang: "en")
        let denial = try await web.send("POST", "connect/\(thirdStart.userCode)/deny")
        XCTAssertEqual(denial.status, 200, denial.text)
        let denied = try await third.connectPoll(requestId: thirdStart.requestId)
        XCTAssertEqual(denied, .denied)
        do {
            _ = try await QuotaRunClient(base: base, signer: SoftwareRunSigner()).connectPoll(requestId: thirdStart.requestId)
            XCTFail("a request belongs to the key that started it")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "connect_request_invalid")
        }

        // This Mac disconnects; its key stops working; the account is still there.
        try await client.disconnectCurrentDevice()
        do {
            _ = try await client.me()
            XCTFail("a disconnected Mac's key must be refused")
        } catch let error as QuotaRunError {
            XCTAssertTrue(error.isAuthFailure, "\(error)")
        }
        let still = try await HTTP.get(base.appendingPathComponent("users/\(username)"))
        XCTAssertEqual(still.status, 200)

        // Deleted from the web session.
        let deletion = try await web.send("DELETE", "account")
        XCTAssertEqual(deletion.status, 204, deletion.text)
        let gone = try await HTTP.get(base.appendingPathComponent("users/\(username)"))
        XCTAssertEqual(gone.status, 404)
    }

    /// Polls as the app does until the request is no longer pending.
    private func settle(_ client: QuotaRunClient, _ start: RunConnectStart) async throws -> RunRegistration {
        for _ in 0..<10 {
            switch try await client.connectPoll(requestId: start.requestId) {
            case let .approved(registration): return registration
            case .pending: try await Task.sleep(for: .seconds(start.interval))
            case let other:
                XCTFail("expected an approval, got \(other)")
                throw CancellationError()
            }
        }
        XCTFail("still pending after approval")
        throw CancellationError()
    }

    private func json(_ base: URL, _ path: String) async throws -> [String: Any] {
        let url = URL(string: base.absoluteString + "/" + path)!
        let response = try await HTTP.get(url)
        XCTAssertEqual(response.status, 200, String(decoding: response.data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response.data) as? [String: Any])
    }
}

/// A browser's side of quota.run: the `qr_session` cookie, carried by hand,
/// and `Origin` on every write.
private final class WebSession: @unchecked Sendable {
    let base: URL
    let origin: String
    private(set) var cookie = ""
    private let session: URLSession

    init(base: URL, origin: String) {
        self.base = base
        self.origin = origin
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    struct Answer {
        let status: Int
        let text: String
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
    }

    func send(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Answer {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        var request = URLRequest(url: URL(string: text + "/" + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method != "GET" { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if !cookie.isEmpty { request.setValue("qr_session=\(cookie)", forHTTPHeaderField: "Cookie") }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        if let header = http.value(forHTTPHeaderField: "Set-Cookie"),
           let range = header.range(of: #"qr_session=([^;,\s]*)"#, options: .regularExpression)
        {
            cookie = String(header[range].dropFirst("qr_session=".count))
        }
        return Answer(status: http.statusCode, text: String(decoding: data, as: UTF8.self))
    }
}
