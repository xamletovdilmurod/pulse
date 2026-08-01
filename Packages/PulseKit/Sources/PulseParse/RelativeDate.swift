import Foundation

/// A date as a *human* expressed it, before it is resolved against a calendar.
///
/// Kept symbolic on purpose. "Yesterday" said at 00:30 on Tuesday and "yesterday" said at 23:30 on
/// Tuesday mean different calendar days, and the utterance may be parsed long after it was spoken (a
/// queued voice note, a retry after a crash). Resolving late — with an explicit `now` — keeps that
/// correct and keeps the parser itself a pure function, which is what makes it cheap to test.
///
/// The `Codable` representation is the exact wire format used in the training corpus and emitted by the
/// model, so these strings are a contract, not an implementation detail.
public enum RelativeDate: Hashable, Sendable {
    case today
    case yesterday
    case dayBeforeYesterday
    /// The most recent past occurrence of this weekday, not counting today.
    case lastWeekday(Weekday)
    /// This week's occurrence of the weekday — resolves to the nearest one, past or future.
    case thisWeekday(Weekday)
    case daysAgo(Int)
    /// A fully specified calendar date the user gave outright.
    case absolute(year: Int, month: Int, day: Int)

    public enum Weekday: Int, Hashable, Sendable, CaseIterable, Codable {
        case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

        /// `Calendar`'s 1-based weekday numbering starts on Sunday; ours starts on Monday, which is the
        /// convention in all three of our languages.
        var calendarWeekday: Int {
            self == .sunday ? 1 : rawValue + 1
        }

        var name: String {
            switch self {
            case .monday: "monday"
            case .tuesday: "tuesday"
            case .wednesday: "wednesday"
            case .thursday: "thursday"
            case .friday: "friday"
            case .saturday: "saturday"
            case .sunday: "sunday"
            }
        }

        static func named(_ name: String) -> Weekday? {
            allCases.first { $0.name == name.lowercased() }
        }
    }

    /// Resolve to a concrete day, anchored on `now`.
    ///
    /// Returns the start of the day in `calendar`'s time zone: a transaction belongs to a day, not to an
    /// instant, and anchoring to midnight keeps day-grouping stable no matter when it was entered.
    public func resolve(now: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let startOfToday = calendar.startOfDay(for: now)

        switch self {
        case .today:
            return startOfToday
        case .yesterday:
            return calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        case .dayBeforeYesterday:
            return calendar.date(byAdding: .day, value: -2, to: startOfToday) ?? startOfToday
        case .daysAgo(let count):
            return calendar.date(byAdding: .day, value: -abs(count), to: startOfToday) ?? startOfToday

        case .lastWeekday(let weekday):
            // Strictly in the past: "last Friday" said on a Friday means a week ago, not today.
            let offset = backwardOffset(to: weekday, from: startOfToday, calendar: calendar, allowToday: false)
            return calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday

        case .thisWeekday(let weekday):
            // Casual speech nearly always means the recent past — people log spending after the fact.
            let offset = backwardOffset(to: weekday, from: startOfToday, calendar: calendar, allowToday: true)
            return calendar.date(byAdding: .day, value: -offset, to: startOfToday) ?? startOfToday

        case .absolute(let year, let month, let day):
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components).map(calendar.startOfDay(for:)) ?? startOfToday
        }
    }

    /// How many days back from `date` the given weekday last occurred.
    private func backwardOffset(
        to weekday: Weekday,
        from date: Date,
        calendar: Calendar,
        allowToday: Bool
    ) -> Int {
        let current = calendar.component(.weekday, from: date)
        let target = weekday.calendarWeekday
        let raw = (current - target + 7) % 7
        if raw == 0 {
            return allowToday ? 0 : 7
        }
        return raw
    }
}

// MARK: - Wire format

extension RelativeDate: Codable {

    /// The exact strings used in the training corpus and emitted by the model.
    public var wireValue: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case .dayBeforeYesterday: "day_before_yesterday"
        case .lastWeekday(let day): "last_\(day.name)"
        case .thisWeekday(let day): "this_\(day.name)"
        case .daysAgo(let count): "\(count)_days_ago"
        case .absolute(let year, let month, let day):
            String(format: "%04d-%02d-%02d", year, month, day)
        }
    }

    /// Parse the wire format. Returns `nil` for anything unrecognised rather than guessing — a bad date
    /// silently landing on today is the kind of error a user never notices and never forgives.
    public init?(wireValue: String) {
        let value = wireValue.trimmingCharacters(in: .whitespaces).lowercased()

        switch value {
        case "today": self = .today; return
        case "yesterday": self = .yesterday; return
        case "day_before_yesterday": self = .dayBeforeYesterday; return
        default: break
        }

        if let name = value.dropPrefixIfPresent("last_"), let day = Weekday.named(name) {
            self = .lastWeekday(day)
            return
        }
        if let name = value.dropPrefixIfPresent("this_"), let day = Weekday.named(name) {
            self = .thisWeekday(day)
            return
        }
        if let count = value.dropSuffixIfPresent("_days_ago"), let days = Int(count), days >= 0 {
            self = .daysAgo(days)
            return
        }

        // ISO-style yyyy-MM-dd.
        let parts = value.split(separator: "-")
        if parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        {
            self = .absolute(year: year, month: month, day: day)
            return
        }

        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = RelativeDate(wireValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised relative date: \(raw)"
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: -

extension String {
    fileprivate func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    fileprivate func dropSuffixIfPresent(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}
