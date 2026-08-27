import Foundation

/// Pure rules for "seen" bookkeeping. See plan §5.2.
public enum AcknowledgementRules {
    public struct Outcome: Sendable, Hashable {
        public var lastSeen: String
        public var unseen: Int
        public var historyRewritten: Bool
    }

    /// - Parameters:
    ///   - lastSeen: previously acknowledged tip for this watched ref.
    ///   - tip: current tip SHA of the watched ref.
    ///   - leftRight: `rev-list --left-right --count lastSeen...tip`, nil when git could not compute it
    ///     (object gone, i.e. history was rewritten).
    ///   - upstreamMode: watching HEAD's upstream (as opposed to an override branch).
    ///   - behind: HEAD-vs-tip behind count in upstream mode.
    public static func apply(lastSeen: String, tip: String, leftRight: (left: Int, right: Int)?, upstreamMode: Bool, behind: Int?) -> Outcome {
        guard let leftRight else {
            return Outcome(lastSeen: tip, unseen: 0, historyRewritten: true)
        }
        if leftRight.left > 0 {
            return Outcome(lastSeen: tip, unseen: 0, historyRewritten: true)
        }
        if upstreamMode, let behind, behind == 0 {
            // Everything on the watched ref is already in HEAD: the user pulled/merged → auto-acknowledge.
            return Outcome(lastSeen: tip, unseen: 0, historyRewritten: false)
        }
        return Outcome(lastSeen: lastSeen, unseen: leftRight.right, historyRewritten: false)
    }

    /// First time a ref is seen: in upstream mode start from the merge base so a repo that is
    /// already behind lights up immediately; an override branch starts clean.
    public static func initialLastSeen(upstreamMode: Bool, mergeBase: String?, tip: String) -> String {
        if upstreamMode, let mergeBase { return mergeBase }
        return tip
    }

    /// Whether a notification should be posted for this check.
    public static func shouldNotify(unseen: Int, tip: String, lastNotified: String?, muted: Bool, hadSuccessfulCheckBefore: Bool) -> Bool {
        unseen > 0 && tip != lastNotified && !muted && hadSuccessfulCheckBefore
    }

    /// Whether to remind about commits that have been sitting unpushed. `after` is how
    /// long a branch may stay ahead before the first reminder; the reminder then repeats
    /// at most once a day so a long-lived branch does not nag.
    /// `trackingUpstream` must be true: `ahead` counts HEAD against the *watched* ref, which is
    /// only the branch's own upstream in upstream mode. Watching a different branch — or having
    /// no upstream at all — makes every commit on HEAD look unpushed when it is not.
    public static func shouldRemindAboutUnpushed(
        ahead: Int,
        aheadSince: Date?,
        lastReminded: Date?,
        after: Duration?,
        muted: Bool,
        trackingUpstream: Bool,
        now: Date
    ) -> Bool {
        guard trackingUpstream, let after, ahead > 0, !muted, let aheadSince else { return false }
        let seconds = Double(after.components.seconds)
        guard now.timeIntervalSince(aheadSince) >= seconds else { return false }
        guard let lastReminded else { return true }
        return now.timeIntervalSince(lastReminded) >= 86_400
    }
}
