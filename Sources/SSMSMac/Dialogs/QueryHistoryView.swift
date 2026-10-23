import SwiftUI
import AppKit

/// The query history browser: every statement this app has run, searchable, with what
/// it returned and how long it took.
///
/// SSMS has no such window — it keeps nothing once a tab is closed. The point here is
/// the question that actually gets asked: "what was that query I ran this morning, and
/// did it work?"
struct QueryHistoryView: View {
    @EnvironmentObject var app: AppState

    @State private var searchText = ""
    @State private var outcome: HistoryOutcomeFilter = .all
    @State private var serverFilter: String?
    @State private var period: Period = .all
    @State private var selection: Set<UUID> = []
    @State private var confirmClear = false

    private enum Period: String, CaseIterable, Identifiable {
        case all, hour, today, week

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Any time"
            case .hour: return "Last hour"
            case .today: return "Last 24 hours"
            case .week: return "Last 7 days"
            }
        }

        var since: Date? {
            switch self {
            case .all: return nil
            case .hour: return Date().addingTimeInterval(-3600)
            case .today: return Date().addingTimeInterval(-86_400)
            case .week: return Date().addingTimeInterval(-604_800)
            }
        }
    }

    private var entries: [QueryHistoryEntry] {
        app.history.search(text: searchText, outcome: outcome,
                           server: serverFilter, since: period.since)
    }

    private var selected: QueryHistoryEntry? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return app.history.entries.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VSplitView {
                table.frame(minHeight: 220)
                detail.frame(minHeight: 140)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 560)
        .confirmationDialog("Delete the whole query history?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete \(app.history.entries.count) entries", role: .destructive) {
                app.history.clear()
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
            Text("Query History").font(.headline)

            Picker("", selection: $outcome) {
                ForEach(HistoryOutcomeFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Picker("", selection: $serverFilter) {
                Text("Every server").tag(String?.none)
                ForEach(app.history.servers, id: \.self) { server in
                    Text(server).tag(String?.some(server))
                }
            }
            .labelsHidden()
            .fixedSize()

            Spacer()
            TextField("Search statements, servers, databases", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(12)
    }

    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn("") { entry in
                Image(systemName: entry.cancelled == true
                      ? "minus.circle.fill"
                      : (entry.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .foregroundStyle(entry.cancelled == true ? Color.orange
                                     : (entry.succeeded ? Color.green : Color.red))
            }.width(24)

            TableColumn("Statement") { entry in
                Text(entry.preview)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
            }.width(min: 220, ideal: 420)

            TableColumn("Ran at") { entry in
                Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    .monospacedDigit()
            }.width(170)

            TableColumn("Duration") { entry in
                Text(entry.durationText).monospacedDigit()
            }.width(90)

            TableColumn("Outcome") { entry in
                Text(entry.outcomeText)
                    .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)
                    .lineLimit(1)
            }.width(min: 120, ideal: 180)

            TableColumn("Server") { entry in
                Text(entry.server).lineLimit(1)
            }.width(min: 100, ideal: 150)

            TableColumn("Database") { entry in
                Text(entry.database).lineLimit(1)
            }.width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Open in New Query Window") { openSelected(ids) }
            Button("Copy SQL") { copySQL(ids) }
            Divider()
            Button("Delete", role: .destructive) {
                app.history.remove(ids: ids)
                selection.subtract(ids)
            }
        } primaryAction: { ids in
            openSelected(ids)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selected {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                    Text("\(entry.server) · \(entry.database)")
                    Text(entry.durationText)
                    Text(entry.outcomeText)
                    if let batches = entry.batchCount, batches > 1 {
                        Text("\(batches) batches")
                    }
                    Spacer()
                    Button("Open") { openSelected([entry.id]) }
                    Button("Copy") { copySQL([entry.id]) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                ScrollView {
                    Text(entry.sql)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            ContentUnavailableView("Select a statement", systemImage: "clock",
                                   description: Text(app.history.entries.isEmpty
                                                     ? "Executed queries appear here."
                                                     : "Pick a row to read the whole statement."))
        }
    }

    private var footer: some View {
        HStack {
            Text("\(entries.count) of \(app.history.entries.count) statements")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Delete Selected") {
                app.history.remove(ids: selection)
                selection = []
            }
            .disabled(selection.isEmpty)
            Button("Clear All") { confirmClear = true }
                .disabled(app.history.entries.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    /// Opens on the server the statement was run against when it is still connected,
    /// so re-running it does not quietly hit a different instance.
    private func openSelected(_ ids: Set<UUID>) {
        for id in ids {
            guard let entry = app.history.entries.first(where: { $0.id == id }) else { continue }
            let server = app.servers.first {
                $0.displayName.caseInsensitiveCompare(entry.server) == .orderedSame
            }
            app.openScript(entry.sql, server: server, database: entry.database,
                           title: "History \(entry.startedAt.formatted(date: .omitted, time: .shortened))")
        }
    }

    private func copySQL(_ ids: Set<UUID>) {
        let text = app.history.entries
            .filter { ids.contains($0.id) }
            .map(\.sql)
            .joined(separator: "\nGO\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
