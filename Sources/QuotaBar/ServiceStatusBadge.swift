import SwiftUI
import QuotaCore

/// A dot and two words: "● 运行正常". The dot carries the band, the words
/// say it for anyone who cannot tell teal from amber, and the page's own
/// sentence is the tooltip.
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
        .help(status.description)
        .accessibilityLabel(status.level.displayName)
    }
}
