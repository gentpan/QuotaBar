import Foundation

// MARK: - Spend budgets

/// A spending limit per day and per calendar month, in the currency it was
/// set in. Nil means no budget for that period.
public struct SpendBudget: Codable, Equatable, Sendable {
    public var daily: Double?
    public var monthly: Double?
    public var currency: String

    public init(daily: Double? = nil, monthly: Double? = nil, currency: String = "USD") {
        self.daily = daily
        self.monthly = monthly
        self.currency = currency
    }

    public var isSet: Bool { (daily ?? 0) > 0 || (monthly ?? 0) > 0 }
}

public enum BudgetPeriod: String, Sendable {
    case day, month
}

/// One budget crossing worth a notification.
public struct BudgetAlert: Equatable, Sendable {
    public var period: BudgetPeriod
    /// 80 on the way, 100 once over.
    public var level: Int
    /// In the budget's currency.
    public var spent: Double
    public var limit: Double
    /// Identifies this crossing: the period, which day or month, the level.
    public var key: String
}

public enum BudgetCheck {
    public static let warningShare = 0.8

    /// The crossings not yet notified. Each day's and each month's budget
    /// speaks at most twice: at 80%, and once over. Straight past both at
    /// once, only "over" is said.
    ///
    /// `rate` turns dollars into the budget's currency; without one (rates
    /// not fetched yet) a non-dollar budget waits rather than guessing.
    public static func alerts(
        budget: SpendBudget,
        daily: [DailyCost],
        rate: Double?,
        notified: [String],
        now: Date = Date(),
        calendar: Calendar = .current) -> [BudgetAlert]
    {
        guard budget.isSet, let rate = budget.currency == "USD" ? 1 : rate else { return [] }
        let today = calendar.startOfDay(for: now)
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let daySpent = daily.filter { calendar.isDate($0.day, inSameDayAs: today) }.reduce(0) { $0 + $1.usd } * rate
        let monthSpent = daily.filter { $0.day >= monthStart && $0.day <= now }.reduce(0) { $0 + $1.usd } * rate

        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        let monthFormat = DateFormatter()
        monthFormat.calendar = calendar
        monthFormat.locale = Locale(identifier: "en_US_POSIX")
        monthFormat.dateFormat = "yyyy-MM"

        var out: [BudgetAlert] = []
        for (period, limit, spent, stamp) in [
            (BudgetPeriod.day, budget.daily, daySpent, dayFormat.string(from: now)),
            (BudgetPeriod.month, budget.monthly, monthSpent, monthFormat.string(from: now)),
        ] {
            guard let limit, limit > 0 else { continue }
            let level = spent >= limit ? 100 : spent >= limit * warningShare ? 80 : 0
            guard level > 0 else { continue }
            let prefix = "\(period.rawValue)|\(stamp)|"
            let said = notified.filter { $0.hasPrefix(prefix) }.compactMap { Int($0.dropFirst(prefix.count)) }.max() ?? 0
            guard level > said else { continue }
            out.append(BudgetAlert(period: period, level: level, spent: spent, limit: limit, key: prefix + String(level)))
        }
        return out
    }
}

// MARK: - The weekly digest

public enum WeeklyDigest {
    /// Local time on Monday after which last week's digest is due.
    public static let hour = 9

    /// Last week — Monday to Sunday — once it is past Monday 09:00, unless its
    /// digest was already sent (`lastSent` is its key).
    public static func dueWeek(now: Date = Date(), lastSent: String, calendar base: Calendar = .current) -> (key: String, start: Date, end: Date)? {
        var calendar = base
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
              let due = calendar.date(byAdding: .hour, value: hour, to: thisWeek.start),
              now >= due,
              let start = calendar.date(byAdding: .day, value: -7, to: thisWeek.start),
              let end = calendar.date(byAdding: .day, value: -1, to: thisWeek.start)
        else { return nil }
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: start)
        let key = String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
        return key == lastSent ? nil : (key, start, end)
    }
}
