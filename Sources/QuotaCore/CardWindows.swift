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
    /// front, since the card marks it. `shown` is the owner's own choice from
    /// the card's menu, used while any of it still matches a window — window
    /// ids are the provider's titles, and a language switch renames them.
    func upFrontWindows(for provider: ProviderID, picked: String? = nil, shown: [String]? = nil) -> [UsageWindow] {
        let chosen: [UsageWindow]
        if let shown, case let matching = windows.filter({ shown.contains($0.id) }), !matching.isEmpty {
            chosen = matching
        } else {
            chosen = defaultUpFront(for: provider, picked: picked)
        }
        var ids = Set(chosen.map(\.id))
        if let picked, !ids.contains(picked), windows.contains(where: { $0.id == picked }) {
            ids.insert(picked)
        }
        return windows.filter { ids.contains($0.id) }
    }

    private func defaultUpFront(for provider: ProviderID, picked: String?) -> [UsageWindow] {
        let chosen: [UsageWindow]
        switch provider {
        case .codex, .claude:
            let plan = windows.filter { $0.scope == nil || (provider == .claude && $0.usedPercent != nil) }
            chosen = plan.isEmpty ? Array(windows.prefix(1)) : plan
        default:
            chosen = twoMostUseful(picked: picked)
        }
        return chosen
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

// MARK: - Window choices across a language switch

public enum WindowRename {
    /// Old window id → new, for the same limits read in another language.
    ///
    /// Window ids are the provider's own titles — "周窗口" in Chinese, "Weekly
    /// window" in English — and the owner's picks (what the ring follows,
    /// what a card shows) are kept by id. Switching the language rereads every
    /// provider; this lines the two readings up so the picks follow. A window
    /// pairs with the one of the same length and the same kind (plan-wide or
    /// model-scoped) in the same place among its kind; anything ambiguous is
    /// left out rather than guessed.
    public static func pairs(from old: [UsageWindow], to new: [UsageWindow]) -> [String: String] {
        func signature(_ window: UsageWindow) -> String {
            "\(window.windowSeconds ?? -1)|\(window.scope == nil ? "plan" : "scoped")"
        }
        let oldGroups = Dictionary(grouping: old, by: signature)
        let newGroups = Dictionary(grouping: new, by: signature)
        var result: [String: String] = [:]
        for (key, olds) in oldGroups {
            guard let news = newGroups[key], news.count == olds.count else { continue }
            for (from, to) in zip(olds, news) where from.id != to.id {
                result[from.id] = to.id
            }
        }
        return result
    }
}
