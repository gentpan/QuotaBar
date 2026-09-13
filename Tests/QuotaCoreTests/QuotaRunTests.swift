import CryptoKit
import XCTest
@testable import QuotaCore

// MARK: - Run arithmetic

/// The contract's run rules, pinned on fixtures. The server computes the same
/// numbers; a drift here is a drift between a personal record and the board.
final class RunMathTests: XCTestCase {
    /// A weekly window resetting on a five-minute mark.
    private let reset = 1_790_000_100
    private let week = 604_800
    private var start: Int { reset - week }

    private func reading(_ offset: Int, _ used: Double, reset jitter: Int = 0, digest: String? = "d1", provider: String = "codex", seconds: Int? = nil, plan: String? = "Pro 20x") -> RunReading {
        let length = seconds ?? week
        return RunReading(
            provider: provider, plan: plan, accountDigest: digest,
            windowKey: RunMath.windowKey(seconds: length, scope: nil), windowTitle: "Weekly window",
            windowSeconds: length, usedPercent: used, resetsAt: reset + jitter, observedAt: start + offset)
    }

    private var clean: [RunReading] {
        [
            reading(600, 10), reading(1_200, 30, reset: 2), reading(1_800, 48, reset: -3), reading(2_400, 55),
            reading(3_000, 70), reading(3_600, 91), reading(4_200, 99.6), reading(4_800, 100),
        ]
    }

    func testNormalisationAndKeys() {
        XCTAssertEqual(RunMath.planNorm("Pro 20x"), "pro20x")
        XCTAssertEqual(RunMath.planNorm("Pro_Plus"), "proplus")
        XCTAssertEqual(RunMath.planNorm(nil), "")
        XCTAssertEqual(RunMath.windowKey(seconds: 604_800, scope: nil), "604800:")
        XCTAssertEqual(RunMath.windowKey(seconds: nil, scope: "Fable"), "0:Fable")
        XCTAssertEqual(RunMath.roundedReset(reset + 149), reset)
        XCTAssertEqual(RunMath.roundedReset(reset + 150), reset + 300)
        XCTAssertEqual(RunMath.roundedReset(reset - 150), reset)
        XCTAssertEqual(RunMath.roundedReset(reset - 151), reset - 300)
        XCTAssertTrue(RunMath.isRankable(windowSeconds: 3_600, resetsAt: 1))
        XCTAssertTrue(RunMath.isRankable(windowSeconds: 2_764_800, resetsAt: 1))
        XCTAssertFalse(RunMath.isRankable(windowSeconds: 3_599, resetsAt: 1))
        XCTAssertFalse(RunMath.isRankable(windowSeconds: 2_764_801, resetsAt: 1))
        XCTAssertFalse(RunMath.isRankable(windowSeconds: 604_800, resetsAt: nil))
    }

    func testCanonicalTitleIgnoresTheInterfaceLanguage() {
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .zhHans
        XCTAssertEqual(RunMath.canonicalTitle(seconds: 604_800, scope: nil, fallback: "周窗口"), "Weekly window")
        XCTAssertEqual(RunMath.canonicalTitle(seconds: 18_000, scope: "Fable", fallback: "x"), "5-hour window · Fable")
        XCTAssertEqual(RunMath.canonicalTitle(seconds: 0, scope: nil, fallback: "月度套餐"), "月度套餐")
    }

    func testRunFromReadings() throws {
        let runs = RunMath.runs(from: clean) { source, from, to in
            source == "codex" && from == self.start + 600 && to == self.start + 4_200
        }
        XCTAssertEqual(runs.count, 1, "reset jitter under the grain stays one run")
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.windowStart, start)
        XCTAssertEqual(run.resetsAt, reset)
        XCTAssertEqual(run.planNorm, "pro20x")
        XCTAssertEqual(run.peakPercent, 100)
        XCTAssertEqual(run.secondsTo50, 2_400)
        XCTAssertEqual(run.secondsTo90, 3_600)
        XCTAssertEqual(run.secondsTo100, 4_200, "99.5 counts as full")
        XCTAssertEqual(run.completedAt, start + 4_200)
        XCTAssertEqual(run.readingCount, 8)
        XCTAssertEqual(run.tier, .verified)
    }

    func testThresholdsNotReachedAreNil() throws {
        let run = try XCTUnwrap(RunMath.runs(from: [reading(600, 20), reading(1_200, 60)]).first)
        XCTAssertEqual(run.secondsTo50, 1_200)
        XCTAssertNil(run.secondsTo90)
        XCTAssertNil(run.secondsTo100)
        XCTAssertNil(run.completedAt)
        XCTAssertEqual(run.peakPercent, 60)
    }

    func testGroupingSplitsResetsPlansAndDropsUnrankable() {
        var readings = clean
        // The next week.
        readings.append(RunReading(
            provider: "codex", plan: "Pro 20x", windowKey: "604800:", windowTitle: "Weekly window", windowSeconds: week,
            usedPercent: 5, resetsAt: reset + week, observedAt: reset + 60))
        // Another plan on the same window.
        readings.append(reading(700, 12, plan: "Plus"))
        // 30 minutes is shorter than any rankable window; no reset is not rankable.
        readings.append(reading(900, 40, seconds: 1_800))
        readings.append(RunReading(provider: "cursor", windowKey: "0:", windowTitle: "Monthly plan", windowSeconds: 0, usedPercent: 50, resetsAt: nil, observedAt: start))
        let runs = RunMath.runs(from: readings)
        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(runs.first?.resetsAt, reset + week, "newest reset first")
    }

    func testTierWithoutActivityIsStandard() {
        XCTAssertEqual(RunMath.runs(from: clean).first?.tier, .standard, "codex needs CLI activity")
        // Providers without a CLI log need none.
        let cursor = clean.map { var r = $0; r.provider = "cursor"; return r }
        XCTAssertEqual(RunMath.runs(from: cursor).first?.tier, .verified)
    }

    func testMissingDigestIsStandard() {
        var readings = clean
        readings[3].accountDigest = nil
        XCTAssertEqual(RunMath.runs(from: readings) { _, _, _ in true }.first?.tier, .standard)
    }

    func testDropIsFlagged() {
        var readings = clean
        readings.append(reading(4_000, 60))
        XCTAssertFalse(RunMath.isMonotonic(readings.sorted { $0.observedAt < $1.observedAt }))
        XCTAssertEqual(RunMath.runs(from: readings) { _, _, _ in true }.first?.tier, .flagged)
        // Two points of wobble is allowed.
        var wobble = clean
        wobble.append(reading(3_700, 89))
        XCTAssertEqual(RunMath.runs(from: wobble) { _, _, _ in true }.first?.tier, .verified)
    }

    func testImplausibleJumpIsFlagged() {
        let jump = [reading(100, 0), reading(350, 65), reading(900, 70)]
        XCTAssertFalse(RunMath.isPlausible(jump))
        XCTAssertEqual(RunMath.runs(from: jump) { _, _, _ in true }.first?.tier, .flagged)
        // The same rise over five minutes or more is plausible.
        XCTAssertTrue(RunMath.isPlausible([reading(100, 0), reading(400, 65)]))
        // Two 40-point steps inside four minutes are one 80-point jump.
        XCTAssertFalse(RunMath.isPlausible([reading(100, 0), reading(200, 40), reading(340, 80)]))
    }

    func testCoverage() {
        XCTAssertTrue(RunMath.isCovered(clean))
        XCTAssertFalse(RunMath.isCovered([reading(600, 51), reading(1_200, 60)]), "joined past half")
        XCTAssertFalse(RunMath.isCovered([reading(600, 10), reading(1_801, 20), reading(2_400, 30)]), "a 20m01s gap")
        XCTAssertTrue(RunMath.isCovered([reading(600, 10), reading(1_800, 20)]), "exactly 20 minutes")
        // Gaps after the 100% reading do not matter.
        XCTAssertTrue(RunMath.isCovered([reading(600, 10), reading(1_200, 100), reading(9_000, 100)]))
    }

    func testBests() throws {
        let fast = RunMath.runs(from: clean) { _, _, _ in true }
        // A slower week that peaked at 100% too, and a flagged one that was faster.
        let slowReadings = [0, 1, 2, 3].map { index in
            RunReading(
                provider: "codex", plan: "Pro 20x", accountDigest: "d1", windowKey: "604800:", windowTitle: "Weekly window",
                windowSeconds: week, usedPercent: [20, 60, 95, 100][index], resetsAt: reset + week,
                observedAt: start + week + 10_000 * (index + 1))
        }
        let slow = RunMath.runs(from: slowReadings)
        var flagged = slow[0]
        flagged.resetsAt += week
        flagged.secondsTo100 = 60
        flagged.tier = .flagged
        let bests = RunMath.bests(from: fast + slow + [flagged])
        XCTAssertEqual(bests.count, 1)
        let best = try XCTUnwrap(bests.first)
        XCTAssertEqual(best.fastest?.secondsTo100, 4_200)
        XCTAssertEqual(best.highestPeak?.id, fast[0].id, "tie on 100% goes to the earlier completion")

        // The readings behind the fast run expire; the record stays.
        let later = RunMath.bests(from: slow, keeping: bests)
        XCTAssertEqual(later.first?.fastest?.secondsTo100, 4_200)
    }

    func testInProgress() {
        let runs = RunMath.runs(from: clean)
        XCTAssertEqual(RunMath.inProgress(runs, now: start + 5_000).count, 1)
        XCTAssertTrue(RunMath.inProgress(runs, now: reset + 1).isEmpty)
    }

    func testDurations() {
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .en
        XCTAssertEqual(RunFormat.duration(9_420), "2h 37m")
        XCTAssertEqual(RunFormat.duration(2_460), "41m")
        XCTAssertEqual(RunFormat.duration(90_000), "1d 1h")
        L10n.override = .zhHans
        XCTAssertEqual(RunFormat.duration(9_420), "2 小时 37 分")
    }
}

// MARK: - Readings and the ledger

final class RunLedgerTests: XCTestCase {
    func testAccountDigest() {
        let expected = "6dcc534f9660472ab683e6860fb341a519260b5906534c9acaacd21a5b84f9ce"
        XCTAssertEqual(RunAccountDigest.digest(provider: "codex", account: "dev@example.com"), expected)
        XCTAssertEqual(RunAccountDigest.digest(provider: "codex", account: "  Dev@Example.COM\n"), expected)
        XCTAssertNotEqual(RunAccountDigest.digest(provider: "claude", account: "dev@example.com"), expected)
        XCTAssertNil(RunAccountDigest.digest(provider: "codex", account: "  "))
    }

    func testReadingsFromASnapshot() {
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .zhHans
        let fetched = Date(timeIntervalSince1970: 1_789_420_000.6)
        let snapshot = UsageSnapshot(
            planName: " Pro 20x ",
            account: "Dev@example.com",
            windows: [
                UsageWindow(title: "周窗口", usedPercent: 36.499999999, resetsAt: Date(timeIntervalSince1970: 1_789_999_200), windowSeconds: 604_800),
                UsageWindow(title: "余额", detail: "$4.00"),
                UsageWindow(title: "周窗口 · Fable", usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_789_999_200), windowSeconds: 604_800, scope: "Fable"),
                UsageWindow(title: "月度套餐", usedPercent: 61),
            ],
            fetchedAt: fetched)
        let readings = RunReading.from(provider: .codex, snapshot: snapshot)
        XCTAssertEqual(readings.count, 3, "a window without a percentage is not a reading")
        XCTAssertEqual(readings[0].plan, "Pro 20x")
        XCTAssertEqual(readings[0].windowKey, "604800:")
        XCTAssertEqual(readings[0].windowTitle, "Weekly window")
        XCTAssertEqual(readings[0].usedPercent, 36.5)
        XCTAssertEqual(readings[0].observedAt, 1_789_420_000)
        XCTAssertEqual(readings[0].resetsAt, 1_789_999_200)
        XCTAssertEqual(readings[0].accountDigest, RunAccountDigest.digest(provider: "codex", account: "dev@example.com"))
        XCTAssertEqual(readings[0].source, "api")
        XCTAssertEqual(readings[1].windowKey, "604800:Fable")
        XCTAssertEqual(readings[1].windowTitle, "Weekly window · Fable")
        XCTAssertEqual(readings[2].windowKey, "0:")
        XCTAssertEqual(readings[2].windowTitle, "月度套餐")
        XCTAssertNil(readings[2].resetsAt)
        XCTAssertEqual(RunReading.from(provider: .windsurf, snapshot: snapshot).first?.source, "local")
    }

    private func reading(_ observed: Int, _ used: Double, key: String = "604800:", reset: Int? = 2_000_000) -> RunReading {
        RunReading(provider: "codex", windowKey: key, windowTitle: "Weekly window", windowSeconds: 604_800, usedPercent: used, resetsAt: reset, observedAt: observed)
    }

    func testDedupeAndHeartbeat() {
        var ledger = RunLedger()
        XCTAssertEqual(ledger.append(reading(1_000, 36))?.seq, 1)
        XCTAssertNil(ledger.append(reading(1_300, 36)), "unchanged within ten minutes")
        XCTAssertNil(ledger.append(reading(1_300, 36, reset: 2_000_002)), "reset jitter is not a change")
        XCTAssertEqual(ledger.append(reading(1_600, 36))?.seq, 2, "unchanged, but ten minutes on")
        XCTAssertEqual(ledger.append(reading(1_700, 37))?.seq, 3, "a change is always kept")
        XCTAssertNil(ledger.append(reading(1_700, 38)), "same instant, same window")
        XCTAssertNil(ledger.append(reading(1_500, 40)), "older than what is kept")
        XCTAssertEqual(ledger.append(reading(1_700, 5, key: "18000:"))?.seq, 4, "windows are independent")
        XCTAssertEqual(ledger.readings(after: 2).map(\.seq), [3, 4])
        XCTAssertEqual(ledger.readings(after: 4), [])
        XCTAssertEqual(ledger.lastSeq, 4)
    }

    func testOneRunKeepsOneDigest() {
        var ledger = RunLedger()
        var named = reading(1_000, 10)
        named.accountDigest = "abc"
        ledger.append(named)
        XCTAssertEqual(ledger.append(reading(1_700, 12))?.accountDigest, "abc", "a refresh that did not name the account")
        XCTAssertNil(ledger.append(reading(2_400, 13, reset: 2_604_800))?.accountDigest, "a new period is not assumed")
        var other = reading(3_100, 14, reset: 2_604_800)
        other.accountDigest = "xyz"
        XCTAssertEqual(ledger.append(other)?.accountDigest, "xyz")
    }

    func testPruneKeepsBestsAndIndex() {
        var ledger = RunLedger()
        ledger.append(reading(1_000, 10))
        ledger.append(reading(100_000, 20))
        ledger.bests = [PersonalBest(id: "b", provider: "codex", plan: nil, planNorm: "", windowKey: "604800:", windowSeconds: 604_800, scope: nil, fastest: nil, highestPeak: nil)]
        ledger.prune(now: 1_000 + RunLedger.retention + 1)
        XCTAssertEqual(ledger.readings.map(\.observedAt), [100_000])
        XCTAssertEqual(ledger.bests.count, 1)
        XCTAssertNil(ledger.append(reading(100_100, 20)), "the index survived the prune")
        XCTAssertEqual(ledger.append(reading(100_100, 21))?.seq, 3)
    }

    func testFileRoundTripAndLeniency() throws {
        var ledger = RunLedger()
        ledger.append(reading(1_000, 36.5))
        ledger.append(RunReading(provider: "cursor", plan: "Pro", accountDigest: "abc", windowKey: "0:", windowTitle: "Monthly plan", windowSeconds: 0, scope: nil, usedPercent: 61, resetsAt: nil, observedAt: 1_000))
        ledger.append(reading(2_000, 40))
        let data = try JSONEncoder().encode(ledger)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"rows\""))
        XCTAssertEqual(text.components(separatedBy: "\"provider\"").count - 1, 2, "one series row per window")
        XCTAssertEqual(try JSONDecoder().decode(RunLedger.self, from: data), ledger)

        let damaged = #"{"version":1,"nextSeq":2,"series":[{"provider":"codex","windowKey":"604800:","windowTitle":"W","windowSeconds":604800,"source":"api"}],"rows":[[0,5,1000,36,null],[7,6,1000,1,1],[0,"x"],[0,9,1100,37]],"bests":"nope"}"#
        let decoded = try JSONDecoder().decode(RunLedger.self, from: Data(damaged.utf8))
        XCTAssertEqual(decoded.readings.map(\.seq), [5, 9])
        XCTAssertNil(decoded.readings[1].resetsAt)
        XCTAssertEqual(decoded.nextSeq, 10, "never reuses a number in the file")
        XCTAssertEqual(decoded.bests, [])
    }

    func testStoreWritesAndReloads() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("runs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 2_000)
        let store = RunLedgerStore(fileURL: url, saveDelay: 60, now: now)
        XCTAssertEqual(store.record([reading(1_000, 10), reading(1_000, 11)]), 1)
        store.flush()
        let reloaded = RunLedgerStore(fileURL: url, now: now)
        XCTAssertEqual(reloaded.current.readings.count, 1)
        XCTAssertEqual(reloaded.lastSeq, 1)
    }
}

// MARK: - Wire client

final class QuotaRunClientTests: XCTestCase {
    private let signer = SoftwareRunSigner()
    private let fixedNonce = Data((0..<16).map { UInt8($0) })

    private func client(base: URL = QuotaRunClient.productionBase, deviceId: String? = "dev_1", transport: @escaping QuotaRunClient.Transport = { _, _, _, _ in HTTPResponse(status: 500, data: Data()) }) -> QuotaRunClient {
        let nonce = fixedNonce
        return QuotaRunClient(
            base: base, signer: signer, deviceId: deviceId, transport: transport,
            clock: { Date(timeIntervalSince1970: 1_789_420_000) }, nonce: { nonce })
    }

    func testBase64URL() {
        XCTAssertEqual(Base64URL.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(Base64URL.encode(fixedNonce), "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(Base64URL.decode("AAECAwQFBgcICQoLDA0ODw"), fixedNonce)
        XCTAssertNil(Base64URL.decode("A"))
    }

    func testCanonicalStringAndBodyHash() {
        XCTAssertEqual(RunCanonical.bodyHash(nil), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(RunCanonical.bodyHash(Data(#"{"a":1}"#.utf8)), "015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862")
        XCTAssertEqual(
            RunCanonical.string(method: "post", path: "/api/v1/snapshots", timestamp: 1_789_420_000, nonce: "AAECAwQFBgcICQoLDA0ODw", body: Data(#"{"a":1}"#.utf8)),
            "quota-run-v1\nPOST\n/api/v1/snapshots\n1789420000\nAAECAwQFBgcICQoLDA0ODw\n015abd7f5cc57a2dd94b7590f04ad8084273905ee33ec5cebeae62276a97f862")
    }

    func testSignedRequestHeadersAndSignature() throws {
        let body = Data(#"{"a":1}"#.utf8)
        let request = try client().signedRequest("POST", "/snapshots", body: body)
        XCTAssertEqual(request.url.absoluteString, "https://quota.run/api/v1/snapshots")
        XCTAssertEqual(request.path, "/api/v1/snapshots")
        XCTAssertEqual(request.headers["X-Quota-Device"], "dev_1")
        XCTAssertEqual(request.headers["X-Quota-Timestamp"], "1789420000")
        XCTAssertEqual(request.headers["X-Quota-Nonce"], "AAECAwQFBgcICQoLDA0ODw")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertFalse(request.canonical.hasSuffix("\n"))
        XCTAssertEqual(request.canonical.split(separator: "\n", omittingEmptySubsequences: false).count, 6)

        // What the server does: the public key from X9.63, the DER signature.
        XCTAssertEqual(signer.publicKeyX963.count, 65)
        let signatureText = try XCTUnwrap(request.headers["X-Quota-Signature"])
        XCTAssertFalse(signatureText.contains("="))
        let publicKey = try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(Base64URL.decode(signatureText)))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(request.canonical.utf8)))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data((request.canonical + "x").utf8)))
    }

    func testOverriddenBaseAndNoDeviceBeforeConnecting() throws {
        let request = try client(base: URL(string: "http://127.0.0.1:8787/api/v1/")!, deviceId: nil).signedRequest("GET", "/me")
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8787/api/v1/me")
        XCTAssertEqual(request.path, "/api/v1/me")
        XCTAssertNil(request.headers["X-Quota-Device"])
        XCTAssertNil(request.headers["Content-Type"])
        XCTAssertTrue(request.canonical.hasSuffix(RunCanonical.bodyHash(nil)))
    }

    func testSnapshotAndActivityJSON() throws {
        let reading = RunReading(provider: "codex", plan: nil, accountDigest: "3f1c", windowKey: "604800:", windowTitle: "Weekly window", windowSeconds: 604_800, scope: nil, usedPercent: 36.5, resetsAt: 1_789_999_200, observedAt: 1_789_420_000, source: "api")
        let body = RunUploadBody(snapshots: [RunSnapshotPayload(reading)], activity: [RunActivityPayload(minute: 1_789_419_960, source: "codex", tokens: 12_840)])
        let data = try QuotaRunClient.encoder.encode(body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshot = try XCTUnwrap((object["snapshots"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(snapshot.keys), ["provider", "plan", "accountDigest", "windowKey", "windowTitle", "windowSeconds", "scope", "usedPercent", "resetsAt", "observedAt", "source"])
        XCTAssertTrue(snapshot["plan"] is NSNull)
        XCTAssertTrue(snapshot["scope"] is NSNull)
        XCTAssertEqual(snapshot["usedPercent"] as? Double, 36.5)
        XCTAssertEqual(snapshot["resetsAt"] as? Int, 1_789_999_200)
        let activity = try XCTUnwrap((object["activity"] as? [[String: Any]])?.first)
        XCTAssertEqual(activity["minute"] as? Int, 1_789_419_960)
        XCTAssertEqual(activity["source"] as? String, "codex")
        XCTAssertEqual(activity["tokens"] as? Int, 12_840)
    }

    /// Records what was sent and answers with a canned response.
    private final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var requests: [(method: String, url: URL, headers: [String: String], body: Data?)] = []
        var answer: HTTPResponse

        init(_ status: Int, _ json: String) {
            answer = HTTPResponse(status: status, data: Data(json.utf8))
        }

        var transport: QuotaRunClient.Transport {
            { method, url, headers, body in
                self.lock.withLock {
                    self.requests.append((method, url, headers, body))
                    return self.answer
                }
            }
        }
    }

    /// Signed like every request, but with no device id: the server checks it
    /// against the public key in the body.
    private func assertSignedWithBodyKey(_ sent: (method: String, url: URL, headers: [String: String], body: Data?), path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(sent.method, "POST", file: file, line: line)
        XCTAssertEqual(sent.url.path, path, file: file, line: line)
        XCTAssertNil(sent.headers["X-Quota-Device"], file: file, line: line)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any])
        let keyText = try XCTUnwrap(object["publicKey"] as? String)
        XCTAssertEqual(keyText, Base64URL.encode(signer.publicKeyX963), file: file, line: line)
        // The signature covers exactly the bytes sent, and verifies with the
        // key they carry.
        let canonical = [
            "quota-run-v1", "POST", path, sent.headers["X-Quota-Timestamp"]!, sent.headers["X-Quota-Nonce"]!,
            RunCanonical.bodyHash(sent.body),
        ].joined(separator: "\n")
        let publicKey = try P256.Signing.PublicKey(x963Representation: try XCTUnwrap(Base64URL.decode(keyText)))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Base64URL.decode(sent.headers["X-Quota-Signature"]!)!)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(canonical.utf8)), file: file, line: line)
    }

    func testConnectStart() async throws {
        let recorder = Recorder(201, #"{"requestId":"req_1","userCode":"KXPT-7M4Q","verifyURL":"https://quota.run/zh/connect?code=KXPT-7M4Q","expiresAt":1789420600,"interval":3}"#)
        // A device id left over on the client still stays off these calls.
        let start = try await client(deviceId: "dev_old", transport: recorder.transport)
            .connectStart(deviceName: " Peter's Studio ", appVersion: "0.6.0", lang: "zh")
        XCTAssertEqual(start.requestId, "req_1")
        XCTAssertEqual(start.userCode, "KXPT-7M4Q")
        XCTAssertEqual(start.verifyURL.absoluteString, "https://quota.run/zh/connect?code=KXPT-7M4Q")
        XCTAssertEqual(start.expiresAt, Date(timeIntervalSince1970: 1_789_420_600))
        XCTAssertEqual(start.interval, 3)

        let sent = try XCTUnwrap(recorder.requests.first)
        try assertSignedWithBodyKey(sent, path: "/api/v1/connect/start")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any])
        XCTAssertEqual(object["deviceName"] as? String, "Peter's Studio")
        XCTAssertEqual(object["platform"] as? String, "macos")
        XCTAssertEqual(object["appVersion"] as? String, "0.6.0")
        XCTAssertEqual(object["lang"] as? String, "zh")
        XCTAssertNil(object["username"])

        // The contract's limits, and a language that follows the interface.
        let long = Recorder(201, #"{"requestId":"r","userCode":"ABCD-EFGH","verifyURL":"https://quota.run/connect?code=ABCD-EFGH","expiresAt":1789420600}"#)
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .en
        let defaults = try await client(transport: long.transport).connectStart(deviceName: String(repeating: "M", count: 80), appVersion: String(repeating: "9", count: 50))
        XCTAssertEqual(defaults.interval, 3, "the contract's interval when none is sent")
        let longBody = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(long.requests.first?.body)) as? [String: Any])
        XCTAssertEqual((longBody["deviceName"] as? String)?.count, 60)
        XCTAssertEqual((longBody["appVersion"] as? String)?.count, 40)
        XCTAssertEqual(longBody["lang"] as? String, "en")

        // Only a web page is ever opened.
        do {
            _ = try await client(transport: Recorder(201, #"{"requestId":"r","userCode":"ABCD-EFGH","verifyURL":"file:///etc/passwd","expiresAt":1789420600}"#).transport)
                .connectStart(deviceName: "Mac", appVersion: "1")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "bad_response")
        }
    }

    func testConnectPollStatuses() async throws {
        let pending = Recorder(200, #"{"status":"pending"}"#)
        let status = try await client(deviceId: nil, transport: pending.transport).connectPoll(requestId: "req_1")
        XCTAssertEqual(status, .pending)
        let sent = try XCTUnwrap(pending.requests.first)
        try assertSignedWithBodyKey(sent, path: "/api/v1/connect/poll")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(sent.body)) as? [String: Any])
        XCTAssertEqual(object["requestId"] as? String, "req_1")

        let denied = try await client(transport: Recorder(200, #"{"status":"denied"}"#).transport).connectPoll(requestId: "req_1")
        XCTAssertEqual(denied, .denied)
        let expired = try await client(transport: Recorder(200, #"{"status":"expired"}"#).transport).connectPoll(requestId: "req_1")
        XCTAssertEqual(expired, .expired)

        let approved = try await client(transport: Recorder(200, #"{"status":"approved","user":{"username":"peter","displayName":"Peter","region":"china"},"deviceId":"dev_9","ranked":true}"#).transport)
            .connectPoll(requestId: "req_1")
        XCTAssertEqual(approved, .approved(RunRegistration(user: RunUser(username: "peter", displayName: "Peter", region: .china), deviceId: "dev_9", ranked: true)))

        do {
            _ = try await client(transport: Recorder(200, #"{"status":"approved","user":{"username":"peter"}}"#).transport).connectPoll(requestId: "req_1")
            XCTFail("an approval without a device id is no approval")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "bad_response")
        }
        do {
            _ = try await client(transport: Recorder(200, #"{"status":"thinking"}"#).transport).connectPoll(requestId: "req_1")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "bad_response")
        }
        do {
            _ = try await client(transport: Recorder(404, #"{"error":"connect_request_invalid","message":"Unknown request."}"#).transport).connectPoll(requestId: "req_x")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.code, "connect_request_invalid")
            XCTAssertFalse(error.isAuthFailure)
        }
    }

    func testErrorMapping() async {
        do {
            _ = try await client(deviceId: nil, transport: Recorder(409, #"{"error":"key_registered","message":"Key is already registered."}"#).transport)
                .connectStart(deviceName: "Mac", appVersion: "1")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "key_registered")
            XCTAssertFalse(error.isAuthFailure)
        } catch {
            XCTFail("unexpected \(error)")
        }

        do {
            _ = try await client(transport: Recorder(401, #"{"error":"bad_signature","message":"Signature did not verify."}"#).transport).me()
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertTrue(error.isAuthFailure)
            XCTAssertEqual(error.code, "bad_signature")
        } catch {
            XCTFail("unexpected \(error)")
        }

        do {
            _ = try await client(transport: Recorder(409, #"{"error":"cooldown","availableAt":1790000000}"#).transport).setRanked(deviceId: "dev_2")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "cooldown")
            XCTAssertEqual(error.availableAt, Date(timeIntervalSince1970: 1_790_000_000))
        } catch {
            XCTFail("unexpected \(error)")
        }

        do {
            _ = try await client(transport: { _, _, _, _ in throw ProviderError.network("offline") }).connectPoll(requestId: "req_1")
            XCTFail("expected an error")
        } catch let error as QuotaRunError {
            XCTAssertEqual(error.code, "network")
            XCTAssertEqual(error.message, "offline")
        } catch {
            XCTFail("unexpected \(error)")
        }

        let odd = QuotaRunError.from(status: 502, body: Data("<html>".utf8))
        XCTAssertEqual(odd.code, "http_502")

        // A 401 over the clock is not a revoked key.
        let skew = QuotaRunError.from(status: 401, body: Data(#"{"error":"stale_timestamp","serverTime":1789419400}"#.utf8), now: Date(timeIntervalSince1970: 1_789_420_000))
        XCTAssertFalse(skew.isAuthFailure)
        XCTAssertEqual(skew.clockSkew, 600)
        XCTAssertTrue(skew.errorDescription?.contains("10") ?? false)
        let limited = QuotaRunError.from(status: 429, body: Data(#"{"error":"rate_limited","retryAfter":42}"#.utf8))
        XCTAssertEqual(limited.retryAfter, 42)
    }

    /// The codes the app can meet get a sentence of their own in both
    /// languages, not the server's English.
    func testErrorMessagesAreTheApps() {
        let saved = L10n.override
        defer { L10n.override = saved }
        let cases: [(Int, String)] = [
            (404, "connect_request_invalid"), (409, "key_registered"), (401, "not_signed_in"), (403, "needs_signup"), (409, "current_device"),
        ]
        for (status, code) in cases {
            let body = Data(#"{"error":"\#(code)","message":"Server sentence."}"#.utf8)
            L10n.override = .en
            let english = QuotaRunError.from(status: status, body: body).errorDescription ?? ""
            L10n.override = .zhHans
            let chinese = QuotaRunError.from(status: status, body: body).errorDescription ?? ""
            XCTAssertFalse(english.isEmpty, code)
            XCTAssertNotEqual(english, "Server sentence.", code)
            XCTAssertNotEqual(english, chinese, code)
            XCTAssertTrue(chinese.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }, code)
        }
        L10n.override = .en
        let revoked = QuotaRunError.from(status: 401, body: Data(#"{"error":"unknown_device"}"#.utf8))
        XCTAssertTrue(revoked.isAuthFailure)
        XCTAssertTrue(revoked.errorDescription?.contains("sign in again") ?? false)
    }

    func testRankedChangeCarriesTheCooldown() async throws {
        let recorder = Recorder(200, #"{"devices":[{"deviceId":"d1","name":"Studio","ranked":true,"current":true}],"rankedChangeAvailableAt":1790604800}"#)
        let change = try await client(transport: recorder.transport).setRanked(deviceId: "d1")
        XCTAssertEqual(change.devices.first?.ranked, true)
        XCTAssertEqual(change.rankedChangeAvailableAt, Date(timeIntervalSince1970: 1_790_604_800))
        let free = try await client(transport: Recorder(200, #"{"devices":[],"rankedChangeAvailableAt":null}"#).transport).setRanked(deviceId: "d1")
        XCTAssertNil(free.rankedChangeAvailableAt)
    }

    func testMeDecodesLeniently() async throws {
        let json = #"""
        {"user":{"username":"peter","displayName":"Peter","bio":null,"region":"mars","links":{"website":"https://a.dev","github":null},"joinedAt":"2026-09-01T10:00:00Z"},
         "devices":[{"deviceId":"d1","name":"Studio","ranked":true,"lastSeenAt":1789420000000,"current":true,"appVersion":"0.6.0"},{"deviceId":"d2","name":"Air","ranked":false,"lastSeenAt":null,"current":false,"appVersion":null}],
         "identities":[{"id":"i1","provider":"github","email":"peter@example.com","name":"gentpan","linkedAt":1789000000},{"id":7,"provider":"google","email":"peter@example.com","name":"Peter Pan"},{"id":"i3","provider":"email","email":"peter@example.com","name":null}],
         "rankedChangeAvailableAt":1790000000,"lastUploadAt":null,"projects":[{"name":"QuotaBar","url":"https://quota.bar","description":"Limits","builtWith":["codex","claude"]}]}
        """#
        let me = try await client(transport: Recorder(200, json).transport).me()
        XCTAssertEqual(me.user.region, .global)
        XCTAssertEqual(me.user.bio, "")
        XCTAssertEqual(me.user.links.website, "https://a.dev")
        XCTAssertEqual(me.user.joinedAt, Dates.parseISO("2026-09-01T10:00:00Z"))
        XCTAssertEqual(me.devices.first?.lastSeenAt, Date(timeIntervalSince1970: 1_789_420_000))
        XCTAssertEqual(me.currentDevice?.deviceId, "d1")
        XCTAssertEqual(me.rankedChangeAvailableAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertNil(me.lastUploadAt)
        XCTAssertEqual(me.projects.first?.builtWith, ["codex", "claude"])
        XCTAssertEqual(me.devices.map(\.appVersion), ["0.6.0", nil])
        XCTAssertEqual(me.identities.map(\.id), ["i1", "7", "i3"])
        XCTAssertEqual(me.identities.first?.linkedAt, Date(timeIntervalSince1970: 1_789_000_000))
        let saved = L10n.override
        defer { L10n.override = saved }
        L10n.override = .en
        XCTAssertEqual(me.identities.map(\.label), ["GitHub · gentpan", "Google · peter@example.com", "Email · peter@example.com"])
        L10n.override = .zhHans
        XCTAssertEqual(me.identities.last?.label, "邮箱 · peter@example.com")

        // A server from before sign-in methods: none, not a failure.
        let older = try await client(transport: Recorder(200, #"{"user":{"username":"peter"},"devices":[{"deviceId":"d1"}]}"#).transport).me()
        XCTAssertEqual(older.identities, [])
        XCTAssertNil(older.devices.first?.appVersion)

        // And back through the state file.
        let encoder = JSONEncoder()
        let again = try JSONDecoder().decode(RunMe.self, from: encoder.encode(me))
        XCTAssertEqual(again, me)
    }

    func testProjectsAndProfileBodies() async throws {
        let recorder = Recorder(200, #"{"projects":[]}"#)
        _ = try await client(transport: recorder.transport).updateProjects([RunProject(name: "A", url: "https://a.dev", description: "d", github: " ", builtWith: ["codex"])])
        let text = String(decoding: try XCTUnwrap(recorder.requests.first?.body), as: UTF8.self)
        XCTAssertFalse(text.contains("github"), "a blank optional address is left out")
        XCTAssertEqual(recorder.requests.first?.method, "PUT")

        let profile = Recorder(200, #"{"user":{"username":"peter","displayName":"P","region":"global"}}"#)
        _ = try await client(transport: profile.transport).updateProfile(.init(displayName: "P", bio: "", region: .global, links: RunLinks(website: "https://a.dev", github: "", x: nil)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(profile.requests.first?.body)) as? [String: Any])
        let links = try XCTUnwrap(object["links"] as? [String: Any])
        XCTAssertEqual(links["website"] as? String, "https://a.dev")
        XCTAssertTrue(links["github"] is NSNull)
        XCTAssertTrue(links["x"] is NSNull)

        XCTAssertNil(RunProject(name: "A", url: "https://a.dev").problem)
        XCTAssertNotNil(RunProject(name: "A", url: "http://a.dev").problem)
        XCTAssertNotNil(RunProject(name: " ", url: "https://a.dev").problem)
        XCTAssertNil(RunProject(name: "A", url: "https://a.dev", github: "gentpan/QuotaBar").problem, "the server expands owner/repo")
        XCTAssertNil(RunProject(name: "A", url: "https://a.dev", github: "https://github.com/gentpan/QuotaBar").problem)
        XCTAssertNotNil(RunProject(name: "A", url: "https://a.dev", github: "http://github.com/a").problem)
        XCTAssertTrue(RunProject.isHandleOrHTTPS("@gentpan"))
        XCTAssertTrue(RunProject.isHandleOrHTTPS("httpster"))
        XCTAssertFalse(RunProject.isHandleOrHTTPS("ftp://x.dev"))
    }

    func testDeleteDeviceEscapesTheID() async throws {
        let recorder = Recorder(200, #"{"devices":[]}"#)
        _ = try await client(transport: recorder.transport).deleteDevice("d/1")
        XCTAssertEqual(recorder.requests.first?.url.absoluteString, "https://quota.run/api/v1/devices/d%2F1")
        XCTAssertEqual(recorder.requests.first?.method, "DELETE")
        let gone = Recorder(204, "")
        try await client(transport: gone.transport).deleteAccount()
        XCTAssertEqual(gone.requests.first?.url.path, "/api/v1/account")
        XCTAssertEqual(gone.requests.first?.method, "DELETE")
    }

    func testDisconnectCurrentDevice() async throws {
        let recorder = Recorder(204, "")
        try await client(transport: recorder.transport).disconnectCurrentDevice()
        let sent = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(sent.method, "DELETE")
        XCTAssertEqual(sent.url.absoluteString, "https://quota.run/api/v1/devices/current")
        XCTAssertEqual(sent.headers["X-Quota-Device"], "dev_1")
        XCTAssertNil(sent.body)
        let canonical = ["quota-run-v1", "DELETE", "/api/v1/devices/current", sent.headers["X-Quota-Timestamp"]!, sent.headers["X-Quota-Nonce"]!, RunCanonical.bodyHash(nil)].joined(separator: "\n")
        let signature = try P256.Signing.ECDSASignature(derRepresentation: Base64URL.decode(sent.headers["X-Quota-Signature"]!)!)
        XCTAssertTrue(try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963).isValidSignature(signature, for: Data(canonical.utf8)))

        XCTAssertEqual(RunAccountState.accountURL(chinese: false).absoluteString, "https://quota.run/account")
        XCTAssertEqual(RunAccountState.accountURL(chinese: true).absoluteString, "https://quota.run/zh/account")
    }
}

// MARK: - Upload planning and activity

final class RunUploadTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var clock: Int { Int(now.timeIntervalSince1970) }

    private func reading(seq: Int, observed: Int) -> RunReading {
        RunReading(seq: seq, provider: "codex", windowKey: "604800:", windowTitle: "Weekly window", windowSeconds: 604_800, usedPercent: 1, resetsAt: nil, observedAt: observed)
    }

    func testCursorSkipsWhatTheServerWouldRefuse() {
        var state = RunUploadState()
        state.sentSeq = 1
        let readings = [
            reading(seq: 1, observed: clock - 100),
            reading(seq: 2, observed: clock - 8 * 86_400),
            reading(seq: 3, observed: clock - 60),
            reading(seq: 4, observed: clock + 3_600),
        ]
        let batch = RunUploadPlan.batch(readings: readings, activity: ActivityMinutes(), state: state, now: now)
        XCTAssertEqual(batch.snapshots.map(\.observedAt), [clock - 60])
        XCTAssertEqual(batch.sentSeq, 4)
        XCTAssertFalse(batch.hasMore)
    }

    func testReadingsOutsideTheirWindowStayHome() {
        let window = RunReading(seq: 1, provider: "claude", windowKey: "18000:", windowTitle: "5-hour window", windowSeconds: 18_000, usedPercent: 3, resetsAt: clock + 1_000, observedAt: clock - 100)
        var stale = window
        stale.seq = 2
        stale.resetsAt = clock - 500  // last period's reset, reported after the roll-over
        var edge = window
        edge.seq = 3
        edge.resetsAt = clock - 250
        XCTAssertTrue(RunMath.isInsideWindow(window))
        XCTAssertFalse(RunMath.isInsideWindow(stale))
        XCTAssertTrue(RunMath.isInsideWindow(edge), "five minutes of slack")
        let batch = RunUploadPlan.batch(readings: [window, stale, edge], activity: ActivityMinutes(), state: RunUploadState(), now: now)
        XCTAssertEqual(batch.snapshots.count, 2)
        XCTAssertEqual(batch.sentSeq, 3)
        XCTAssertEqual(RunMath.runs(from: [stale]).count, 0, "nor does it count locally")
    }

    func testSnapshotLimit() {
        let readings = (1...600).map { reading(seq: $0, observed: clock - 1_000 + $0) }
        let batch = RunUploadPlan.batch(readings: readings, activity: ActivityMinutes(), state: RunUploadState(), now: now)
        XCTAssertEqual(batch.snapshots.count, 500)
        XCTAssertEqual(batch.sentSeq, 500)
        XCTAssertTrue(batch.hasMore)
    }

    func testActivityGoesByWholeMinutes() {
        let base = ActivityMinutes.floor(now) - 2_000 * 60
        var minutes: [Int: [String: Int]] = [:]
        for index in 0..<1_439 { minutes[base + index * 60] = ["codex": 10] }
        minutes[base + 1_439 * 60] = ["claude": 1, "codex": 2]
        minutes[ActivityMinutes.floor(now)] = ["codex": 99]
        let activity = ActivityMinutes(scannedAt: now, minutes: minutes)
        let batch = RunUploadPlan.batch(readings: [], activity: activity, state: RunUploadState(), now: now)
        XCTAssertEqual(batch.activity.count, 1_439, "the two-source minute would split at 1,440")
        XCTAssertEqual(batch.activityMinute, base + 1_438 * 60)
        XCTAssertTrue(batch.hasMore)

        var state = RunUploadState()
        state.activityMinute = batch.activityMinute
        let next = RunUploadPlan.batch(readings: [], activity: activity, state: state, now: now)
        XCTAssertEqual(next.activity.map(\.source), ["claude", "codex"], "the open minute waits")
        XCTAssertFalse(next.hasMore)
    }

    func testBackoff() {
        XCTAssertEqual(RunUploadPlan.backoff(failures: 0), 0)
        XCTAssertEqual(RunUploadPlan.backoff(failures: 1), 60)
        XCTAssertEqual(RunUploadPlan.backoff(failures: 2), 120)
        XCTAssertEqual(RunUploadPlan.backoff(failures: 7), 3_600)
        XCTAssertEqual(RunUploadPlan.backoff(failures: 100), 3_600)
    }

    func testStateFileRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("run-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var file = RunStateFile()
        file.account = RunAccountState(username: "peter", displayName: "Peter", region: .china, deviceId: "d1", joinedAt: Date(timeIntervalSince1970: 1_789_000_000), ranked: true,
                                       me: RunMe(user: RunUser(username: "peter", displayName: "Peter"), devices: [RunDevice(deviceId: "d1", name: "Studio", ranked: true, current: true)]))
        file.upload.sentSeq = 42
        file.upload.retryAt = Date(timeIntervalSince1970: 1_790_000_000)
        file.save(to: url)
        XCTAssertEqual(RunStateFile.load(from: url), file)
        XCTAssertEqual(file.account?.profileURL.absoluteString, "https://quota.run/@peter")
        try Data(#"{"account":{"username":"x"},"upload":{"sentSeq":"many","failures":2}}"#.utf8).write(to: url)
        let damaged = RunStateFile.load(from: url)
        XCTAssertNil(damaged.account, "no device id, no membership")
        XCTAssertEqual(damaged.upload.sentSeq, 0)
        XCTAssertEqual(damaged.upload.failures, 2)
    }
}

/// The minutes come out of the archive's own pass over the logs.
final class ActivityMinutesTests: XCTestCase {
    private var root: URL!
    private var paths: CostPaths!
    private let now = ISO8601DateFormatter().date(from: "2026-08-26T12:00:30Z")!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quotabar-activity-\(UUID().uuidString)")
        let claude = root.appendingPathComponent("claude")
        let codex = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        paths = CostPaths(claudeProjects: claude, codexSessions: codex)
        CostEstimator.resetCache()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        CostEstimator.resetCache()
    }

    private func claude(_ id: String, _ timestamp: String, input: Int = 0, output: Int = 0) -> String {
        #"{"type":"assistant","requestId":"r\#(id)","timestamp":"\#(timestamp)","message":{"id":"m\#(id)","model":"claude-opus-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_read_input_tokens":0}}}"#
    }

    func testBucketsPerMinuteAndSource() throws {
        try [
            claude("1", "2026-08-26T11:59:10.000Z", output: 100),
            claude("2", "2026-08-26T11:59:50.000Z", input: 50),
            claude("3", "2026-08-24T10:00:00.000Z", output: 7),
            claude("4", "2026-08-26T12:00:10.000Z", output: 5),
        ].joined(separator: "\n").write(to: paths.claudeProjects.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        // A replayed turn in another session file counts once.
        try claude("1", "2026-08-26T11:59:10.000Z", output: 100)
            .write(to: paths.claudeProjects.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"event_msg","timestamp":"2026-08-26T11:30:05.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":10}}}}"#
            .write(to: paths.codexSessions.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)

        let scan = CostEstimator.archiveScan(paths: paths, since: .distantPast, now: now)
        let minute = { (text: String) in Int(ISO8601DateFormatter().date(from: text)!.timeIntervalSince1970) }
        XCTAssertEqual(scan.activity.minutes[minute("2026-08-26T11:59:00Z")], ["claude": 150])
        XCTAssertEqual(scan.activity.minutes[minute("2026-08-26T11:30:00Z")], ["codex": 1_010])
        XCTAssertEqual(scan.activity.minutes[minute("2026-08-26T12:00:00Z")], ["claude": 5])
        XCTAssertEqual(scan.activity.minutes.count, 3, "two days back is the horizon")
        XCTAssertFalse(scan.days.isEmpty, "the archive still gets everything")

        let entries = scan.activity.completeEntries(after: 0)
        XCTAssertEqual(entries.map(\.minute), [minute("2026-08-26T11:30:00Z"), minute("2026-08-26T11:59:00Z")], "the minute being scanned in waits")
        XCTAssertTrue(scan.activity.hasTokens(source: "codex", from: minute("2026-08-26T11:30:30Z"), to: minute("2026-08-26T11:31:00Z")))
        XCTAssertFalse(scan.activity.hasTokens(source: "claude", from: minute("2026-08-26T11:00:00Z"), to: minute("2026-08-26T11:10:00Z")))
        XCTAssertEqual(ActivityMinutes.floor(Date(timeIntervalSince1970: 119.9)), 60)
    }
}
