import AppKit
import Network
import OSLog
import GitEngine

/// Forwards system events (network, sleep/wake, power, volumes) to the engine via `AppModel`.
final class SystemTriggers {
    private let model: AppModel
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var wakeTask: Task<Void, Never>?
    private var networkTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.aliyar.RepoBar.network"))

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.trigger(.volumeMounted) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.powerStateChanged() }
        })
        powerStateChanged()
    }

    private func networkChanged(online: Bool) {
        networkTask?.cancel()
        if online {
            // Let DNS/VPN settle before the first fetch.
            networkTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.model.setOnline(true)
            }
        } else {
            model.setOnline(false)
        }
        Log.ui.notice("network \(online ? "reachable" : "unreachable", privacy: .public)")
    }

    private func didWake() {
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.model.trigger(.wake)
        }
    }

    private func powerStateChanged() {
        model.setLowPower(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
