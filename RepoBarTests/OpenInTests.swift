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
