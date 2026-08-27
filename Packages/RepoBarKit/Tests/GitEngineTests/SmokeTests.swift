import Foundation
import Testing
@testable import GitEngine

/// Replaces a test that only asserted a hard-coded version string was non-empty. The pure
/// decisions the app leans on must hold before any repository or git binary is involved.
@Test func theEnginesPureDecisionsWorkOutOfTheBox() throws {
    let settings = EngineSettings()
    #expect(settings.checkInterval > .zero)
    #expect(settings.maxConcurrentChecks >= 1)

    #expect(throws: PullRefusal.noSnapshot) { try PullService.preflight(snapshot: nil) }
    #expect(SchedulePlanner().isDue(state: nil, now: Date(), interval: .seconds(300), lowPower: false, reason: .launch),
            "a repository that has never been checked is due")
    #expect(GitErrorClassifier.classify(stderr: "fatal: Authentication failed for 'https://x/'") == .authFailed(.https))
}
