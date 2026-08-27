import Foundation
import Testing
@testable import RepoBar

@MainActor
@Suite("Open in")
struct OpenInTests {
    /// Installed on every Mac, so it stands in for an app the built-in catalog does not list.
    let textEdit = "com.apple.TextEdit"

    func makeModel() -> AppModel {
        let model = AppModel.preview(sample: false)
        model.settings.customOpenAppBundleIDs = []
        model.settings.defaultOpenAppBundleID = ExternalApp.finder.id
        model.refreshOpenApps()
        return model
    }

    @Test func addedApplicationJoinsTheListAndRemoveTakesItOut() {
        let model = makeModel()
        #expect(!model.openApps.contains { $0.kind == .custom })

        model.settings.customOpenAppBundleIDs = [textEdit]
        model.refreshOpenApps()
        #expect(model.openApps.contains { $0.id == textEdit && $0.kind == .custom })

        model.removeCustomOpenApp(textEdit)
        #expect(!model.openApps.contains { $0.id == textEdit }, "removing must drop it from the offered apps")
        #expect(model.settings.customOpenAppBundleIDs.isEmpty)
    }

    @Test func removingTheDefaultApplicationFallsBackToFinder() {
        let model = makeModel()
        model.settings.customOpenAppBundleIDs = [textEdit]
        model.refreshOpenApps()
        model.settings.defaultOpenAppBundleID = textEdit
        #expect(model.defaultOpenApp().id == textEdit)

        model.removeCustomOpenApp(textEdit)
        #expect(model.defaultOpenApp().id == ExternalApp.finder.id)
    }

    @Test func customApplicationsAreOfferedRightAfterFinder() {
        let model = makeModel()
        model.settings.customOpenAppBundleIDs = [textEdit]
        model.refreshOpenApps()
        let kinds = model.openApps.map(\.kind)
        #expect(kinds.first == .finder)
        #expect(kinds.firstIndex(of: .custom) == 1, "hand-picked apps must not sit below every editor")
    }

    @Test func unknownBundleIDsAreDropped() {
        let model = makeModel()
        model.settings.customOpenAppBundleIDs = ["com.example.not.installed"]
        model.refreshOpenApps()
        #expect(!model.openApps.contains { $0.id == "com.example.not.installed" })
    }
}

@MainActor
@Suite("Panel keyboard")
struct PanelKeyboardTests {
    let ids = [UUID(), UUID(), UUID()]

    @Test func arrowsWalkTheListAndStopAtTheEnds() {
        let ui = PanelUIState()
        #expect(ui.moveSelection(1, in: ids) == ids[0], "first press selects the top row")
        #expect(ui.moveSelection(1, in: ids) == ids[1])
        #expect(ui.moveSelection(1, in: ids) == ids[2])
        #expect(ui.moveSelection(1, in: ids) == ids[2], "does not wrap past the end")
        #expect(ui.moveSelection(-1, in: ids) == ids[1])
    }

    @Test func upFromNothingSelectsTheLastRow() {
        let ui = PanelUIState()
        #expect(ui.moveSelection(-1, in: ids) == ids[2])
    }

    @Test func emptyListLeavesTheSelectionAlone() {
        let ui = PanelUIState()
        #expect(ui.moveSelection(1, in: []) == nil)
        #expect(ui.selected == nil)
    }

    @Test func filteringDropsASelectionThatIsNoLongerShown() {
        let ui = PanelUIState()
        ui.selected = ids[2]
        ui.pruneSelection(to: [ids[0], ids[1]])
        #expect(ui.selected == nil)

        ui.selected = ids[0]
        ui.pruneSelection(to: [ids[0], ids[1]])
        #expect(ui.selected == ids[0], "a visible selection survives")
    }
}

@Suite("Mute timing")
struct MuteTimingTests {
    @Test func eveningMuteRunsPastMidnightToTheMorning() {
        var components = DateComponents(year: 2026, month: 8, day: 27, hour: 22, minute: 0)
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: components)!

        let seconds = MuteWindow.secondsUntilTomorrowMorning(from: now, calendar: calendar)
        let until = now.addingTimeInterval(seconds)
        let hour = calendar.component(.hour, from: until)
        #expect(hour == 9)
        #expect(calendar.component(.day, from: until) == 28, "lands on the next morning, not this one")
    }

    @Test func morningMuteStillLastsAtLeastAnHour() {
        var components = DateComponents(year: 2026, month: 8, day: 27, hour: 8, minute: 59)
        components.timeZone = TimeZone(identifier: "UTC")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: components)!
        #expect(MuteWindow.secondsUntilTomorrowMorning(from: now, calendar: calendar) >= 3600)
    }
}

@MainActor
@Suite("Silence labels")
struct SilenceLabelTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func date(day: Int, hour: Int) -> Date {
        var components = DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: 30)
        components.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: components)!
    }

    @Test func todayShowsOnlyTheTime() {
        let now = Date()
        let later = now.addingTimeInterval(1800)
        let label = AppModel.untilLabel(later, calendar: .current)
        #expect(!label.contains("tomorrow"))
        #expect(label == later.formatted(date: .omitted, time: .shortened))
    }

    @Test func tomorrowSaysSo() {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        #expect(AppModel.untilLabel(tomorrow, calendar: .current).hasPrefix("tomorrow "),
                "a bare time would be ambiguous for an overnight silence")
    }

    @Test func furtherOutCarriesTheDate() {
        let later = Calendar.current.date(byAdding: .day, value: 5, to: Date())!
        let label = AppModel.untilLabel(later, calendar: .current)
        #expect(!label.hasPrefix("tomorrow"))
        #expect(label.count > 8, "includes a date, not just a time")
    }
}
