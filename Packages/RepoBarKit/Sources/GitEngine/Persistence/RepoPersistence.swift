import Foundation
import os

/// JSON persistence under `~/Library/Application Support/RepoBar/` (plan §5.8).
/// `repos.json` holds user intent; `state.json` is a volatile cache and can be deleted safely.
public actor RepoPersistence {
    public let directory: URL
    private let logger = Logger(subsystem: "com.aliyar.RepoBar", category: "persistence")

    struct RecordsFile: Codable {
        var schemaVersion = 1
        var repos: [RepoRecord]
    }

    struct StatesFile: Codable {
        var schemaVersion = 1
        var states: [String: RepoState]
    }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RepoBar", isDirectory: true)
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    public var recordsURL: URL { directory.appendingPathComponent("repos.json") }
    public var statesURL: URL { directory.appendingPathComponent("state.json") }

    public func loadRecords() -> [RepoRecord] {
        load(RecordsFile.self, from: recordsURL)?.repos ?? []
    }

    public func loadStates() -> [RepoID: RepoState] {
        let raw = load(StatesFile.self, from: statesURL)?.states ?? [:]
        var result: [RepoID: RepoState] = [:]
        for (key, value) in raw {
            if let id = UUID(uuidString: key) { result[id] = value }
        }
        return result
    }

    public func saveRecords(_ records: [RepoRecord]) throws {
        try save(RecordsFile(repos: records), to: recordsURL)
    }

    public func saveStates(_ states: [RepoID: RepoState]) throws {
        var raw: [String: RepoState] = [:]
        for (id, state) in states { raw[id.uuidString] = state }
        // Not pretty-printed: this one is written on every check and read by nobody, while
        // repos.json stays readable because people do open and edit it.
        try save(StatesFile(states: raw), to: statesURL, pretty: false)
    }

    // MARK: - Private

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            // Keep the broken file for inspection and start fresh.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let corrupt = url.appendingPathExtension("corrupt-\(stamp)")
            try? FileManager.default.moveItem(at: url, to: corrupt)
            logger.error("could not decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public); moved aside")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try (pretty ? Self.encoder : Self.compactEncoder).encode(value)
        try data.write(to: url, options: [.atomic])
    }

    nonisolated(unsafe) private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Same dates, no indentation — for the file that is rewritten on every check.
    private static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = fractionalFormatter.date(from: text) ?? plainFormatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date: \(text)"))
        }
        return decoder
    }()
}
