import SwiftUI
import AppKit
import SQLServerKit

/// The SQL Server Logs viewer from SSMS's Management folder.
struct ErrorLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var kind: ServerLogKind = .sqlServer
    @State private var archives: [ServerLogArchive] = []
    @State private var archive = 0
    @State private var searchDraft = ""
    @State private var search = ""
    @State private var entries: [ServerLogEntry] = []
    @State private var selection: Int?
    @State private var severityFilter = "all"
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false

    private var visible: [ServerLogEntry] {
        switch severityFilter {
        case "errors": return entries.filter { $0.severity == .error }
        case "warnings": return entries.filter { $0.severity != .information }
        default: return entries
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "doc.plaintext", title: "SQL Server Logs",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 1040, height: 680)
        .task {
            await loadArchives()
            await load()
        }
        .task(id: kind) { await loadArchives(); await load() }
        .task(id: archive) { await load() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Log", selection: $kind) {
                ForEach(ServerLogKind.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 210)

            Picker("File", selection: $archive) {
                ForEach(archives) { Text($0.title).tag($0.number) }
            }
            .frame(width: 160)

            Picker("Show", selection: $severityFilter) {
                Text("Everything").tag("all")
                Text("Warnings and errors").tag("warnings")
                Text("Errors only").tag("errors")
            }
            .frame(width: 190)

            TextField("Filter text (applied by the server)", text: $searchDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    search = searchDraft
                    Task { await load() }
                }

            Button {
                search = searchDraft
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isBusy)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if isError {
            ContentUnavailableView("Could not read the log",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(status ?? ""))
        } else if isBusy && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView("Nothing to show", systemImage: "doc.plaintext",
                                   description: Text(entries.isEmpty
                                       ? "This log file is empty, or the filter matched nothing."
                                       : "No line matches the severity filter."))
        } else {
            VSplitView {
                Table(visible, selection: Binding(
                    get: { selection.map { Set([$0]) } ?? [] },
                    set: { selection = $0.first }
                )) {
                    TableColumn("") { entry in
                        Image(systemName: entry.severity.symbol)
                            .foregroundStyle(tint(entry.severity))
                    }.width(22)
                    TableColumn("Date", value: \.loggedAt).width(155)
                    TableColumn("Source", value: \.source).width(100)
                    TableColumn("Message") { Text($0.message).lineLimit(1) }
                        .width(min: 260, ideal: 560)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Message").font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Line") { copySelected() }
                            .font(.caption)
                            .disabled(selection == nil)
                    }
                    ScrollView {
                        Text(selected?.message ?? "Select a line to read it in full.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(minHeight: 80, idealHeight: 130)
            }
        }
    }

    private var selected: ServerLogEntry? {
        entries.first { $0.id == selection }
    }

    private var footer: some View {
        HStack {
            Text(summary)
                .font(.caption)
                .foregroundStyle(isError ? Color.red : Color.secondary)
                .lineLimit(2)
            Spacer()
            Button("Copy All") { copyAll() }
                .disabled(visible.isEmpty)
            Button("Recycle Log") { Task { await recycle() } }
                .help("Rolls the log over without restarting the instance")
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var summary: String {
        if let status, isError { return status }
        let errors = entries.filter { $0.severity == .error }.count
        var text = "\(visible.count) of \(entries.count) line\(entries.count == 1 ? "" : "s")"
        if errors > 0 { text += " · \(errors) flagged as errors" }
        return text
    }

    private func tint(_ severity: ServerLogEntry.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .information: return .secondary
        }
    }

    private func copySelected() {
        guard let entry = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "\(entry.loggedAt)\t\(entry.source)\t\(entry.message)", forType: .string)
    }

    private func copyAll() {
        let text = visible
            .map { "\($0.loggedAt)\t\($0.source)\t\($0.message)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadArchives() async {
        let service = ErrorLogService(session: server.session)
        archives = (try? await service.archives(kind: kind)) ?? [ServerLogArchive(number: 0)]
        if !archives.contains(where: { $0.number == archive }) {
            archive = archives.first?.number ?? 0
        }
    }

    private func recycle() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await ErrorLogService(session: server.session).recycle(kind: kind)
            isError = false
            status = "The log was recycled."
            await loadArchives()
            await load()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            entries = try await ErrorLogService(session: server.session)
                .entries(kind: kind, archive: archive, search: search)
            selection = entries.first?.id
            isError = false
            status = nil
        } catch {
            entries = []
            isError = true
            // sp_readerrorlog needs securityadmin, which plenty of working logins lack.
            status = String(describing: error)
        }
    }
}
