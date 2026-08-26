import SwiftUI
import SQLServerKit
import TDSKit

/// Registered Servers: saved connections organised into groups, and the multi-server
/// query that makes the grouping worth having.
struct RegisteredServersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState

    @State private var selectedGroup: String?
    @State private var selectedProfile: UUID?
    @State private var newGroupName = ""
    @State private var showNewGroup = false
    @State private var showMultiServer = false
    @State private var status: String?

    private var groups: [String] {
        let named = app.connections.profiles.compactMap { $0.group }
            .filter { !$0.isEmpty }
        return Array(Set(named)).sorted()
    }

    private var ungrouped: [ConnectionProfile] {
        app.connections.profiles.filter { ($0.group ?? "").isEmpty }
    }

    private func profiles(in group: String) -> [ConnectionProfile] {
        app.connections.profiles.filter { $0.group == group }
    }

    private var visibleProfiles: [ConnectionProfile] {
        guard let selectedGroup else { return app.connections.profiles }
        return selectedGroup == "__ungrouped__" ? ungrouped : profiles(in: selectedGroup)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "rectangle.stack", title: "Registered Servers",
                           subtitle: "\(app.connections.profiles.count) saved connections",
                           isBusy: false)
            Divider()
            HSplitView {
                groupList.frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
                serverList.frame(minWidth: 420)
            }
            Divider()
            footer
        }
        .frame(width: 860, height: 560)
        .alert("New group", isPresented: $showNewGroup) {
            TextField("Group name", text: $newGroupName)
            Button("Cancel", role: .cancel) { newGroupName = "" }
            Button("Create") {
                // A group exists once a server is filed under it, so creating one just
                // selects the name and waits for a server to be assigned.
                selectedGroup = newGroupName
                status = "Assign a server to \"\(newGroupName)\" to keep the group."
                newGroupName = ""
            }
        }
        .sheet(isPresented: $showMultiServer) {
            MultiServerQuerySheet(profiles: visibleProfiles,
                                  groupName: selectedGroup == "__ungrouped__"
                                      ? "Ungrouped" : (selectedGroup ?? "All servers"))
                .environmentObject(app)
        }
    }

    private var groupList: some View {
        VStack(spacing: 0) {
            List(selection: $selectedGroup) {
                Section("Groups") {
                    Text("All servers").tag(String?.none)
                    ForEach(groups, id: \.self) { group in
                        Label(group, systemImage: "folder")
                            .tag(String?.some(group))
                    }
                    if !ungrouped.isEmpty {
                        Label("Ungrouped", systemImage: "tray")
                            .tag(String?.some("__ungrouped__"))
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { showNewGroup = true } label: { Image(systemName: "plus") }
                    .help("New group")
                Spacer()
            }
            .padding(6)
        }
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            Table(visibleProfiles, selection: $selectedProfile) {
                TableColumn("Name") { profile in
                    HStack(spacing: 6) {
                        if let color = Theme.color(hex: profile.colorHex) {
                            Circle().fill(color).frame(width: 7, height: 7)
                        } else {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                        }
                        Text(profile.displayName).lineLimit(1)
                    }
                }.width(min: 140, ideal: 190)
                TableColumn("Server") { Text($0.server) }.width(150)
                TableColumn("Authentication") { Text($0.authentication.displayName) }.width(160)
                TableColumn("Group") { profile in
                    Text(profile.group ?? "").foregroundStyle(.secondary)
                }.width(120)
            }

            Divider()
            HStack(spacing: 8) {
                Button {
                    guard let id = selectedProfile,
                          let profile = app.connections.profiles.first(where: { $0.id == id })
                    else { return }
                    Task {
                        let password = await app.connections.password(for: profile)
                        await app.connect(profile: profile, password: password)
                        dismiss()
                    }
                } label: { Label("Connect", systemImage: "bolt") }
                    .disabled(selectedProfile == nil)

                Menu {
                    Button("Ungrouped") { assign(group: "") }
                    ForEach(groups, id: \.self) { group in
                        Button(group) { assign(group: group) }
                    }
                    if let selectedGroup, selectedGroup != "__ungrouped__",
                       !groups.contains(selectedGroup) {
                        Button(selectedGroup) { assign(group: selectedGroup) }
                    }
                } label: {
                    Label("Move to group", systemImage: "folder")
                }
                .disabled(selectedProfile == nil)

                Button(role: .destructive) {
                    guard let id = selectedProfile,
                          let profile = app.connections.profiles.first(where: { $0.id == id })
                    else { return }
                    app.connections.remove(profile)
                    selectedProfile = nil
                    status = "Removed \(profile.displayName)."
                } label: { Label("Remove", systemImage: "trash") }
                    .disabled(selectedProfile == nil)

                Spacer()

                Button {
                    showMultiServer = true
                } label: { Label("New Multi-Server Query", systemImage: "square.stack.3d.up") }
                    .disabled(visibleProfiles.count < 2)
                    .help("Run one script against every server in this group")
            }
            .padding(8)
        }
    }

    private func assign(group: String) {
        guard let id = selectedProfile,
              var profile = app.connections.profiles.first(where: { $0.id == id }) else { return }
        profile.group = group.isEmpty ? nil : group
        app.connections.save(profile, password: nil)
        status = group.isEmpty
            ? "\(profile.displayName) is now ungrouped."
            : "\(profile.displayName) moved to \(group)."
    }

    private var footer: some View {
        HStack {
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

// MARK: - Multi-server query

/// Runs one script against several servers and stacks the results, with a Server Name
/// column so the rows can be told apart — the same shape SSMS produces.
struct MultiServerQuerySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var app: AppState

    let profiles: [ConnectionProfile]
    let groupName: String

    struct ServerOutcome: Identifiable {
        var id: UUID
        var serverName: String
        var succeeded: Bool
        var message: String
        var elapsed: TimeInterval
        var columns: [String]
        var rows: [[String]]
    }

    @State private var script = "SELECT @@SERVERNAME AS server_name,\n"
        + "       SERVERPROPERTY('ProductVersion') AS version,\n"
        + "       SERVERPROPERTY('Edition') AS edition;"
    @State private var outcomes: [ServerOutcome] = []
    @State private var isRunning = false
    @State private var progress = 0.0
    @State private var status: String?

    private var combined: ReportResult? {
        let successful = outcomes.filter { $0.succeeded && !$0.rows.isEmpty }
        guard let template = successful.first else { return nil }
        var rows: [[String]] = []
        for outcome in successful {
            // Only stack servers whose shape matches the first one; a different result
            // shape would silently misalign the columns.
            guard outcome.columns == template.columns else { continue }
            rows.append(contentsOf: outcome.rows.map { [outcome.serverName] + $0 })
        }
        return ReportResult(columns: ["Server Name"] + template.columns, rows: rows)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "square.stack.3d.up", title: "Multi-Server Query",
                           subtitle: "\(groupName) · \(profiles.count) servers",
                           isBusy: isRunning)
            Divider()
            VSplitView {
                editor.frame(minHeight: 140)
                results.frame(minHeight: 220)
            }
            Divider()
            footer
        }
        .frame(width: 1000, height: 680)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Script").font(.caption.weight(.medium))
                Spacer()
                Button {
                    Task { await run() }
                } label: { Label("Execute", systemImage: "play.fill") }
                    .disabled(isRunning || script.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    isRunning = false
                } label: { Label("Stop", systemImage: "stop.fill") }
                    .disabled(!isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TextEditor(text: $script)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private var results: some View {
        VStack(spacing: 0) {
            if isRunning {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }

            if outcomes.isEmpty {
                ContentUnavailableView("No results yet", systemImage: "square.stack.3d.up",
                                       description: Text("Execute the script to query "
                                                         + "every server in this group."))
            } else {
                HSplitView {
                    Table(outcomes) {
                        TableColumn("Server") { outcome in
                            HStack(spacing: 5) {
                                Image(systemName: outcome.succeeded
                                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                                Text(outcome.serverName).lineLimit(1)
                            }
                        }.width(min: 130, ideal: 170)
                        TableColumn("Rows") { Text("\($0.rows.count)").monospacedDigit() }.width(60)
                        TableColumn("Time") {
                            Text(String(format: "%.2f s", $0.elapsed)).monospacedDigit()
                        }.width(70)
                        TableColumn("Message") {
                            Text($0.message).foregroundStyle(.secondary).lineLimit(1)
                        }.width(min: 120, ideal: 200)
                    }
                    .frame(minWidth: 340)

                    if let combined, !combined.isEmpty {
                        ReportTableView(result: combined).frame(minWidth: 380)
                    } else {
                        ContentUnavailableView("No rows", systemImage: "tray",
                                               description: Text("No server returned rows, or "
                                                                 + "their shapes differ."))
                            .frame(minWidth: 380)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Copy Combined") {
                guard let combined else { return }
                let header = combined.columns.joined(separator: "\t")
                let body = combined.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(header + "\n" + body, forType: .string)
            }
            .disabled(combined?.isEmpty ?? true)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func run() async {
        isRunning = true
        outcomes = []
        progress = 0
        defer { isRunning = false }

        let total = Double(max(profiles.count, 1))
        var completed = 0.0

        for profile in profiles {
            guard isRunning else { break }
            let started = Date()
            let password = await app.connections.password(for: profile)
            var outcome = ServerOutcome(id: profile.id, serverName: profile.displayName,
                                        succeeded: false, message: "", elapsed: 0,
                                        columns: [], rows: [])
            do {
                let session = try await SQLServerSession.connect(profile: profile,
                                                                 password: password)
                let connection = try await session.openConnection()
                let result = try await connection.query(script)
                try? await connection.close()
                await session.close()

                if let set = result.resultSets.first {
                    let converted = ServerReports.convert(set)
                    outcome.columns = converted.columns
                    outcome.rows = converted.rows
                }
                outcome.succeeded = true
                outcome.message = result.errors.isEmpty
                    ? "\(outcome.rows.count) rows"
                    : result.errors[0].text
                if !result.errors.isEmpty { outcome.succeeded = false }
            } catch {
                outcome.succeeded = false
                outcome.message = String(describing: error)
            }
            outcome.elapsed = Date().timeIntervalSince(started)
            outcomes.append(outcome)
            completed += 1
            progress = completed / total
        }

        let ok = outcomes.filter(\.succeeded).count
        status = "\(ok) of \(outcomes.count) servers succeeded."
    }
}
