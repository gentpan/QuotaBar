import Foundation

// MARK: - Which windows a card shows before it is expanded

public extension UsageSnapshot {
    /// The windows a provider card shows up front; the rest wait under its
    /// disclosure arrow.
    ///
    /// Codex and Claude show the plan's own limits — the windows no model
    /// scope applies to — in the order the provider reports them. So a Codex
    /// plan with a 5-hour limit shows the 5-hour and the week, and Pro, which
    /// has no 5-hour limit, the week alone; GPT-5.3-Codex-Spark's limits stay
    /// folded. Claude also puts its per-model limits up front (Fable, the
    /// newest model's week), so it shows the 5-hour, the week and Fable.
    ///
    /// Other providers keep the two most useful windows: the one the ring
    /// follows, then the first of the other horizon.
    ///
    /// `picked` is the window the owner chose for the ring: it is always up
    /// front, since the card marks it.
    func upFrontWindows(for provider: ProviderID, picked: String? = nil) -> [UsageWindow] {
        let chosen: [UsageWindow]
        switch provider {
        case .codex, .claude:
            let plan = windows.filter { $0.scope == nil || (provider == .claude && $0.usedPercent != nil) }
            chosen = plan.isEmpty ? Array(windows.prefix(1)) : plan
        default:
            chosen = twoMostUseful(picked: picked)
        }
        var ids = Set(chosen.map(\.id))
        if let picked, !ids.contains(picked), windows.contains(where: { $0.id == picked }) {
            ids.insert(picked)
        }
        return windows.filter { ids.contains($0.id) }
    }

    private func twoMostUseful(picked: String?) -> [UsageWindow] {
        let withFigures = windows.filter { $0.usedPercent != nil }
        guard let lead = headlineWindow(preferring: picked) ?? withFigures.first else {
            return Array(windows.prefix(2))
        }
        var chosen = [lead]
        if let other = withFigures.first(where: { $0.id != lead.id && $0.horizon != lead.horizon && $0.scope == nil })
            ?? withFigures.first(where: { $0.id != lead.id })
        {
            chosen.append(other)
        }
        return chosen
    }
}
