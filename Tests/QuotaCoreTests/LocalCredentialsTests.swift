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
