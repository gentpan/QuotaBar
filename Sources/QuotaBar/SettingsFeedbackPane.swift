import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Feedback

/// A form, not a mailto: the text goes to quota.bar's own receiver, which
/// files it and opens an issue where it can. Nobody has to sign in.
struct FeedbackPane: View {
    @ObservedObject var store: UsageStore
    @State private var kind: FeedbackKind = .bug
    @State private var message = ""
    @State private var contact = ""
    @State private var includeDiagnostics = true
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case sending
        case sent(FeedbackReceipt)
        case failed(String)
    }

    private var macos: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    private var diagnostics: [String: String] {
        [
            L10n.t("Providers", "服务商"): store.enabled.map(\.displayName).joined(separator: ", "),
            L10n.t("Presentation", "展示方式"): store.presentation.displayName,
            L10n.t("Menu bar", "菜单栏"): store.menuBarIconMode.displayName,
        ]
    }

    private var canSend: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && phase != .sending
    }

    var body: some View {
        SettingsCard {
            SettingRow(L10n.t("Kind", "类型")) {
                GlassSegmented(
                    options: FeedbackKind.allCases.map { (value: $0, label: $0.displayName) },
                    selection: kind,
                    onSelect: { kind = $0 })
                .frame(maxWidth: 300)
            }
            SettingRow(L10n.t("Message", "内容")) {
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(Design.space2)
                    .frame(minHeight: 132)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous)
                            .fill(Design.fieldFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous)
                            .strokeBorder(Design.glassEdge, lineWidth: 1))
            }
            SettingRow(L10n.t("Contact", "联系方式"), caption: L10n.t("Optional.", "选填。")) {
                GlassTextField(
                    placeholder: L10n.t("Email, or where to reply", "邮箱，或其他能回复你的方式"),
                    text: $contact,
                    monospaced: false)
            }
            SettingToggle(
                L10n.t("Include version and setup", "附带版本与配置信息"),
                caption: "QuotaBar \(SettingsView.version) · macOS \(macos) · \(diagnostics.values.joined(separator: " · "))",
                isOn: $includeDiagnostics)
            HStack(spacing: Design.space3) {
                Spacer().frame(width: Design.labelColumn + Design.space3 - Design.space3)
                Button(phase == .sending ? L10n.t("Sending…", "发送中…") : L10n.t("Send", "发送")) { send() }
                    .glassAction(prominent: true)
                    .disabled(!canSend)
                result
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .idle, .sending:
            EmptyView()
        case let .sent(receipt):
            HStack(spacing: Design.space2) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.t("Received, thank you. #\(receipt.id)", "已收到，谢谢。编号 \(receipt.id)"))
                    .font(.system(size: 12))
                if let url = receipt.issueURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(L10n.t("View on GitHub", "在 GitHub 上查看"), systemImage: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        case let .failed(reason):
            HStack(spacing: Design.space2) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(L10n.t("Could not send (\(reason)).", "没发出去（\(reason)）。"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Button(L10n.t("Open a GitHub issue instead", "改在 GitHub 提交")) {
                    NSWorkspace.shared.open(FeedbackClient.issueURL(
                        kind: kind, message: message, app: SettingsView.version, macos: macos))
                }
                .glassAction()
            }
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending
        let kind = kind, contact = contact, app = SettingsView.version, macos = macos
        let diagnostics = includeDiagnostics ? diagnostics : [:]
        let locale = L10n.t("en", "zh-Hans")
        Task {
            do {
                let receipt = try await FeedbackClient.submit(
                    kind: kind, message: text, contact: contact,
                    app: app, macos: macos, locale: locale, diagnostics: diagnostics)
                phase = .sent(receipt)
                message = ""
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
