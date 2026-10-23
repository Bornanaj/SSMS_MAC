import Foundation

struct QueryHistoryEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var sql: String
    var server: String
    var database: String
    var startedAt: Date
    var elapsed: TimeInterval
    var rowsReturned: Int
    var succeeded: Bool
    var errorText: String?
    /// Added after the first release, so every field below decodes as absent from an
    /// older history.json rather than throwing the whole file away.
    var rowsAffected: Int64?
    var cancelled: Bool?
    var batchCount: Int?
    /// The window the statement ran in, so history can be grouped by tab.
    var tabTitle: String?

    var durationText: String {
        if elapsed >= 1 { return String(format: "%.3f s", elapsed) }
        return String(format: "%.0f ms", elapsed * 1000)
    }

    /// "12 rows", "3 rows affected" or the error, whichever describes the run.
    var outcomeText: String {
        if cancelled == true { return "Cancelled" }
        if !succeeded { return errorText ?? "Failed" }
        if rowsReturned > 0 { return "\(rowsReturned) row\(rowsReturned == 1 ? "" : "s")" }
        if let affected = rowsAffected, affected > 0 {
            return "\(affected) row\(affected == 1 ? "" : "s") affected"
        }
        return "OK"
    }

    var preview: String {
        let collapsed = sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}

enum HistoryOutcomeFilter: String, CaseIterable, Identifiable {
    case all, succeeded, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .succeeded: return "Succeeded"
        case .failed: return "Failed"
        }
    }
}

/// Keeps the last N executed statements so the user can find that query they ran
/// twenty minutes ago. Persisted next to the connection list.
@MainActor
final class QueryHistoryStore: ObservableObject {
    @Published private(set) var entries: [QueryHistoryEntry] = []
    var limit = 500

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSMS for Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([QueryHistoryEntry].self, from: data)) ?? []
        }
    }

    func record(_ entry: QueryHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    /// The history browser's filter, in one place so the list and the counts agree.
    /// `text` matches the statement, the server and the database, so "ShopDemo" or the
    /// name of a server finds everything run against it.
    func search(text: String = "",
                outcome: HistoryOutcomeFilter = .all,
                server: String? = nil,
                since: Date? = nil) -> [QueryHistoryEntry] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            if let since, entry.startedAt < since { return false }
            if let server, !server.isEmpty,
               entry.server.caseInsensitiveCompare(server) != .orderedSame { return false }
            switch outcome {
            case .all: break
            case .succeeded: if !entry.succeeded { return false }
            case .failed: if entry.succeeded { return false }
            }
            guard !needle.isEmpty else { return true }
            return entry.sql.localizedCaseInsensitiveContains(needle)
                || entry.server.localizedCaseInsensitiveContains(needle)
                || entry.database.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Distinct servers seen in the history, for the filter menu.
    var servers: [String] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let key = entry.server.lowercased()
            guard !entry.server.isEmpty, seen.insert(key).inserted else { return nil }
            return entry.server
        }.sorted()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
