import SwiftUI

/// "just now", "2 min. ago", "yesterday" — refreshes every 30 s.
struct RelativeTimeText: View {
    let date: Date
    var prefix: String = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(prefix + Self.string(for: date, now: context.date))
        }
    }

    nonisolated static func string(for date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 45 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
