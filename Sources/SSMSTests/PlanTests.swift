import Foundation
import TDSKit
import SQLServerKit

/// Showplan parsing and plan comparison, pinned against hand-written plan XML so the
/// rules do not need a server to check.
func runPlanTests(_ t: TestRunner) {

    /// A one-statement plan: a join whose inner side is the operator under test.
    func plan(statementCost: Double,
              outer: String,
              inner: String,
              innerCost: Double,
              innerIndex: String,
              innerEstimateRows: Double = 100,
              innerActualRows: Double? = nil) -> String {
        let actual = innerActualRows.map {
            "<RunTimeInformation><RunTimeCountersPerThread Thread=\"0\" ActualRows=\"\($0)\" "
                + "ActualExecutions=\"1\"/></RunTimeInformation>"
        } ?? ""
        return """
        <?xml version="1.0" encoding="utf-16"?>
        <ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan">
          <BatchSequence><Batch><Statements>
            <StmtSimple StatementText="SELECT * FROM Orders o JOIN Customers c ON ..."
                        StatementSubTreeCost="\(statementCost)" StatementEstRows="100">
              <QueryPlan>
                <RelOp NodeId="0" PhysicalOp="\(outer)" LogicalOp="Inner Join"
                       EstimateRows="100" EstimateIO="0" EstimateCPU="0.01"
                       EstimatedTotalSubtreeCost="\(statementCost)" AvgRowSize="40">
                  <RelOp NodeId="1" PhysicalOp="\(inner)" LogicalOp="Index Seek"
                         EstimateRows="\(innerEstimateRows)" EstimateIO="0.003"
                         EstimateCPU="0.0002"
                         EstimatedTotalSubtreeCost="\(innerCost)" AvgRowSize="30">
                    \(actual)
                    <IndexScan>
                      <Object Database="[Shop]" Schema="[dbo]" Table="[Orders]"
                              Index="[\(innerIndex)]"/>
                    </IndexScan>
                  </RelOp>
                </RelOp>
              </QueryPlan>
            </StmtSimple>
          </Statements></Batch></BatchSequence>
        </ShowPlanXML>
        """
    }

    t.suite("showplan parsing") {
        let statements = ShowplanParser.parse(
            plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                 innerCost: 0.1, innerIndex: "IX_Orders_Date", innerActualRows: 320))
        t.equal(statements.count, 1, "one statement")
        t.equal(statements.first?.root?.physicalOp, "Nested Loops", "root operator")
        t.equal(statements.first?.root?.children.count, 1, "one child")
        let child = statements.first?.root?.children.first
        t.equal(child?.physicalOp, "Index Seek", "child operator")
        t.equal(child?.indexName, "IX_Orders_Date", "index name is picked up")
        t.equal(child?.actualRows, 320, "actual rows come from the runtime counters")
        t.expect(statements.first?.root?.operatorCost ?? 0 > 0,
                 "the root keeps the cost its children do not account for")
        t.expect(ShowplanParser.parse("not xml at all").isEmpty, "garbage parses to nothing")

        // The fixture above carries the `encoding="utf-16"` declaration a .sqlplan file
        // saved by SSMS starts with, which is what this parses past; the same plan
        // without a declaration is the shape the server returns.
        let bare = plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                        innerCost: 0.1, innerIndex: "IX_Orders_Date")
            .replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"utf-16\"?>", with: "")
        t.equal(ShowplanParser.parse(bare).count, 1, "a plan without a declaration parses")
        t.expect(ShowplanParser.parse("<?xml version=\"1.0\" encoding=\"utf-16\"?>").isEmpty,
                 "a declaration with no document behind it parses to nothing")
    }

    t.suite("plan comparison") {
        let fast = plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                        innerCost: 0.1, innerIndex: "IX_Orders_Date")
        let identical = PlanComparer.compare(leftXML: fast, rightXML: fast)
        t.expect(identical.isIdentical, "a plan compared with itself reports no change",
                 identical.differences.map(\.change.rawValue).joined(separator: ", "))
        t.equal(identical.changedCount, 0, "no operator differs")
        t.equal(identical.verdict, "Both plans cost the same.", "verdict for equal plans")

        // The seek became a scan: the operator changed, and the plan costs more.
        let slow = plan(statementCost: 2.0, outer: "Nested Loops", inner: "Index Scan",
                        innerCost: 1.6, innerIndex: "IX_Orders_Date")
        let regressed = PlanComparer.compare(leftXML: fast, rightXML: slow)
        t.expect(!regressed.isIdentical, "a changed plan is not identical")
        t.expect(regressed.differences.contains { $0.change == .operatorChanged },
                 "the seek turning into a scan is reported as an operator change",
                 regressed.differences.map(\.label).joined(separator: " | "))
        t.expect(regressed.costDelta > 0, "the second plan is the expensive one")
        t.expect(regressed.verdict.contains("more expensive") || regressed.verdict.contains("×"),
                 "the verdict says which way it went", regressed.verdict)

        // Same operators, a different index: still a plan change worth seeing.
        let otherIndex = plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                              innerCost: 0.1, innerIndex: "IX_Orders_Customer")
        let swapped = PlanComparer.compare(leftXML: fast, rightXML: otherIndex)
        t.expect(swapped.differences.contains { $0.change == .operatorChanged },
                 "a different index on the same operator is a difference")

        // Same shape, the estimate moved: reported as rows, not as an operator change.
        let moreRows = plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                            innerCost: 0.1, innerIndex: "IX_Orders_Date",
                            innerEstimateRows: 5000)
        let estimateChange = PlanComparer.compare(leftXML: fast, rightXML: moreRows)
        t.expect(estimateChange.differences.contains { $0.change == .rowsChanged },
                 "a moved row estimate is reported",
                 estimateChange.differences.map(\.change.rawValue).joined(separator: ", "))
        t.expect(!estimateChange.differences.contains { $0.change == .operatorChanged },
                 "and is not called an operator change")

        // A cost shift under the tolerance is noise, not a finding.
        let nudged = plan(statementCost: 0.5, outer: "Nested Loops", inner: "Index Seek",
                          innerCost: 0.1005, innerIndex: "IX_Orders_Date")
        t.expect(PlanComparer.compare(leftXML: fast, rightXML: nudged).isIdentical,
                 "a half-percent cost difference is below the tolerance")

        // One side having an extra operator is reported per missing operator.
        let empty = PlanComparer.compare(leftXML: fast, rightXML: "<ShowPlanXML/>")
        t.expect(empty.differences.allSatisfy { $0.change == .onlyInLeft },
                 "every operator of a plan with no counterpart is reported as missing")
        t.equal(empty.differences.count, 2, "both operators of the tree are listed")
        t.equal(empty.rightStatementCount, 0, "the empty side has no statements")
    }

    t.suite("live query statistics model") {
        var op = LiveQueryOperator(nodeID: 1, physicalOperator: "Index Scan",
                                   rowCount: 50, estimatedRows: 100)
        t.equal(op.progress, 0.5, "progress is rows over estimate")
        t.expect(!op.isOverrun, "half the estimate is not an overrun")

        op.rowCount = 5_000
        t.equal(op.progress, 1, "progress is capped at one")
        t.expect(op.isOverrun, "fifty times the estimate is an overrun")

        op = LiveQueryOperator(nodeID: 2, physicalOperator: "Compute Scalar",
                               rowCount: 0, estimatedRows: 0, isClosed: true)
        t.equal(op.progress, 1, "a closed operator with no estimate reads as done")

        let snapshot = LiveQuerySnapshot(operators: [
            LiveQueryOperator(nodeID: 1, physicalOperator: "Index Seek", rowCount: 40,
                              estimatedRows: 100, logicalReads: 12, isClosed: true),
            LiveQueryOperator(nodeID: 2, physicalOperator: "Sort", rowCount: 10,
                              estimatedRows: 100, logicalReads: 8)
        ])
        t.equal(snapshot.rowsProduced, 50, "rows are summed across operators")
        t.equal(snapshot.rowsEstimated, 200, "estimates are summed too")
        t.equal(snapshot.logicalReads, 20, "reads are summed")
        t.equal(snapshot.progress, 0.25, "overall progress")
        t.equal(snapshot.finishedOperators, 1, "closed operators are counted")

        var info = ServerInfo()
        info.productVersion = "11.0.7001.0"
        t.expect(!LiveQueryStatsService.isSupported(info), "2012 has no profiles DMV")
        info.productVersion = "13.0.5026.0"
        t.expect(LiveQueryStatsService.isSupported(info), "2016 does")
        info.engineEdition = 5
        t.expect(!LiveQueryStatsService.isSupported(info), "Azure SQL Database does not")
    }
}
