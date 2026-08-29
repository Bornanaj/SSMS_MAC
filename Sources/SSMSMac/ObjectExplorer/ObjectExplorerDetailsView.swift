import SwiftUI
import AppKit
import SQLServerKit

/// Object Explorer Details — the F7 pane. Lists the children of the selected node as a
/// sortable table, which is far easier to scan than the tree when a folder holds
/// hundreds of objects.
struct ObjectExplorerDetailsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ObjectExplorerModel

    @State private var sortOrder: [KeyPathComparator<DetailRow>] = [
        KeyPathComparator(\DetailRow.name)
    ]
    @State private var selection: String?
    @State private var filter = ""

    /// One row of the details table. The tree's node is carried along so the context menu
    /// and double-click behave exactly as they do in the tree.
    struct DetailRow: Identifiable, Hashable {
        var id: String { node.id }
        var node: ObjectExplorerNode

        var name: String { node.label }
        var kind: String { node.folder != nil ? "Folder" : DetailRow.kindTitle(node.kind) }
        var schema: String { node.schema ?? "" }
        var detail: String { node.detail ?? "" }
        var created: String { node.info["createDate"] ?? "" }
        var modified: String { node.info["modifyDate"] ?? "" }

        static func kindTitle(_ kind: ObjectNodeKind) -> String {
            switch kind {
            case .table: return "Table"
            case .externalTable: return "External Table"
            case .view: return "View"
            case .column: return "Column"
            case .index: return "Index"
            case .primaryKey: return "Primary Key"
            case .uniqueKey: return "Unique Key"
            case .foreignKey: return "Foreign Key"
            case .checkConstraint: return "Check Constraint"
            case .defaultConstraint: return "Default"
            case .trigger: return "Trigger"
            case .storedProcedure: return "Stored Procedure"
            case .scalarFunction: return "Scalar Function"
            case .tableValuedFunction: return "Table-valued Function"
            case .aggregateFunction: return "Aggregate Function"
            case .synonym: return "Synonym"
            case .sequence: return "Sequence"
            case .database: return "Database"
            case .schema: return "Schema"
            case .databaseUser: return "User"
            case .databaseRole: return "Database Role"
            case .applicationRole: return "Application Role"
            case .login: return "Login"
            case .serverRole: return "Server Role"
            case .credential: return "Credential"
            case .linkedServer: return "Linked Server"
            case .filegroup: return "Filegroup"
            case .databaseFile: return "Database File"
            case .parameter: return "Parameter"
            case .statistic: return "Statistics"
            case .assembly: return "Assembly"
            case .xmlSchemaCollection: return "XML Schema Collection"
            case .partitionFunction: return "Partition Function"
            case .partitionScheme: return "Partition Scheme"
            case .agentJob: return "Agent Job"
            case .userDefinedDataType: return "User-Defined Data Type"
            case .userDefinedTableType: return "User-Defined Table Type"
            case .server: return "Server"
            default: return "Object"
            }
        }
    }

    private var parent: ObjectExplorerNode? {
        app.selectedExplorerNode
    }

    private var rows: [DetailRow] {
        guard let parent else { return [] }
        // A leaf node shows its siblings, which is what SSMS does when you click a table
        // inside a folder.
        let source: [ObjectExplorerNode]
        if parent.isExpandable, !model.children(of: parent).isEmpty {
            source = model.children(of: parent)
        } else if let parentID = parent.parentID, let grandparent = model.node(id: parentID) {
            source = model.children(of: grandparent)
        } else {
            source = model.children(of: parent)
        }
        let matching = filter.isEmpty
            ? source
            : source.filter { $0.label.localizedCaseInsensitiveContains(filter) }
        return matching.map { DetailRow(node: $0) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("Nothing to show", systemImage: "list.bullet.rectangle",
                                       description: Text(parent == nil
                                           ? "Select a node in the tree."
                                           : "Expand the node to load its children."))
                    .frame(minHeight: 120)
            } else {
                table
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.tint)
            Text(parent?.displayPath ?? "Object Explorer Details")
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text("\(rows.count) item\(rows.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 160)
            Button {
                app.showExplorerDetails = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Hide the details pane (F7)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var table: some View {
        Table(rows, selection: Binding(
            get: { selection.map { Set([$0]) } ?? [] },
            set: { ids in
                selection = ids.first
                if let id = ids.first { model.selectedID = id }
            }
        ), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 5) {
                    Image(systemName: row.node.iconName).font(.system(size: 11))
                    Text(row.name).lineLimit(1)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Type", value: \.kind).width(150)
            TableColumn("Schema", value: \.schema).width(90)
            TableColumn("Detail", value: \.detail) { row in
                Text(row.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Created", value: \.created).width(150)
            TableColumn("Modified", value: \.modified).width(150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let node = model.node(id: id) {
                ObjectExplorerMenu(node: node, model: model)
            }
        }
    }
}
