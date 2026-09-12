import Security
import XCTest
@testable import QuotaCore

/// The Claude lookup never touches the real keychain here — that would prompt
/// on the developer's Mac and leak state between runs. What is pinned is the
/// mapping from what the keychain said to what the app does about it.
final class LocalCredentialsClaudeTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: Status → state

    func testASuccessfulReadWithATokenIsAvailable() {
        let lookup = LocalCredentials.classify(
            status: errSecSuccess,
            data: json(#"{"claudeAiOauth":{"accessToken":"sk-ant-abc"}}"#))
        XCTAssertEqual(lookup.state, .available)
        XCTAssertEqual(lookup.token, "sk-ant-abc")
    }

    func testASuccessfulReadWithoutATokenIsMissing() {
        let lookup = LocalCredentials.classify(status: errSecSuccess, data: json(#"{"other":1}"#))
        XCTAssertEqual(lookup.state, .missing)
        XCTAssertNil(lookup.token)
    }

    func testNoItemIsMissing() {
        XCTAssertEqual(LocalCredentials.classify(status: errSecItemNotFound, data: nil).state, .missing)
    }

    /// The three answers that mean "macOS would ask, or did ask and was told
    /// no". The documented one, the one macOS 27 actually returns for a
    /// suppressed dialog, and the user pressing Deny.
    func testAnAnswerThatNeedsTheUserIsNeedsAuthorization() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            let lookup = LocalCredentials.classify(status: status, data: nil)
            XCTAssertEqual(lookup.state, .needsAuthorization, "status \(status)")
            XCTAssertNil(lookup.token, "status \(status)")
        }
    }

    func testAnUnknownFailureIsMissingNotAPrompt() {
        // Anything else must not turn into a button that raises the dialog.
        XCTAssertEqual(LocalCredentials.classify(status: errSecParam, data: nil).state, .missing)
    }

    // MARK: Token extraction

    func testFallsBackToTheLegacyTopLevelToken() {
        XCTAssertEqual(LocalCredentials.extractClaudeToken(json(#"{"accessToken":"legacy"}"#)), "legacy")
    }

    func testAnEmptyTokenCountsAsNoToken() {
        XCTAssertNil(LocalCredentials.extractClaudeToken(json(#"{"claudeAiOauth":{"accessToken":""}}"#)))
        XCTAssertNil(LocalCredentials.extractClaudeToken(json(#"{"accessToken":""}"#)))
        XCTAssertNil(LocalCredentials.extractClaudeToken(json("not json")))
    }

    // MARK: Plan

    func testThePlanComesFromTheRateLimitTierFirst() {
        let root: [String: Any] = ["claudeAiOauth": [
            "accessToken": "t", "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"]]
        XCTAssertEqual(LocalCredentials.claudePlan(root), "Max 20x")
        XCTAssertEqual(LocalCredentials.claudePlan(["claudeAiOauth": ["rateLimitTier": "default_claude_pro"]]), "Pro")
    }

    func testThePlanFallsBackToTheSubscriptionType() {
        XCTAssertEqual(LocalCredentials.claudePlan(["claudeAiOauth": ["subscriptionType": "max"]]), "Max")
        XCTAssertNil(LocalCredentials.claudePlan(["claudeAiOauth": ["accessToken": "t"]]))
    }

    func testASuccessfulReadCarriesThePlan() {
        let lookup = LocalCredentials.classify(
            status: errSecSuccess,
            data: json(#"{"claudeAiOauth":{"accessToken":"t","rateLimitTier":"default_claude_max_5x"}}"#))
        XCTAssertEqual(lookup.plan, "Max 5x")
    }

    // MARK: The security tool

    /// The tool prints the item and a newline; the plan rides along as it
    /// does for the direct read.
    func testTheToolsOutputIsTheItem() {
        let lookup = LocalCredentials.SecurityTool.classifyToolResult(
            exitCode: 0,
            output: json(#"{"claudeAiOauth":{"accessToken":"sk-ant-abc","rateLimitTier":"default_claude_max_20x"}}"# + "\n"))
        XCTAssertEqual(lookup?.state, .available)
        XCTAssertEqual(lookup?.token, "sk-ant-abc")
        XCTAssertEqual(lookup?.plan, "Max 20x")
        XCTAssertEqual(lookup?.via, .securityTool)
    }

    func testTheToolFindingNoItemIsMissing() {
        let lookup = LocalCredentials.SecurityTool.classifyToolResult(exitCode: 44, output: Data())
        XCTAssertEqual(lookup?.state, .missing)
        XCTAssertNil(lookup?.token)
    }

    /// Refusals do not become a verdict of their own: the direct read already
    /// said "needs the user", and that is what stays on screen.
    func testTheToolBeingRefusedLeavesTheDirectVerdict() {
        for code in [36, 51, 128] as [Int32] {
            XCTAssertNil(LocalCredentials.SecurityTool.classifyToolResult(exitCode: code, output: Data()), "exit \(code)")
            XCTAssertTrue(LocalCredentials.SecurityTool.refusals.contains(code), "exit \(code)")
        }
        XCTAssertNil(LocalCredentials.SecurityTool.classifyToolResult(exitCode: 1, output: Data()))
    }

    /// Bytes the tool will not print as text come out as hex.
    func testHexOutputIsDecoded() {
        let item = #"{"claudeAiOauth":{"accessToken":"sk-ant-hex"}}"#
        let hex = item.utf8.map { String(format: "%02x", $0) }.joined() + "\n"
        let lookup = LocalCredentials.SecurityTool.classifyToolResult(exitCode: 0, output: json(hex))
        XCTAssertEqual(lookup?.state, .available)
        XCTAssertEqual(lookup?.token, "sk-ant-hex")
    }

    func testAnItemThatStartsWithABraceIsNotTakenForHex() {
        XCTAssertEqual(LocalCredentials.SecurityTool.secret(from: json("{}\r\n")), json("{}"))
    }

    // MARK: The process-wide switch

    /// The switch is global to the process, so leaving it off would silence
    /// every keychain read the app makes afterwards, including the ones that
    /// legitimately should ask.
    func testWithoutPromptsRestoresTheSwitch() {
        let before = LocalCredentials.KeychainUI.isInteractionAllowed
        var inside: Bool?
        LocalCredentials.KeychainUI.withoutPrompts {
            inside = LocalCredentials.KeychainUI.isInteractionAllowed
        }
        XCTAssertEqual(inside, false, "the dialog is suppressed inside the block")
        XCTAssertEqual(LocalCredentials.KeychainUI.isInteractionAllowed, before, "and back to how it was after")
    }

    func testWithoutPromptsReturnsTheBodyValue() {
        XCTAssertEqual(LocalCredentials.KeychainUI.withoutPrompts { 42 }, 42)
    }
}
