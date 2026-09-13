import Foundation

/// The resets coming up across providers, by day: when each window starts
/// again over the next week.
public enum ResetSchedule {
    public struct Entry: Sendable, Identifiable {
        public var provider: ProviderID
        public var window: UsageWindow
        public var at: Date
        public var id: String { "\(provider.rawValue)|\(window.id)" }
    }

    public struct Day: Sendable, Identifiable {
        /// Local midnight.
        public var day: Date
        public var entries: [Entry]
        public var id: TimeInterval { day.timeIntervalSince1970 }
    }

    /// Windows resetting after `now` and within `days` days, earliest first,
    /// grouped by local day. A window already past its reset time is left
    /// out: it resets when the provider says so, not on a clock.
    public static func upcoming(
        _ readings: [(ProviderID, UsageSnapshot)],
        days: Int = 7,
        now: Date = Date(),
        calendar: Calendar = .current) -> [Day]
    {
        guard let horizon = calendar.date(byAdding: .day, value: days, to: now) else { return [] }
        var entries: [Entry] = []
        for (provider, snapshot) in readings {
            for window in snapshot.windows {
                guard let at = window.resetsAt, at > now, at <= horizon else { continue }
                entries.append(Entry(provider: provider, window: window, at: at))
            }
        }
        entries.sort { $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at }
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.at) }
        return grouped.keys.sorted().map { Day(day: $0, entries: grouped[$0] ?? []) }
    }
}
