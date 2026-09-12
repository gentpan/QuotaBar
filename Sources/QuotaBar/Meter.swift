import SwiftUI
import QuotaCore

/// One quota bar, in whichever style the owner has chosen.
///
/// Stepped: a row of short segments, as many as the width takes at 5pt plus
/// a 2pt gap — codex-island's bar, which lights its segments one by one. The
/// count follows the width, so the callout's 236pt gets about 34 and a
/// widget row's 180 about 26, and the segments look the same everywhere.
/// Continuous: the capsule the app started with.
struct Meter: View {
    /// Used percentage; nil draws the empty track.
    let percent: Double?
    let tint: Color
    var style: MeterStyle
    var height: CGFloat = 5
    var track: Color = Color.white.opacity(0.16)

    private static let segment: CGFloat = 5
    private static let gap: CGFloat = 2

    var body: some View {
        switch style {
        case .continuous:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(track)
                    if let percent, percent > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, proxy.size.width * CGFloat(min(percent, 100) / 100)))
                    }
                }
            }
            .frame(height: height)
        case .stepped:
            GeometryReader { proxy in
                let count = max(8, Int((proxy.size.width + Self.gap) / (Self.segment + Self.gap)))
                let width = (proxy.size.width - Self.gap * CGFloat(count - 1)) / CGFloat(count)
                // Rounded to the nearest segment, and at least one once
                // anything is used: 1% on 34 segments is still a lit bar.
                let lit = percent.map { value -> Int in
                    guard value > 0 else { return 0 }
                    return max(1, Int((Double(count) * min(value, 100) / 100).rounded()))
                } ?? 0
                HStack(spacing: Self.gap) {
                    ForEach(0..<count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(index < lit ? tint : track)
                            .frame(width: width)
                    }
                }
            }
            .frame(height: height + 3)
        }
    }
}
