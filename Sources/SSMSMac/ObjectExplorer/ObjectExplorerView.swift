import SwiftUI
import SQLServerKit

/// The Object Explorer sidebar: lazy tree, filter box, and the context menus that
/// make up most of SSMS's day-to-day surface area.
struct ObjectExplorerView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ObjectExplorerModel
    @State private var filterDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.roots.isEmpty {
                ContentUnavailableView {
                    Label("Not connected", systemImage: "server.rack")
                } description: {
                    Text("Connect to a SQL Server instance to browse its objects.")
                } actions: {
                    Button("Connect…") { app.activeSheet = .connect }
                }
            } else {
                tree
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    app.activeSheet = .connect
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Connect to a server")

                Button {
                    guard let id = model.selectedID, let node = model.node(id: id) else { return }
                    Task { await model.refresh(node) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh the selected node")

                Toggle(isOn: $model.showSystemObjects) {
                    Image(systemName: "gearshape.2")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Show system objects")

                Toggle(isOn: $app.showExplorerDetails) {
                    Image(systemName: "list.bullet.rectangle")
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("Object Explorer Details (⌘7)")

                Spacer()
            }
            .padding(.horizontal, 8)

            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { applyFilter() }
                if !filterDraft.isEmpty {
                    Button {
                        filterDraft = ""
                        applyFilter()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 6)
    }

    private func applyFilter() {
        model.filterText = filterDraft
        Task {
            for root in model.roots { await model.refresh(root) }
        }
    }

    private var tree: some View {
        List(selection: $model.selectedID) {
            ForEach(model.visibleRows, id: \.node.id) { row in
                nodeRow(row.node, depth: row.depth)
                    .tag(row.node.id)
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 22)
    }

    @ViewBuilder
    private func nodeRow(_ node: ObjectExplorerNode, depth: Int) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)

            if node.isExpandable {
                Button {
                    Task { await model.toggle(node) }
                } label: {
                    Image(systemName: model.isExpanded(node) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            if model.isLoading(node) {
                ProgressView().controlSize(.mini).frame(width: 14)
            } else {
                Image(systemName: node.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(iconTint(node))
                    .frame(width: 14)
            }

            Text(node.label)
                .lineLimit(1)
                .truncationMode(.middle)

            if let detail = node.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            Task { await handleDoubleClick(node) }
        }
        .contextMenu { ObjectExplorerMenu(node: node, model: model) }
        .help(model.error(for: node) ?? node.displayPath)
    }

    private func iconTint(_ node: ObjectExplorerNode) -> Color {
        if model.error(for: node) != nil { return .red }
        switch node.kind {
        case .folder: return .secondary
        case .database: return .blue
        case .table: return .teal
        case .view: return .purple
        case .storedProcedure, .scalarFunction, .tableValuedFunction, .aggregateFunction: return .orange
        case .primaryKey, .uniqueKey, .foreignKey: return .yellow
        case .index: return .indigo
        case .login, .databaseUser, .databaseRole, .serverRole: return .pink
        default: return .accentColor
        }
    }

    private func handleDoubleClick(_ node: ObjectExplorerNode) async {
        if node.isExpandable {
            await model.toggle(node)
            return
        }
        if node.isTableLike {
            await ObjectExplorerActions.selectTopRows(node: node, app: app)
        }
    }
}
