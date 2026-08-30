import SwiftUI
import SQLServerKit

/// Database Properties: the General / Files / Options pages SSMS shows.
struct DatabasePropertiesView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var properties: DatabaseProperties?
    @State private var errorText: String?
    @State private var page = "general"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "cylinder").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Database Properties").font(.headline)
                    Text(database).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            Divider()
            Picker("", selection: $page) {
                Text("General").tag("general")
                Text("Files").tag("files")
                Text("Options").tag("options")
                Text("Backup").tag("backup")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            content
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 540)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read properties", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if let properties {
            ScrollView {
                switch page {
                case "files": filesPage(properties)
                case "options": optionsPage(properties)
                case "backup": backupPage(properties)
                default: generalPage(properties)
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func generalPage(_ p: DatabaseProperties) -> some View {
        PropertyGrid(rows: [
            ("Name", p.name),
            ("Database ID", "\(p.databaseID)"),
            ("Owner", p.owner),
            ("Status", p.state),
            ("Date created", p.createDate),
            ("Collation", p.collation),
            ("Compatibility level", "\(p.compatibilityLevel)"),
            ("Recovery model", p.recoveryModel),
            ("Size", String(format: "%.2f MB", p.sizeMB)),
            ("Space available", String(format: "%.2f MB", p.spaceAvailableMB)),
            ("Number of files", "\(p.files.count)")
        ])
    }

    private func filesPage(_ p: DatabaseProperties) -> some View {
        Table(p.files) {
            TableColumn("Logical name", value: \.name).width(140)
            TableColumn("Type", value: \.type).width(80)
            TableColumn("Filegroup", value: \.filegroup).width(100)
            TableColumn("Size (MB)") { Text(String(format: "%.0f", $0.sizeMB)).monospacedDigit() }
                .width(90)
            TableColumn("Used (MB)") { Text(String(format: "%.0f", $0.usedMB)).monospacedDigit() }
                .width(90)
            TableColumn("Autogrowth", value: \.growth).width(190)
            TableColumn("Path") { Text($0.physicalName).lineLimit(1) }.width(min: 160, ideal: 260)
        }
        .frame(minHeight: 340)
    }

    private func optionsPage(_ p: DatabaseProperties) -> some View {
        PropertyGrid(rows: [
            ("Recovery model", p.recoveryModel),
            ("Compatibility level", "\(p.compatibilityLevel)"),
            ("Collation", p.collation),
            ("Read-only", p.isReadOnly ? "True" : "False"),
            ("Auto close", p.isAutoClose ? "True" : "False"),
            ("Auto shrink", p.isAutoShrink ? "True" : "False"),
            ("Snapshot isolation", p.snapshotIsolationState),
            ("Read committed snapshot", p.isReadCommittedSnapshotOn ? "True" : "False"),
            ("Page verify", p.pageVerifyOption),
            ("Restrict access", p.userAccess)
        ])
    }

    private func backupPage(_ p: DatabaseProperties) -> some View {
        PropertyGrid(rows: [
            ("Last database backup", p.lastFullBackup.isEmpty ? "None" : p.lastFullBackup),
            ("Last differential backup",
             p.lastDifferentialBackup.isEmpty ? "None" : p.lastDifferentialBackup),
            ("Last log backup", p.lastLogBackup.isEmpty ? "None" : p.lastLogBackup),
            ("Recovery model", p.recoveryModel)
        ])
    }

    private func load() async {
        do {
            properties = try await DatabaseAdmin(session: server.session).properties(database: database)
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Table Properties: storage numbers and the object's identity.
struct TablePropertiesView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String
    let schema: String
    let table: String

    @State private var properties: TableProperties?
    @State private var columns: [ColumnMetadata] = []
    @State private var errorText: String?
    @State private var page = "general"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "tablecells").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Table Properties").font(.headline)
                    Text("\(database).\(schema).\(table)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()
            Picker("", selection: $page) {
                Text("General").tag("general")
                Text("Columns").tag("columns")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read properties", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if page == "columns" {
            Table(columns) {
                TableColumn("Name", value: \.name).width(180)
                TableColumn("Type", value: \.typeName).width(150)
                TableColumn("Null") { Text($0.isNullable ? "Yes" : "No") }.width(60)
                TableColumn("Identity") { Text($0.isIdentity ? "Yes" : "") }.width(70)
                TableColumn("Key") { Text($0.isPrimaryKey ? "PK" : "") }.width(50)
                TableColumn("Default") { Text($0.defaultDefinition).lineLimit(1) }
                    .width(min: 100, ideal: 160)
            }
        } else if let properties {
            ScrollView {
                PropertyGrid(rows: [
                    ("Schema", properties.schema),
                    ("Name", properties.name),
                    ("Object ID", "\(properties.objectID)"),
                    ("Created", properties.createDate),
                    ("Last modified", properties.modifyDate),
                    ("Rows", "\(properties.rowCount)"),
                    ("Columns", "\(properties.columnCount)"),
                    ("Indexes", "\(properties.indexCount)"),
                    ("Primary key", properties.hasPrimaryKey ? "Yes" : "No"),
                    ("Data space", formatKB(properties.dataSpaceKB)),
                    ("Index space", formatKB(properties.indexSpaceKB)),
                    ("Unused space", formatKB(properties.unusedSpaceKB)),
                    ("Total space", formatKB(properties.totalSpaceKB)),
                    ("Filegroup", properties.fileGroup),
                    ("Partitions", "\(properties.partitionCount)"),
                    ("Memory optimized", properties.isMemoryOptimized ? "Yes" : "No"),
                    ("System versioned", properties.isTemporal ? "Yes" : "No")
                ])
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func formatKB(_ value: Int64) -> String {
        value >= 1024
            ? String(format: "%.2f MB", Double(value) / 1024)
            : "\(value) KB"
    }

    private func load() async {
        let admin = DatabaseAdmin(session: server.session)
        let metadata = MetadataService(session: server.session)
        do {
            properties = try await admin.tableProperties(database: database, schema: schema,
                                                         table: table)
            columns = try await metadata.columns(database: database, schema: schema, table: table)
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Two-column label/value grid used by the property sheets.
struct PropertyGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.1.isEmpty ? "—" : row.1)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A stored showplan in the same operator tree the query window uses. Query Store keeps
/// plans for queries that finished long ago, so this is the only way to look at them.
struct PlanPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let xml: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(title).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ExecutionPlanView(xml: xml)
            Divider()
            HStack {
                Button("Copy Plan XML") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(xml, forType: .string)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 920, height: 640)
    }
}

/// Read-only preview of a generated script with copy / open-in-editor actions.
struct ScriptPreviewSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let title: String
    let sql: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(sql)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sql, forType: .string)
                }
                Button("Open in New Query Window") {
                    app.openScript(sql, server: app.servers.first, database: nil, title: title)
                    dismiss()
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
    }
}
