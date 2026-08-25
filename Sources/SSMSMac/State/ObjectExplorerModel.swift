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
        await load(node)
    }

    func refresh(_ node: ObjectExplorerNode) async {
        childrenByID[node.id] = nil
        errorsByID[node.id] = nil
        await load(node)
    }

    private func load(_ node: ObjectExplorerNode) async {
        guard let sessionID = sessionID(for: node), let service = servicesBySession[sessionID] else { return }
        loadingIDs.insert(node.id)
        defer { loadingIDs.remove(node.id) }

        var options = ObjectExplorerOptions()
        options.showSystemObjects = showSystemObjects
        options.nameFilter = filterText.isEmpty ? nil : filterText

        do {
            let result = try await service.children(of: node, options: options)
            for child in result { nodeIndex[child.id] = child }
            childrenByID[node.id] = result
            errorsByID[node.id] = nil
        } catch {
            childrenByID[node.id] = []
            errorsByID[node.id] = String(describing: error)
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
