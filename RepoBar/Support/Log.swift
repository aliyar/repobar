import OSLog

nonisolated enum Log {
    static let subsystem = "com.aliyar.RepoBar"
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let statusItem = Logger(subsystem: subsystem, category: "statusItem")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}
