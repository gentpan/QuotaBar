import Foundation

// MARK: - Feedback (posted to quota.bar, no account needed)

public enum FeedbackKind: String, CaseIterable, Identifiable, Sendable {
    case bug
    case idea
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bug: L10n.t("Problem", "问题")
        case .idea: L10n.t("Idea", "建议")
        case .other: L10n.t("Other", "其他")
        }
    }
}

public struct FeedbackReceipt: Sendable, Equatable {
    public let id: String
    public let issueURL: URL?
}

/// The form in Settings goes to the site's own receiver, which files it
/// and — when the server holds a token — opens a GitHub issue on the
/// sender's behalf. Nothing here needs the user to sign in anywhere.
public enum FeedbackClient {
    public static let endpoint = URL(string: "https://quota.bar/api/feedback")!
    /// Where to send people when the receiver is unreachable: a new-issue
    /// page with the text already in it. That one does need a GitHub login.
    public static let issuesURL = URL(string: "https://github.com/gentpan/quotabar/issues/new")!

    struct Receipt: Decodable {
        let ok: Bool?
        let id: String?
        let issue_url: String?
        let error: String?
    }

    public static func submit(
        kind: FeedbackKind,
        message: String,
        contact: String,
        app: String,
        macos: String,
        locale: String,
        diagnostics: [String: String]) async throws -> FeedbackReceipt
    {
        let payload: [String: Any] = [
            "kind": kind.rawValue,
            "message": message,
            "contact": contact,
            "app": app,
            "macos": macos,
            "locale": locale,
            "diagnostics": diagnostics,
        ]
        let body = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let response = try await HTTP.post(endpoint, headers: ["Accept": "application/json", "User-Agent": "QuotaBar"], jsonBody: body)
        let receipt = try? response.json(Receipt.self)
        guard response.status == 200, receipt?.ok == true, let id = receipt?.id else {
            throw ProviderError.network(receipt?.error ?? "HTTP \(response.status)")
        }
        return FeedbackReceipt(id: id, issueURL: receipt?.issue_url.flatMap(URL.init(string:)))
    }

    /// The fallback page, with the message filled in.
    public static func issueURL(kind: FeedbackKind, message: String, app: String, macos: String) -> URL {
        var components = URLComponents(url: issuesURL, resolvingAgainstBaseURL: false)!
        let firstLine = message.split(separator: "\n").first.map(String.init) ?? ""
        components.queryItems = [
            URLQueryItem(name: "title", value: "[\(kind.displayName)] \(String(firstLine.prefix(72)))"),
            URLQueryItem(name: "body", value: "\(message)\n\n---\n- 版本：\(app) · macOS \(macos)"),
            URLQueryItem(name: "labels", value: "feedback"),
        ]
        return components.url ?? issuesURL
    }
}
