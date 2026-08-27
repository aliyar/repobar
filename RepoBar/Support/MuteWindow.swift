import Foundation

/// The choices offered wherever notifications can be silenced for a while — the
/// footer's global menu and a repository's own Notifications menu.
nonisolated enum MuteWindow: String, CaseIterable, Sendable {
    case hour, fourHours, tomorrowMorning

    var title: String {
        switch self {
        case .hour: "for 1 hour"
        case .fourHours: "for 4 hours"
        case .tomorrowMorning: "until tomorrow"
        }
    }

    /// How long the silence lasts, counted from `now`.
    func duration(from now: Date = Date(), calendar: Calendar = .current) -> Duration {
        switch self {
        case .hour: .seconds(3600)
        case .fourHours: .seconds(4 * 3600)
        case .tomorrowMorning: .seconds(Int(Self.secondsUntilTomorrowMorning(from: now, calendar: calendar)))
        }
    }

    /// Until 9am tomorrow, so an evening silence covers the night rather than expiring in it.
    static func secondsUntilTomorrowMorning(from now: Date = Date(), calendar: Calendar = .current) -> Double {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return max(3600, morning.timeIntervalSince(now))
    }
}
