import AppKit
import OSLog
import GitEngine

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDependencies.bootstrap()
        AppDependencies.shared.notifications.configure()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppDependencies.shared.statusItem.install()
        guard !ProcessInfo.processInfo.isRunningTests else { return }
        AppDependencies.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        let engine = AppDependencies.shared.engine
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.flush()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }
}
