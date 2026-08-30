import Foundation

/// One node of the blocking tree: a session plus everything it is holding up.
public struct BlockingNode: Sendable, Hashable, Identifiable {
    public var id: Int { session.sessionID }
    public var session: ActivitySession
    public var children: [BlockingNode]

    public init(session: ActivitySession, children: [BlockingNode] = []) {
        self.session = session
        self.children = children
    }

    /// Everything below this node, however deep.
    public var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }

    /// The longest path from here to a leaf, counting this node as 1.
    public var chainLength: Int {
        1 + (children.map(\.chainLength).max() ?? 0)
    }
}

/// A blocking tree flattened for a list view.
public struct BlockingRow: Sendable, Hashable, Identifiable {
    public var id: Int { session.sessionID }
    public var session: ActivitySession
    public var depth: Int
    /// `true` when this is the session at the head of the chain.
    public var isHead: Bool

    public init(session: ActivitySession, depth: Int, isHead: Bool) {
        self.session = session
        self.depth = depth
        self.isHead = isHead
    }
}

/// Turns the flat process list into the blocking tree SSMS draws in Activity Monitor.
///
/// This is deliberately pure. The shape of a blocking chain is fiddly enough — heads that
/// are idle, blockers that have already disconnected, chains that loop — that it is worth
/// testing without a server, and the alternative (asking SQL Server for the tree with a
/// recursive CTE) would hand back a different answer than the process list the operator is
/// looking at.
public enum BlockingChain {

    /// Sessions that are blocked or blocking, arranged into trees.
    public static func build(from sessions: [ActivitySession]) -> [BlockingNode] {
        let byID = Dictionary(sessions.map { ($0.sessionID, $0) },
                             uniquingKeysWith: { first, _ in first })

        var waitersByBlocker: [Int: [Int]] = [:]
        for session in sessions where session.isBlocked {
            // A session that reports itself as its own blocker is waiting on a parallel
            // sibling of its own request. That is not a chain, so it is left alone.
            guard session.blockingSessionID != session.sessionID else { continue }
            waitersByBlocker[session.blockingSessionID, default: []].append(session.sessionID)
        }
        guard !waitersByBlocker.isEmpty else { return [] }

        let blockerIDs = Set(waitersByBlocker.keys)
        let waiterIDs = Set(waitersByBlocker.values.flatMap { $0 })

        // A root is a blocker that nothing else is holding up. A blocker that never
        // appeared in the input — it disconnected between the two reads, or it was
        // filtered out as a system session — is still a root; `node(for:)` gives it a
        // placeholder row so its waiters cannot vanish from the tree.
        let rootIDs = blockerIDs.filter { !waiterIDs.contains($0) }.sorted()

        var visited = Set<Int>()
        var roots: [BlockingNode] = []
        for id in rootIDs where !visited.contains(id) {
            guard let node = node(for: id, byID: byID, waitersByBlocker: waitersByBlocker,
                                  visited: &visited) else { continue }
            roots.append(node)
        }

        // Anything still unvisited is part of a cycle. Every member of it is reported as
        // its own root, so a loop can never hide a blocked session from the operator.
        for id in waiterIDs.union(blockerIDs).sorted() where !visited.contains(id) {
            guard let node = node(for: id, byID: byID, waitersByBlocker: waitersByBlocker,
                                  visited: &visited) else { continue }
            roots.append(node)
        }

        return roots
    }

    private static func node(for id: Int,
                             byID: [Int: ActivitySession],
                             waitersByBlocker: [Int: [Int]],
                             visited: inout Set<Int>) -> BlockingNode? {
        guard !visited.contains(id) else { return nil }
        visited.insert(id)
        let session = byID[id] ?? ActivitySession(sessionID: id, status: "gone",
                                                 command: "(session has ended)")
        let children = (waitersByBlocker[id] ?? []).sorted().compactMap {
            node(for: $0, byID: byID, waitersByBlocker: waitersByBlocker, visited: &visited)
        }
        return BlockingNode(session: session, children: children)
    }

    /// Depth-first flattening for a list view.
    public static func rows(from nodes: [BlockingNode]) -> [BlockingRow] {
        var out: [BlockingRow] = []
        func walk(_ node: BlockingNode, depth: Int) {
            out.append(BlockingRow(session: node.session, depth: depth, isHead: depth == 0))
            for child in node.children { walk(child, depth: depth + 1) }
        }
        for node in nodes { walk(node, depth: 0) }
        return out
    }

    /// The head of the worst chain, which is what an operator wants to kill first.
    public static func worstOffender(in nodes: [BlockingNode]) -> BlockingNode? {
        nodes.max { left, right in
            (left.descendantCount, left.chainLength) < (right.descendantCount, right.chainLength)
        }
    }
}
