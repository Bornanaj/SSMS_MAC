import Foundation
import SQLServerKit

/// Backing store for the Object Explorer outline: which nodes exist, which are
/// expanded, and which are still loading. Children are fetched lazily on expand.
@MainActor
final class ObjectExplorerModel: ObservableObject {
    @Published private(set) var roots: [ObjectExplorerNode] = []
    @Published private(set) var childrenByID: [String: [ObjectExplorerNode]] = [:]
    @Published private(set) var loadingIDs: Set<String> = []
    @Published private(set) var errorsByID: [String: String] = [:]
    @Published var expandedIDs: Set<String> = []
    @Published var selectedID: String?
    @Published var filterText: String = ""
    @Published var showSystemObjects: Bool = false

    private var servicesBySession: [UUID: MetadataService] = [:]
    private var nodeIndex: [String: ObjectExplorerNode] = [:]

    func addServer(session: SQLServerSession) async {
        let service = MetadataService(session: session)
        servicesBySession[session.id] = service
        let root = await service.rootNode()
        nodeIndex[root.id] = root
        roots.append(root)
        selectedID = root.id
        await expand(root)
    }

    func removeServer(sessionID: UUID) {
        servicesBySession[sessionID] = nil
        let prefix = sessionID.uuidString
        roots.removeAll { $0.id.hasPrefix(prefix) }
        for key in childrenByID.keys where key.hasPrefix(prefix) { childrenByID[key] = nil }
        expandedIDs = expandedIDs.filter { !$0.hasPrefix(prefix) }
        nodeIndex = nodeIndex.filter { !$0.key.hasPrefix(prefix) }
    }

    func node(id: String) -> ObjectExplorerNode? { nodeIndex[id] }

    func children(of node: ObjectExplorerNode) -> [ObjectExplorerNode] {
        childrenByID[node.id] ?? []
    }

    func isExpanded(_ node: ObjectExplorerNode) -> Bool { expandedIDs.contains(node.id) }
    func isLoading(_ node: ObjectExplorerNode) -> Bool { loadingIDs.contains(node.id) }
    func error(for node: ObjectExplorerNode) -> String? { errorsByID[node.id] }

    func toggle(_ node: ObjectExplorerNode) async {
        if expandedIDs.contains(node.id) {
            expandedIDs.remove(node.id)
        } else {
            await expand(node)
        }
    }

    func expand(_ node: ObjectExplorerNode) async {
        expandedIDs.insert(node.id)
        guard childrenByID[node.id] == nil else { return }
        await load(node, reloadingExpandedChildren: false)
    }

    /// Lists `node` again, together with everything open underneath it. Node ids are
    /// paths, so the listings cached for its descendants are the keys that start with
    /// its own id; dropping only the node's own entry left a table's open Columns
    /// folder showing the columns from before the change.
    func refresh(_ node: ObjectExplorerNode) async {
        forgetSubtree(of: node.id)
        await load(node, reloadingExpandedChildren: true)
    }

    /// Applies the current filter and system-object setting to the whole tree: every
    /// open node is listed again, and every closed listing is forgotten so that it is
    /// read with the new options when it is next opened. Expansion state is kept.
    func reloadAll() async {
        var open = Set<String>()
        func walk(_ nodes: [ObjectExplorerNode]) {
            for node in nodes where expandedIDs.contains(node.id) {
                open.insert(node.id)
                walk(childrenByID[node.id] ?? [])
            }
        }
        walk(roots)
        // Open listings stay on screen until their replacement arrives, so the tree
        // does not collapse to the server names while the catalog is read again.
        childrenByID = childrenByID.filter { open.contains($0.key) }
        errorsByID = errorsByID.filter { open.contains($0.key) }
        for root in roots where expandedIDs.contains(root.id) {
            await load(root, reloadingExpandedChildren: true)
        }
    }

    /// Lists a table again after a sheet changed it on the server, wherever it appears
    /// in the tree of the session that owns it. A table the tree has never listed has
    /// nothing cached, so there is nothing to do for it.
    func refreshTable(sessionID: UUID, database: String, schema: String, table: String) async {
        let matches = nodeIndex.values.filter { node in
            (node.kind == .table || node.kind == .externalTable)
                && self.sessionID(for: node) == sessionID
                && node.database?.caseInsensitiveCompare(database) == .orderedSame
                && node.schema?.caseInsensitiveCompare(schema) == .orderedSame
                && node.name?.caseInsensitiveCompare(table) == .orderedSame
        }
        for node in matches.sorted(by: { $0.id < $1.id }) {
            await refresh(node)
        }
    }

    private func forgetSubtree(of id: String) {
        let prefix = id + "/"
        childrenByID[id] = nil
        errorsByID[id] = nil
        for key in childrenByID.keys where key.hasPrefix(prefix) { childrenByID[key] = nil }
        for key in errorsByID.keys where key.hasPrefix(prefix) { errorsByID[key] = nil }
    }

    /// Lists `node`'s children, then whichever of them are open: all of them when the
    /// listing is being redone, otherwise only those with no listing of their own,
    /// because `visibleRows` shows an open node's children straight from the cache and
    /// nothing else would ever fill an empty one in.
    private func load(_ node: ObjectExplorerNode, reloadingExpandedChildren: Bool) async {
        guard let sessionID = sessionID(for: node), let service = servicesBySession[sessionID] else { return }
        loadingIDs.insert(node.id)
        defer { loadingIDs.remove(node.id) }

        var options = ObjectExplorerOptions()
        options.showSystemObjects = showSystemObjects
        options.nameFilter = filterText.isEmpty ? nil : filterText

        let result: [ObjectExplorerNode]
        do {
            result = try await service.children(of: node, options: options)
            for child in result { nodeIndex[child.id] = child }
            childrenByID[node.id] = result
            errorsByID[node.id] = nil
        } catch {
            childrenByID[node.id] = []
            errorsByID[node.id] = String(describing: error)
            return
        }

        for child in result where expandedIDs.contains(child.id) {
            if reloadingExpandedChildren || childrenByID[child.id] == nil {
                await load(child, reloadingExpandedChildren: reloadingExpandedChildren)
            }
        }
    }

    private func sessionID(for node: ObjectExplorerNode) -> UUID? {
        let head = node.id.split(separator: "/").first.map(String.init) ?? ""
        return UUID(uuidString: head)
    }

    func service(for node: ObjectExplorerNode) -> MetadataService? {
        guard let sessionID = sessionID(for: node) else { return nil }
        return servicesBySession[sessionID]
    }

    // MARK: - Keyboard navigation

    /// The rows the keyboard walks, which is exactly what the outline shows.
    private var visibleNodes: [ObjectExplorerNode] { visibleRows.map(\.node) }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return visibleNodes.firstIndex { $0.id == selectedID }
    }

    /// Moves the selection by whole rows. Returns false when there is nowhere to go,
    /// so the view can let the key fall through.
    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        let nodes = visibleNodes
        guard !nodes.isEmpty else { return false }
        guard let current = selectedIndex else {
            selectedID = nodes.first?.id
            return true
        }
        let target = current + delta
        guard nodes.indices.contains(target) else { return false }
        selectedID = nodes[target].id
        return true
    }

    func selectFirst() { selectedID = visibleNodes.first?.id }
    func selectLast() { selectedID = visibleNodes.last?.id }

    /// Right arrow: open a closed node, or step into an open one, the way every
    /// outline on this platform behaves.
    @discardableResult
    func expandSelection() async -> Bool {
        guard let id = selectedID, let node = nodeIndex[id] else { return false }
        if node.isExpandable && !expandedIDs.contains(id) {
            await expand(node)
            return true
        }
        return moveSelection(by: 1)
    }

    /// Left arrow: close an open node, or step out to its parent.
    @discardableResult
    func collapseSelection() -> Bool {
        guard let id = selectedID, let node = nodeIndex[id] else { return false }
        if node.isExpandable && expandedIDs.contains(id) {
            expandedIDs.remove(id)
            return true
        }
        guard let parentID = node.parentID, nodeIndex[parentID] != nil else { return false }
        selectedID = parentID
        return true
    }

    /// Flattened rows for the outline, honouring the current expansion state.
    var visibleRows: [(node: ObjectExplorerNode, depth: Int)] {
        var rows: [(ObjectExplorerNode, Int)] = []
        func walk(_ nodes: [ObjectExplorerNode], depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if expandedIDs.contains(node.id) {
                    walk(childrenByID[node.id] ?? [], depth: depth + 1)
                }
            }
        }
        walk(roots, depth: 0)
        return rows
    }
}
