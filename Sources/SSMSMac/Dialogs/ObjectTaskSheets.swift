import SwiftUI
import AppKit
import SQLServerKit

/// Rename, which SSMS does inline in the tree. A sheet is clearer about what will run.
struct RenameObjectSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let node: ObjectExplorerNode

    @State private var newName = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Rename", subtitle: node.displayPath, symbol: "pencil")
            Divider()
            Form {
                Section {
                    LabeledContent("Current name", value: node.name ?? node.label)
                    TextField("New name", text: $newName)
                } footer: {
                    Text(footerText).font(.caption)
                }
            }
            .formStyle(.grouped)

            if let errorText { SheetError(text: errorText) }
            Divider()
            HStack {
                Button("Script") { script() }.disabled(!canRename)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { Task { await rename() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename || isWorking)
            }
            .padding(12)
        }
        .frame(width: 560, height: 320)
        .onAppear { newName = node.name ?? node.label }
    }

    private var supported: Bool { ObjectAdmin.canRename(node.kind) }

    private var footerText: String {
        if !supported { return "This object type cannot be renamed." }
        if node.kind == .database {
            return "ALTER DATABASE … MODIFY NAME needs exclusive access, so open "
                + "connections to the database will be in the way."
        }
        return "sp_rename does not update references to the object. Views, procedures and "
            + "functions that name it keep the old name until they are altered."
    }

    private var canRename: Bool {
        supported && !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && newName != (node.name ?? node.label)
    }

    private func script() {
        do {
            let sql = try ObjectAdmin.renameScript(node: node, to: newName)
            app.activeSheet = .scriptPreview("Rename \(node.displayPath)", sql)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func rename() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session).rename(node: node, to: newName)
            app.statusMessage = "Renamed \(node.displayPath) to \(newName)."
            if node.kind == .database {
                await refreshDatabasesFolder(server: server, app: app)
            } else {
                await refreshParent(of: node, app: app)
            }
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Delete Object: SSMS's confirmation dialog, with the dependants it would break.
struct DeleteObjectSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let node: ObjectExplorerNode

    @State private var dependants: [ObjectDependency] = []
    @State private var isLoadingDependants = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Delete Object", subtitle: node.displayPath, symbol: "trash")
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Delete \(kindTitle) \(node.displayPath)?")
                    .font(.headline)
                if let sql = try? ObjectAdmin.dropScript(node: node) {
                    Text(sql)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 6))
                }

                if isLoadingDependants {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking dependencies…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !dependants.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("\(dependants.count) object(s) depend on this one",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        ForEach(dependants.prefix(12)) { dependency in
                            Text("• \(dependency.qualifiedName) (\(dependency.typeDescription))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if dependants.count > 12 {
                            Text("…and \(dependants.count - 12) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(12)

            if let errorText { SheetError(text: errorText) }
            Divider()
            HStack {
                Button("Script") { script() }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { Task { await drop() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
        .task { await loadDependants() }
    }

    private var kindTitle: String {
        ObjectAdmin.dropKeyword(for: node.kind)?.lowercased() ?? "object"
    }

    private func script() {
        do {
            app.activeSheet = .scriptPreview("Drop \(node.displayPath)",
                                             try ObjectAdmin.dropScript(node: node))
        } catch {
            errorText = String(describing: error)
        }
    }

    private func drop() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session).drop(node: node)
            app.statusMessage = "Deleted \(node.displayPath)."
            if node.kind == .database {
                await refreshDatabasesFolder(server: server, app: app)
            } else {
                await refreshParent(of: node, app: app)
            }
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func loadDependants() async {
        guard let database = node.database, let schema = node.schema, let name = node.name,
              node.isTableLike || node.isModule else { return }
        isLoadingDependants = true
        defer { isLoadingDependants = false }
        dependants = (try? await ObjectAdmin(session: server.session)
            .dependencies(database: database, schema: schema, name: name,
                          direction: .usedBy)) ?? []
    }
}

/// View Dependencies: both directions, expandable one level at a time like SSMS.
struct DependenciesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let node: ObjectExplorerNode

    @State private var direction: DependencyDirection = .usedBy
    @State private var rows: [DependencyRow] = []
    @State private var expanded: Set<String> = []
    @State private var isLoading = false
    @State private var errorText: String?

    /// A dependency plus where it sits in the tree, so one flat List can draw a tree.
    struct DependencyRow: Identifiable, Hashable {
        var id: String
        var dependency: ObjectDependency
        var depth: Int
        var hasChildren: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Object Dependencies", subtitle: node.displayPath,
                        symbol: "arrow.triangle.branch")
            Divider()
            Picker("", selection: $direction) {
                ForEach(DependencyDirection.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            .onChange(of: direction) { _, _ in Task { await load() } }
            Divider()

            if let errorText {
                SheetError(text: errorText)
                Spacer()
            } else if isLoading && rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView("No dependencies", systemImage: "arrow.triangle.branch",
                                       description: Text(direction == .usedBy
                                           ? "Nothing references this object."
                                           : "This object references nothing."))
            } else {
                List {
                    ForEach(rows) { row in
                        dependencyRow(row)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(rows.count) row\(rows.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 520)
        .task { await load() }
    }

    private func dependencyRow(_ row: DependencyRow) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.hasChildren {
                Button {
                    Task { await toggle(row) }
                } label: {
                    Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Image(systemName: symbol(for: row.dependency.nodeKind))
                .font(.system(size: 11))
                .foregroundStyle(row.dependency.isUnresolved ? Color.red : Color.accentColor)
            Text(row.dependency.qualifiedName)
            if !row.dependency.columnName.isEmpty {
                Text("(\(row.dependency.columnName))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(row.dependency.isUnresolved ? "unresolved" : row.dependency.typeDescription)
                .font(.caption)
                .foregroundStyle(row.dependency.isUnresolved ? Color.red : Color.secondary)
            Spacer()
        }
        .contextMenu {
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.dependency.qualifiedName, forType: .string)
            }
        }
    }

    private func symbol(for kind: ObjectNodeKind) -> String {
        switch kind {
        case .table: return "tablecells"
        case .view: return "eye"
        case .storedProcedure, .scalarFunction, .tableValuedFunction, .aggregateFunction:
            return "function"
        case .trigger: return "bolt"
        case .synonym: return "link"
        default: return "doc"
        }
    }

    /// Children are fetched when a row is opened, which keeps a deep graph cheap.
    private func toggle(_ row: DependencyRow) async {
        if expanded.contains(row.id) {
            expanded.remove(row.id)
            rows.removeAll { $0.id.hasPrefix(row.id + "/") }
            return
        }
        guard let database = node.database else { return }
        expanded.insert(row.id)
        let children = (try? await ObjectAdmin(session: server.session)
            .dependencies(database: database,
                          schema: row.dependency.schema,
                          name: row.dependency.name,
                          direction: direction)) ?? []
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let childRows = children.map { child in
            DependencyRow(id: "\(row.id)/\(child.qualifiedName)",
                          dependency: child,
                          depth: row.depth + 1,
                          hasChildren: !child.isUnresolved)
        }
        rows.insert(contentsOf: childRows, at: index + 1)
    }

    private func load() async {
        guard let database = node.database, let schema = node.schema, let name = node.name else {
            errorText = "This node is not an object with dependencies."
            return
        }
        isLoading = true
        defer { isLoading = false }
        expanded.removeAll()
        do {
            let found = try await ObjectAdmin(session: server.session)
                .dependencies(database: database, schema: schema, name: name, direction: direction)
            rows = found.map {
                DependencyRow(id: $0.qualifiedName, dependency: $0, depth: 0,
                              hasChildren: !$0.isUnresolved)
            }
            errorText = nil
        } catch {
            errorText = String(describing: error)
            rows = []
        }
    }
}

/// The Permissions page: who has what, plus grant / deny / revoke.
struct PermissionsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let node: ObjectExplorerNode

    @State private var entries: [PermissionEntry] = []
    @State private var principals: [String] = []
    @State private var permissionNames: [String] = []
    @State private var selectedPrincipal = ""
    @State private var selectedPermission = ""
    @State private var action: PermissionAction = .grant
    @State private var withGrantOption = false
    @State private var cascade = false
    @State private var isWorking = false
    @State private var errorText: String?

    private var target: PermissionTarget { app.permissionTarget(for: node) }

    private var databaseScope: String {
        node.database ?? server.serverInfo.currentDatabase
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Permissions", subtitle: target.describedScope,
                        symbol: "lock.shield")
            Divider()

            if entries.isEmpty && errorText == nil && isWorking {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(entries) {
                    TableColumn("Principal", value: \.principal).width(min: 130, ideal: 180)
                    TableColumn("Type") { Text(humanised($0.principalType)) }.width(110)
                    TableColumn("Permission", value: \.permission).width(min: 130, ideal: 180)
                    TableColumn("State") { entry in
                        Text(stateTitle(entry))
                            .foregroundStyle(entry.isDenied ? Color.red : Color.primary)
                    }.width(150)
                    TableColumn("Column") { Text($0.columnName) }.width(110)
                    TableColumn("Granted by") { Text($0.grantor) }.width(120)
                }
            }

            Divider()
            editor
            if let errorText { SheetError(text: errorText) }
            Divider()
            HStack {
                Text("\(entries.count) explicit permission\(entries.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await load() } }
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 880, height: 600)
        .task { await load() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Action", selection: $action) {
                    ForEach(PermissionAction.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 160)
                Picker("Permission", selection: $selectedPermission) {
                    Text("<choose>").tag("")
                    ForEach(permissionNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 240)
                Picker("Principal", selection: $selectedPrincipal) {
                    Text("<choose>").tag("")
                    ForEach(principals, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
                Spacer()
            }
            HStack(spacing: 12) {
                if action == .grant {
                    Toggle("With grant option", isOn: $withGrantOption)
                }
                if action == .revoke {
                    Toggle("Cascade", isOn: $cascade)
                }
                Spacer()
                Button("Script") { script() }.disabled(!canApply)
                Button("Apply") { Task { await apply() } }
                    .disabled(!canApply || isWorking)
            }
        }
        .padding(12)
    }

    private var canApply: Bool {
        !selectedPermission.isEmpty && !selectedPrincipal.isEmpty
    }

    private func stateTitle(_ entry: PermissionEntry) -> String {
        entry.allowsGranting ? "Grant with grant option" : entry.state.capitalized
    }

    private func humanised(_ typeDesc: String) -> String {
        typeDesc.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }

    private func statement() throws -> String {
        try ObjectAdmin.permissionStatement(action: action,
                                            permission: selectedPermission,
                                            on: target,
                                            to: selectedPrincipal,
                                            withGrantOption: withGrantOption,
                                            cascade: cascade)
    }

    private func script() {
        do {
            var sql = ""
            // A server permission is granted from master; everything else needs its database.
            if target != .server {
                sql += "USE \(SQLIdentifier.quote(databaseScope));\nGO\n"
            }
            sql += try statement() + "\nGO\n"
            app.activeSheet = .scriptPreview("\(action.title) \(selectedPermission)", sql)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func apply() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session)
                .applyPermission(database: databaseScope,
                                 action: action,
                                 permission: selectedPermission,
                                 target: target,
                                 principal: selectedPrincipal,
                                 withGrantOption: withGrantOption,
                                 cascade: cascade)
            app.statusMessage = "\(action.title) \(selectedPermission) applied."
            errorText = nil
            await load()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func load() async {
        isWorking = true
        defer { isWorking = false }
        let admin = ObjectAdmin(session: server.session)
        do {
            entries = try await admin.permissions(database: databaseScope, target: target)
            principals = (try? await admin.principals(database: databaseScope, target: target)) ?? []
            permissionNames = (try? await admin.availablePermissions(database: databaseScope,
                                                                     target: target)) ?? []
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// After a rename or a delete, the node's own folder is stale.
@MainActor
func refreshParent(of node: ObjectExplorerNode, app: AppState) async {
    guard let parentID = node.parentID, let parent = app.explorer.node(id: parentID) else { return }
    await app.explorer.refresh(parent)
}
