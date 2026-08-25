import Foundation

/// One physical operator in an execution plan.
struct PlanNode: Identifiable, Hashable {
    let id = UUID()
    var nodeID: Int = 0
    var physicalOp: String = ""
    var logicalOp: String = ""
    var estimateRows: Double = 0
    var actualRows: Double?
    var actualExecutions: Double?
    var estimateIO: Double = 0
    var estimateCPU: Double = 0
    var estimatedTotalSubtreeCost: Double = 0
    var averageRowSize: Double = 0
    var isParallel = false
    var objectName: String?
    var indexName: String?
    var predicate: String?
    var seekPredicate: String?
    var outputList: [String] = []
    var warnings: [String] = []
    var children: [PlanNode] = []

    /// Cost of this operator alone, i.e. subtree cost minus the children's subtrees.
    var operatorCost: Double {
        max(0, estimatedTotalSubtreeCost - children.reduce(0) { $0 + $1.estimatedTotalSubtreeCost })
    }

    var symbol: String {
        let op = physicalOp.lowercased()
        if op.contains("clustered index scan") || op.contains("table scan") { return "doc.text.magnifyingglass" }
        if op.contains("index seek") { return "scope" }
        if op.contains("index scan") { return "doc.text.magnifyingglass" }
        if op.contains("key lookup") || op.contains("rid lookup") { return "arrow.turn.down.right" }
        if op.contains("nested loops") { return "arrow.triangle.merge" }
        if op.contains("hash match") { return "number.square" }
        if op.contains("merge join") { return "arrow.triangle.merge" }
        if op.contains("sort") { return "arrow.up.arrow.down" }
        if op.contains("filter") { return "line.3.horizontal.decrease" }
        if op.contains("compute scalar") { return "function" }
        if op.contains("stream aggregate") || op.contains("aggregate") { return "sum" }
        if op.contains("parallelism") { return "arrow.triangle.branch" }
        if op.contains("insert") || op.contains("update") || op.contains("delete") { return "square.and.pencil" }
        if op.contains("spool") { return "cylinder.split.1x2" }
        return "square.grid.2x2"
    }
}

struct PlanStatement: Identifiable, Hashable {
    let id = UUID()
    var statementText: String = ""
    var subtreeCost: Double = 0
    var estimatedRows: Double = 0
    var root: PlanNode?
    var missingIndexImpact: Double?
    var missingIndexDefinition: String?
}

/// Parses SHOWPLAN_XML / STATISTICS XML output into an operator tree.
enum ShowplanParser {

    static func parse(_ xml: String) -> [PlanStatement] {
        guard let document = try? XMLDocument(xmlString: xml, options: [.nodePreserveWhitespace]) else {
            return []
        }
        guard let root = document.rootElement() else { return [] }

        var statements: [PlanStatement] = []
        for element in descendants(of: root, named: ["StmtSimple", "StmtCond", "StmtCursor", "StmtUseDb"]) {
            var statement = PlanStatement()
            statement.statementText = element.attribute(forName: "StatementText")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            statement.subtreeCost = double(element, "StatementSubTreeCost")
            statement.estimatedRows = double(element, "StatementEstRows")

            if let queryPlan = firstChild(of: element, named: "QueryPlan") {
                if let relOp = firstChild(of: queryPlan, named: "RelOp") {
                    statement.root = parseRelOp(relOp)
                }
                if let missing = descendants(of: queryPlan, named: ["MissingIndexGroup"]).first {
                    statement.missingIndexImpact = double(missing, "Impact")
                    statement.missingIndexDefinition = missingIndexScript(missing)
                }
            }
            statements.append(statement)
        }
        return statements
    }

    private static func parseRelOp(_ element: XMLElement) -> PlanNode {
        var node = PlanNode()
        node.nodeID = Int(double(element, "NodeId"))
        node.physicalOp = element.attribute(forName: "PhysicalOp")?.stringValue ?? ""
        node.logicalOp = element.attribute(forName: "LogicalOp")?.stringValue ?? ""
        node.estimateRows = double(element, "EstimateRows")
        node.estimateIO = double(element, "EstimateIO")
        node.estimateCPU = double(element, "EstimateCPU")
        node.estimatedTotalSubtreeCost = double(element, "EstimatedTotalSubtreeCost")
        node.averageRowSize = double(element, "AvgRowSize")
        node.isParallel = (element.attribute(forName: "Parallel")?.stringValue ?? "0") == "1"

        for output in descendants(of: element, named: ["OutputList"]).prefix(1) {
            node.outputList = descendants(of: output, named: ["ColumnReference"]).compactMap { column in
                let table = column.attribute(forName: "Table")?.stringValue
                let name = column.attribute(forName: "Column")?.stringValue ?? ""
                return table.map { "\($0).\(name)" } ?? name
            }
        }

        if let object = descendants(of: element, named: ["Object"]).first {
            let parts = ["Database", "Schema", "Table"].compactMap {
                object.attribute(forName: $0)?.stringValue
            }
            node.objectName = parts.joined(separator: ".")
            node.indexName = object.attribute(forName: "Index")?.stringValue
        }

        if let predicate = descendants(of: element, named: ["Predicate"]).first {
            node.predicate = scalarText(predicate)
        }
        if let seek = descendants(of: element, named: ["SeekPredicates"]).first {
            node.seekPredicate = scalarText(seek)
        }

        if let runtime = descendants(of: element, named: ["RunTimeCountersPerThread"]).first {
            var rows: Double = 0
            var executions: Double = 0
            for counter in descendants(of: element, named: ["RunTimeCountersPerThread"]) {
                rows += double(counter, "ActualRows")
                executions = max(executions, double(counter, "ActualExecutions"))
            }
            _ = runtime
            node.actualRows = rows
            node.actualExecutions = executions
        }

        for warning in descendants(of: element, named: ["Warnings"]).first.map({ $0.children ?? [] }) ?? [] {
            if let name = warning.name { node.warnings.append(name) }
        }

        node.children = childRelOps(of: element).map(parseRelOp)
        return node
    }

    /// RelOps nested one physical-operator element deep, and no further.
    private static func childRelOps(of element: XMLElement) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ node: XMLElement, isRoot: Bool) {
            for child in node.children ?? [] {
                guard let childElement = child as? XMLElement else { continue }
                if childElement.name == "RelOp" {
                    if !isRoot { result.append(childElement) }
                    continue
                }
                walk(childElement, isRoot: false)
            }
        }
        walk(element, isRoot: true)
        return result
    }

    private static func firstChild(of element: XMLElement, named name: String) -> XMLElement? {
        (element.children ?? []).compactMap { $0 as? XMLElement }.first { $0.name == name }
    }

    private static func descendants(of element: XMLElement, named names: [String]) -> [XMLElement] {
        var result: [XMLElement] = []
        func walk(_ node: XMLElement) {
            for child in node.children ?? [] {
                guard let childElement = child as? XMLElement else { continue }
                if let name = childElement.name, names.contains(name) {
                    result.append(childElement)
                } else {
                    walk(childElement)
                }
            }
        }
        walk(element)
        return result
    }

    private static func double(_ element: XMLElement, _ attribute: String) -> Double {
        Double(element.attribute(forName: attribute)?.stringValue ?? "") ?? 0
    }

    private static func scalarText(_ element: XMLElement) -> String {
        let text = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
        return descendants(of: element, named: ["ScalarOperator"])
            .compactMap { $0.attribute(forName: "ScalarString")?.stringValue }
            .joined(separator: " AND ")
    }

    private static func missingIndexScript(_ group: XMLElement) -> String? {
        guard let index = descendants(of: group, named: ["MissingIndex"]).first else { return nil }
        let database = index.attribute(forName: "Database")?.stringValue ?? ""
        let schema = index.attribute(forName: "Schema")?.stringValue ?? ""
        let table = index.attribute(forName: "Table")?.stringValue ?? ""

        func columns(usage: String) -> [String] {
            descendants(of: index, named: ["ColumnGroup"])
                .filter { $0.attribute(forName: "Usage")?.stringValue == usage }
                .flatMap { descendants(of: $0, named: ["Column"]) }
                .compactMap { $0.attribute(forName: "Name")?.stringValue }
        }

        let equality = columns(usage: "EQUALITY")
        let inequality = columns(usage: "INEQUALITY")
        let included = columns(usage: "INCLUDE")
        let keys = (equality + inequality).joined(separator: ", ")
        guard !keys.isEmpty else { return nil }

        var script = "CREATE NONCLUSTERED INDEX [IX_Suggested]\nON \(database).\(schema).\(table) (\(keys))"
        if !included.isEmpty { script += "\nINCLUDE (\(included.joined(separator: ", ")))" }
        return script + ";"
    }
}
