import Foundation

/// What happened to one operator between two plans of the same query.
public struct PlanDifference: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable, Hashable {
        /// The operator exists in both plans and does the same work.
        case unchanged
        /// Same position in the tree, different physical operator.
        case operatorChanged
        /// Same operator, materially different cost.
        case costChanged
        /// Same operator, materially different row estimate or actual row count.
        case rowsChanged
        case onlyInLeft
        case onlyInRight

        public var title: String {
            switch self {
            case .unchanged: return "Unchanged"
            case .operatorChanged: return "Operator changed"
            case .costChanged: return "Cost changed"
            case .rowsChanged: return "Rows changed"
            case .onlyInLeft: return "Only in the first plan"
            case .onlyInRight: return "Only in the second plan"
            }
        }

        public var isDifference: Bool { self != .unchanged }
    }

    public var id: String
    public var change: Change
    /// Zero-based statement index the operator belongs to.
    public var statementIndex: Int
    /// Depth in the operator tree, for indenting the list.
    public var depth: Int
    public var leftOperator: String?
    public var rightOperator: String?
    /// Table or index the operator touches, when both sides agree on it.
    public var target: String?
    public var leftCost: Double?
    public var rightCost: Double?
    public var leftRows: Double?
    public var rightRows: Double?

    public init(id: String, change: Change, statementIndex: Int, depth: Int,
                leftOperator: String? = nil, rightOperator: String? = nil,
                target: String? = nil, leftCost: Double? = nil, rightCost: Double? = nil,
                leftRows: Double? = nil, rightRows: Double? = nil) {
        self.id = id
        self.change = change
        self.statementIndex = statementIndex
        self.depth = depth
        self.leftOperator = leftOperator
        self.rightOperator = rightOperator
        self.target = target
        self.leftCost = leftCost
        self.rightCost = rightCost
        self.leftRows = leftRows
        self.rightRows = rightRows
    }

    /// Right minus left: positive means the second plan costs more.
    public var costDelta: Double? {
        guard let leftCost, let rightCost else { return nil }
        return rightCost - leftCost
    }

    public var rowsDelta: Double? {
        guard let leftRows, let rightRows else { return nil }
        return rightRows - leftRows
    }

    public var label: String {
        switch change {
        case .onlyInLeft: return leftOperator ?? ""
        case .onlyInRight: return rightOperator ?? ""
        case .operatorChanged:
            return "\(leftOperator ?? "—") → \(rightOperator ?? "—")"
        default: return leftOperator ?? rightOperator ?? ""
        }
    }
}

/// The whole comparison: headline numbers plus the per-operator findings.
public struct PlanComparison: Sendable, Hashable {
    public var differences: [PlanDifference]
    public var leftStatementCount: Int
    public var rightStatementCount: Int
    public var leftTotalCost: Double
    public var rightTotalCost: Double
    /// True when the two plans have the same shape and the same operators throughout.
    public var isIdentical: Bool { differences.allSatisfy { !$0.change.isDifference } }

    public init(differences: [PlanDifference], leftStatementCount: Int,
                rightStatementCount: Int, leftTotalCost: Double, rightTotalCost: Double) {
        self.differences = differences
        self.leftStatementCount = leftStatementCount
        self.rightStatementCount = rightStatementCount
        self.leftTotalCost = leftTotalCost
        self.rightTotalCost = rightTotalCost
    }

    public var costDelta: Double { rightTotalCost - leftTotalCost }

    /// "38% cheaper" / "2.4× more expensive", the sentence the dialog leads with.
    public var verdict: String {
        if leftTotalCost <= 0 && rightTotalCost <= 0 { return "Neither plan carries a cost." }
        if leftTotalCost <= 0 { return "Only the second plan carries a cost." }
        let ratio = rightTotalCost / leftTotalCost
        if abs(ratio - 1) < 0.01 { return "Both plans cost the same." }
        if ratio < 1 {
            return String(format: "The second plan is %.0f%% cheaper.", (1 - ratio) * 100)
        }
        if ratio >= 2 {
            return String(format: "The second plan costs %.1f× as much.", ratio)
        }
        return String(format: "The second plan is %.0f%% more expensive.", (ratio - 1) * 100)
    }

    public var changedCount: Int { differences.filter { $0.change.isDifference }.count }
}

/// Compares two showplans operator by operator.
///
/// Operators are matched by position in the tree rather than by `NodeId`: a plan that
/// gained an operator renumbers everything below it, so node ids only agree when the
/// plans are already the same. Position matching is what makes "this seek became a
/// scan" fall out as one finding instead of a renumbered cascade.
public enum PlanComparer {

    /// Costs within this fraction of each other are not worth reporting.
    public static let costTolerance = 0.01
    /// Row counts within this fraction of each other are not worth reporting.
    public static let rowTolerance = 0.05

    public static func compare(left: [PlanStatement], right: [PlanStatement]) -> PlanComparison {
        var differences: [PlanDifference] = []
        let statementCount = max(left.count, right.count)

        for index in 0..<max(statementCount, 0) {
            let leftStatement = index < left.count ? left[index] : nil
            let rightStatement = index < right.count ? right[index] : nil

            if leftStatement == nil || rightStatement == nil {
                let present = leftStatement ?? rightStatement
                guard let root = present?.root else { continue }
                let change: PlanDifference.Change = leftStatement == nil ? .onlyInRight : .onlyInLeft
                differences += flatten(root, statementIndex: index, depth: 0,
                                       path: "s\(index)", change: change)
                continue
            }

            differences += walk(left: leftStatement?.root, right: rightStatement?.root,
                                statementIndex: index, depth: 0, path: "s\(index)")
        }

        return PlanComparison(differences: differences,
                              leftStatementCount: left.count,
                              rightStatementCount: right.count,
                              leftTotalCost: totalCost(left),
                              rightTotalCost: totalCost(right))
    }

    /// Convenience for the dialog, which holds two blobs of XML.
    public static func compare(leftXML: String, rightXML: String) -> PlanComparison {
        compare(left: ShowplanParser.parse(leftXML), right: ShowplanParser.parse(rightXML))
    }

    public static func totalCost(_ statements: [PlanStatement]) -> Double {
        statements.reduce(0) { total, statement in
            total + max(statement.subtreeCost, statement.root?.estimatedTotalSubtreeCost ?? 0)
        }
    }

    // MARK: - Walking

    private static func walk(left: PlanNode?, right: PlanNode?, statementIndex: Int,
                             depth: Int, path: String) -> [PlanDifference] {
        switch (left, right) {
        case (nil, nil):
            return []
        case (let node?, nil):
            return flatten(node, statementIndex: statementIndex, depth: depth,
                           path: path, change: .onlyInLeft)
        case (nil, let node?):
            return flatten(node, statementIndex: statementIndex, depth: depth,
                           path: path, change: .onlyInRight)
        case (let leftNode?, let rightNode?):
            var result: [PlanDifference] = [difference(left: leftNode, right: rightNode,
                                                       statementIndex: statementIndex,
                                                       depth: depth, path: path)]
            let childCount = max(leftNode.children.count, rightNode.children.count)
            for index in 0..<max(childCount, 0) {
                result += walk(left: index < leftNode.children.count ? leftNode.children[index] : nil,
                               right: index < rightNode.children.count ? rightNode.children[index] : nil,
                               statementIndex: statementIndex,
                               depth: depth + 1,
                               path: "\(path).\(index)")
            }
            return result
        }
    }

    private static func difference(left: PlanNode, right: PlanNode, statementIndex: Int,
                                   depth: Int, path: String) -> PlanDifference {
        let leftRows = left.actualRows ?? left.estimateRows
        let rightRows = right.actualRows ?? right.estimateRows
        let change: PlanDifference.Change

        if left.physicalOp.caseInsensitiveCompare(right.physicalOp) != .orderedSame {
            change = .operatorChanged
        } else if differs(left.estimatedTotalSubtreeCost, right.estimatedTotalSubtreeCost,
                          tolerance: costTolerance) {
            change = .costChanged
        } else if differs(leftRows, rightRows, tolerance: rowTolerance) {
            change = .rowsChanged
        } else if left.indexName != right.indexName || left.objectName != right.objectName {
            // Same operator on a different index is a plan change worth seeing, even
            // when the cost happens to match.
            change = .operatorChanged
        } else {
            change = .unchanged
        }

        return PlanDifference(
            id: path,
            change: change,
            statementIndex: statementIndex,
            depth: depth,
            leftOperator: describe(left),
            rightOperator: describe(right),
            target: right.objectName ?? left.objectName,
            leftCost: left.estimatedTotalSubtreeCost,
            rightCost: right.estimatedTotalSubtreeCost,
            leftRows: leftRows,
            rightRows: rightRows)
    }

    /// Every operator in a subtree that exists on one side only.
    private static func flatten(_ node: PlanNode, statementIndex: Int, depth: Int,
                                path: String, change: PlanDifference.Change) -> [PlanDifference] {
        let rows = node.actualRows ?? node.estimateRows
        var result = [PlanDifference(
            id: path,
            change: change,
            statementIndex: statementIndex,
            depth: depth,
            leftOperator: change == .onlyInLeft ? describe(node) : nil,
            rightOperator: change == .onlyInRight ? describe(node) : nil,
            target: node.objectName,
            leftCost: change == .onlyInLeft ? node.estimatedTotalSubtreeCost : nil,
            rightCost: change == .onlyInRight ? node.estimatedTotalSubtreeCost : nil,
            leftRows: change == .onlyInLeft ? rows : nil,
            rightRows: change == .onlyInRight ? rows : nil)]
        for (index, child) in node.children.enumerated() {
            result += flatten(child, statementIndex: statementIndex, depth: depth + 1,
                              path: "\(path).\(index)", change: change)
        }
        return result
    }

    /// "Index Seek (IX_Orders_Date)" — the operator plus what it reads, which is what
    /// makes a difference list readable without opening both trees.
    private static func describe(_ node: PlanNode) -> String {
        var text = node.physicalOp.isEmpty ? node.logicalOp : node.physicalOp
        if let index = node.indexName, !index.isEmpty {
            text += " (\(index))"
        } else if let object = node.objectName, !object.isEmpty {
            text += " (\(object))"
        }
        return text
    }

    private static func differs(_ left: Double, _ right: Double, tolerance: Double) -> Bool {
        let scale = max(abs(left), abs(right))
        guard scale > 0 else { return false }
        return abs(right - left) / scale > tolerance
    }
}
