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

    var preview: String {
        let collapsed = sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
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

    func search(_ text: String) -> [QueryHistoryEntry] {
        guard !text.isEmpty else { return entries }
        return entries.filter { $0.sql.localizedCaseInsensitiveContains(text) }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
