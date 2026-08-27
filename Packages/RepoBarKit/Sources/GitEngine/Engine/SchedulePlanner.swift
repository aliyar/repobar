import Foundation

public enum CheckReason: String, Sendable, Hashable {
    case launch, interval, manualAll, manual, wake, networkUp, volumeMounted, settingsChanged, panelOpened, afterPull

    /// Manual reasons bypass backoff and due-time.
    public var isManual: Bool { self == .manual || self == .manualAll || self == .afterPull }

    /// Reasons that ignore backoff. A fatal failure parks `backoffUntil` at `.distantFuture`,
    /// and these are exactly the events that undo such a failure: the drive came back, the
    /// user pointed us at a git binary, the app relaunched, the network returned. Without
    /// this the hint "RepoBar will retry automatically" is never honoured.
    public var bypassesBackoff: Bool {
        isManual || self == .volumeMounted || self == .settingsChanged || self == .launch || self == .networkUp
    }
}

/// Decides which repositories are due for a check. Pure and deterministic (jitter derives from the id).
public struct SchedulePlanner: Sendable {
    /// Minimum spacing for opportunistic triggers (wake, network up, …) so they don't stack.
    public var opportunisticSpacing: Duration = .seconds(30)
    public var panelOpenStaleness: Duration = .seconds(60)
    public var lowPowerMultiplier: Double = 3

    public init() {}

    public func isDue(state: RepoState?, now: Date, interval: Duration, lowPower: Bool, reason: CheckReason) -> Bool {
        if reason.isManual { return true }
        if !reason.bypassesBackoff, let until = state?.backoffUntil, until > now { return false }
        guard let lastAttempt = state?.lastAttemptAt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        switch reason {
        case .interval, .launch:
            var seconds = interval.seconds * (lowPower ? lowPowerMultiplier : 1)
            seconds *= 1 + Self.jitter(for: state)
            return elapsed >= seconds
        case .panelOpened:
            return elapsed >= panelOpenStaleness.seconds
        case .wake, .networkUp, .volumeMounted, .settingsChanged:
            return elapsed >= opportunisticSpacing.seconds
        case .manual, .manualAll, .afterPull:
            return true
        }
    }

    /// Due repositories, stalest first.
    public func due(now: Date, records: [RepoRecord], states: [RepoID: RepoState], interval: Duration, lowPower: Bool, reason: CheckReason) -> [RepoRecord] {
        records
            .filter { isDue(state: states[$0.id], now: now, interval: interval, lowPower: lowPower, reason: reason) }
            .sorted { (states[$0.id]?.lastSuccessAt ?? .distantPast) < (states[$1.id]?.lastSuccessAt ?? .distantPast) }
    }

    /// ±10 % deterministic jitter keyed on the repository's last attempt bucket-free hash.
    static func jitter(for state: RepoState?) -> Double {
        guard let attempt = state?.lastAttemptAt else { return 0 }
        let bucket = Int(attempt.timeIntervalSinceReferenceDate) % 21 // 0…20
        return Double(bucket - 10) / 100
    }
}

/// Backoff after failures (plan §5.6).
public struct BackoffPolicy: Sendable {
    public var maxAuthBackoff: Duration = .seconds(6 * 3600)

    public init() {}

    /// Returns how long to wait before the next automatic attempt, `nil` when automatic retries
    /// should stop until the user intervenes, or `.zero` when no backoff applies.
    public func delay(afterFailures failures: Int, kind: FailureKind, interval: Duration) -> Duration? {
        let n = max(0, failures - 1)
        switch kind {
        case .auth:
            let factor = pow(2, Double(min(n, 12)))
            return min(.seconds(interval.seconds * factor), maxAuthBackoff)
        case .network:
            let factor = min(pow(2, Double(n)), 4)
            return .seconds(interval.seconds * factor)
        case .lock, .user:
            return .zero
        case .fatal:
            return nil
        }
    }
}

extension Duration {
    /// Total seconds as a Double.
    public var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
