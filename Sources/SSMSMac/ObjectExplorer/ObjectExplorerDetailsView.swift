import SwiftUI
import SQLServerKit

/// The list pane SSMS shows beside the tree: the children of the selected node, with
/// columns chosen to suit what is being listed.
struct ObjectExplorerDetailsView: View {
    let server: ConnectedServer
    let node: ObjectExplorerNode

    @State private var children: [ObjectExplorerNode] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var search = ""
    @State private var selection: String?

    private var visible: [ObjectExplorerNode] {
        guard !search.isEmpty else { return children }
        return children.filter {
            $0.label.localizedCaseInsensitiveContains(search)
                || ($0.detail ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: node.id) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: node.iconName).foregroundStyle(.tint)
            Text(node.label).font(.headline).lineLimit(1)
            if isLoading { ProgressView().controlSize(.small) }
            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Button {
                Task { await load(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not list this node",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if visible.isEmpty && !isLoading {
            ContentUnavailableView("Nothing to show", systemImage: "tray",
                                   description: Text(search.isEmpty
                                                     ? "This node has no children."
                                                     : "No child matches \"\(search)\"."))
        } else {
            Table(visible, selection: $selection) {
                TableColumn("Name") { child in
                    HStack(spacing: 6) {
                        Image(systemName: child.iconName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(child.name ?? child.label).lineLimit(1)
                    }
                }.width(min: 160, ideal: 240)

                TableColumn("Schema") { child in
                    Text(child.schema ?? "")
                }.width(110)

                TableColumn("Type") { child in
                    Text(Self.typeLabel(child))
                }.width(140)

                TableColumn("Details") { child in
                    Text(child.detail ?? "").foregroundStyle(.secondary).lineLimit(1)
                }.width(min: 140, ideal: 220)

                TableColumn("Created") { child in
                    Text(child.info["create_date"] ?? child.info["created"] ?? "")
                        .foregroundStyle(.secondary)
                }.width(150)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let child = children.first(where: { $0.id == id }) {
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(child.qualifiedName ?? child.label,
                                                       forType: .string)
                    }
                }
            }
        }
    }

    private static func typeLabel(_ node: ObjectExplorerNode) -> String {
        switch node.kind {
        case .table: return "Table"
        case .view: return "View"
        case .column: return "Column"
        case .index: return "Index"
        case .storedProcedure: return "Stored procedure"
        case .scalarFunction: return "Scalar function"
        case .tableValuedFunction: return "Table-valued function"
        case .aggregateFunction: return "Aggregate function"
        case .trigger: return "Trigger"
        case .primaryKey: return "Primary key"
        case .uniqueKey: return "Unique key"
        case .foreignKey: return "Foreign key"
        case .checkConstraint: return "Check constraint"
        case .defaultConstraint: return "Default constraint"
        case .database: return "Database"
        case .schema: return "Schema"
        case .databaseUser: return "User"
        case .databaseRole, .serverRole: return "Role"
        case .login: return "Login"
        case .folder: return "Folder"
        default: return node.kind.rawValue
        }
    }

    private func load(force: Bool = false) async {
        guard node.isExpandable else {
            children = []
            return
        }
        if !force && !children.isEmpty { return }
        isLoading = true
        defer { isLoading = false }

        var options = ObjectExplorerOptions()
        options.showSystemObjects = AppSettings.shared.showSystemObjects
        let service = MetadataService(session: server.session)
        do {
            children = try await service.children(of: node, options: options)
            errorText = nil
        } catch {
            children = []
            errorText = String(describing: error)
        }
    }
}
