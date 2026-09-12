import SwiftUI
import QuotaCore

/// A dot and two words: "● 服务正常". The dot carries the band, the words
/// say it for anyone who cannot tell teal from amber, and the tooltip says
/// where the reading comes from.
struct ServiceStatusBadge: View {
    let status: ServiceStatus
    var size: CGFloat = 11
    /// nil = the surface's secondary text colour.
    var ink: Color? = nil

    var body: some View {
        HStack(spacing: Design.space1) {
            Circle()
                .fill(Color(hex: status.level.colorHex))
                .frame(width: 6, height: 6)
            Text(status.level.displayName)
                .font(.system(size: size))
                .foregroundStyle(ink ?? Color.secondary)
                .lineLimit(1)
        }
        .help(status.sourceNote)
        .accessibilityLabel(status.level.displayName)
    }
}

extension ServiceStatus {
    /// What the badge is reporting and from where: the provider's own public
    /// status page, judged by the coding components, and when it was read.
    /// Not the local session and not QuotaBar's own reading of the quota.
    var sourceNote: String {
        let host = pageURL.host ?? pageURL.absoluteString
        var lines = [description]
        if focus.isEmpty {
            lines.append(L10n.t("From the official status page \(host).", "来自官方状态页 \(host)。"))
        } else {
            let parts = focus.joined(separator: L10n.t(", ", "、"))
            lines.append(L10n.t(
                "From the official status page \(host), judged by \(parts).",
                "来自官方状态页 \(host)，按 \(parts) 判断。"))
        }
        lines.append(L10n.t("Checked \(QuotaFormat.age(of: checkedAt)).", "\(QuotaFormat.age(of: checkedAt))检查。"))
        return lines.joined(separator: "\n")
    }
}
