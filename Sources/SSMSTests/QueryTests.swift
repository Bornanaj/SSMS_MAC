import Foundation
import TDSKit
import SQLServerKit

/// Regressions found by the November 2026 audit of the query path: the executor's
/// preamble, the formatter, plan attribution, completion context and literals.
func runQueryTests(_ t: TestRunner) {

    t.suite("executor preamble") {
        var options = QueryExecutionOptions()
        options.setOptions = QuerySetOptions()
        options.includeEstimatedExecutionPlan = true
        options.database = "Shop"
        let batches = QueryExecutor.preambleBatches(for: options, currentDatabase: "master")
        t.equal(batches.count, 2, "SET SHOWPLAN_XML travels in a batch of its own")
        t.equal(batches.last, "SET SHOWPLAN_XML ON;", "the showplan batch holds nothing else")
        t.expect(batches.first?.hasPrefix("USE [Shop];") == true, "USE comes first")
        t.expect(batches.first?.contains("SHOWPLAN") == false, "the SET block has no showplan switch")

        options.includeActualExecutionPlan = true
        let epilogue = QueryExecutor.epilogueBatches(for: options)
        t.equal(epilogue.first, "SET SHOWPLAN_XML OFF;", "showplan is switched off first, alone")
        t.expect(epilogue.last?.contains("STATISTICS XML OFF") == true, "statistics switched off after")

        var plain = QueryExecutionOptions()
        plain.database = "Shop"
        t.expect(QueryExecutor.preambleBatches(for: plain, currentDatabase: "shop").isEmpty,
                 "no USE when the connection is already there, case-insensitively")
    }

    t.suite("formatter keeps identifiers") {
        let formatter = SQLFormatter(style: SQLFormatter.Style())
        let formatted = formatter.format(
            "select c.CustomerId, o.Date, t.Key, x.Count, Year from dbo.Customers c where c.IsActive = 1")
        t.expect(formatted.contains("o.Date"), "member names keep their case after a dot", formatted)
        t.expect(formatted.contains("t.Key"), "a column called Key is not a keyword", formatted)
        t.expect(formatted.contains("x.Count"), "a column called Count is not a function", formatted)
        t.expect(formatted.contains(" Year\n") || formatted.contains(" Year "),
                 "a bare column called Year is not a function either", formatted)
        t.expect(formatted.contains("SELECT") && formatted.contains("FROM") && formatted.contains("WHERE"),
                 "real keywords are still upper-cased", formatted)

        let cast = formatter.format("select cast(x as int), convert(date, y), getdate() from t")
        t.expect(cast.contains("AS INT"), "a type after AS is a type", cast)
        t.expect(cast.contains("CONVERT (DATE") || cast.contains("CONVERT(DATE"),
                 "a type after an opening parenthesis is a type", cast)
        t.expect(cast.contains("GETDATE()"), "a called function is a function", cast)

        let repeated = formatter.format("insert into t values (1)\ngo 5\nselect 1")
        t.expect(repeated.contains("GO 5\n"), "the GO count stays on the GO line", repeated)
        let batches = BatchSplitter.split(repeated)
        t.equal(batches.count, 2, "the formatted script still splits into two batches")
        t.equal(batches.first?.repeatCount, 5, "and the first still repeats five times")
    }

    t.suite("showplan attribution") {
        let xml = """
        <?xml version="1.0" encoding="utf-16"?>
        <ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan">
          <BatchSequence><Batch><Statements>
            <StmtSimple StatementText="SELECT 1" StatementSubTreeCost="0.5" StatementEstRows="4">
              <QueryPlan>
                <RelOp NodeId="0" PhysicalOp="Nested Loops" LogicalOp="Inner Join"
                       EstimateRows="4" EstimateIO="0" EstimateCPU="0.01"
                       EstimatedTotalSubtreeCost="0.5" AvgRowSize="40">
                  <RunTimeInformation>
                    <RunTimeCountersPerThread Thread="0" ActualRows="4" ActualExecutions="1"/>
                  </RunTimeInformation>
                  <NestedLoops Optimized="false">
                    <RelOp NodeId="1" PhysicalOp="Index Seek" LogicalOp="Index Seek"
                           EstimateRows="8" EstimateIO="0.003" EstimateCPU="0.0002"
                           EstimatedTotalSubtreeCost="0.1" AvgRowSize="30">
                      <RunTimeInformation>
                        <RunTimeCountersPerThread Thread="0" ActualRows="8" ActualExecutions="1"/>
                      </RunTimeInformation>
                      <Warnings NoJoinPredicate="true"><NoJoinPredicate/></Warnings>
                      <IndexScan>
                        <Object Database="[Shop]" Schema="[dbo]" Table="[Customers]" Index="[PK_Customers]"/>
                        <Predicate><ScalarOperator ScalarString="[Id]&gt;(1)"/></Predicate>
                      </IndexScan>
                    </RelOp>
                  </NestedLoops>
                </RelOp>
              </QueryPlan>
            </StmtSimple>
          </Statements></Batch></BatchSequence>
        </ShowPlanXML>
        """
        let root = ShowplanParser.parse(xml).first?.root
        t.equal(root?.actualRows, 4, "a parent keeps its own actual rows")
        t.expect(root?.objectName == nil || root?.objectName?.isEmpty == true,
                 "a parent does not inherit its child's object")
        t.expect(root?.indexName == nil, "a parent does not inherit its child's index")
        t.expect(root?.predicate == nil, "a parent does not inherit its child's predicate")
        t.expect(root?.warnings.isEmpty == true, "a parent does not inherit its child's warnings")
        let child = root?.children.first
        t.equal(child?.actualRows, 8, "the child keeps its rows")
        t.equal(child?.indexName, "[PK_Customers]", "the child keeps its index")
        t.equal(child?.warnings, ["NoJoinPredicate"], "the child keeps its warning")
    }

    t.suite("completion context") {
        let lexer = TSQLLexer()
        func inside(_ script: String, _ offset: Int) -> Bool {
            IntelliSenseProvider.caretIsInsideLiteralOrComment(tokens: lexer.tokenize(script),
                                                               offset: offset)
        }
        t.expect(inside("WHERE Name = 'Ad", 16), "inside an unterminated string")
        t.expect(inside("WHERE Name = 'Ad' ", 15), "inside a closed string")
        t.expect(!inside("WHERE Name = 'Ad' ", 17), "right after the closing quote is outside")
        t.expect(inside("SELECT 1 -- sel", 15), "at the end of a line comment")
        t.expect(inside("/* sel */ SELECT", 5), "inside a block comment")
        t.expect(!inside("/* x */ SEL", 11), "after a block comment is code")
        t.expect(!inside("SELECT Nam", 10), "plain code is not suppressed")
    }

    t.suite("temporal literals") {
        func temporal(_ kind: TDSTemporal.Kind) -> TDSTemporal {
            var value = TDSTemporal(kind: kind)
            value.year = 2024; value.month = 3; value.day = 4
            value.hour = 10; value.minute = 0; value.second = 0
            value.scale = kind == .dateTime ? 3 : 0
            return value
        }
        t.equal(temporal(.dateTime).sqlLiteral, "'2024-03-04T10:00:00.000'",
                "datetime literals take the language-neutral T form")
        t.equal(temporal(.smallDateTime).sqlLiteral, "'2024-03-04T10:00:00'",
                "so do smalldatetime literals")
        t.equal(temporal(.dateTime2).sqlLiteral, "'2024-03-04 10:00:00'",
                "datetime2 is neutral already and keeps the space")
        t.equal(temporal(.date).sqlLiteral, "'2024-03-04'", "date is unchanged")
    }

    t.suite("code pages by full locale") {
        t.equal(TDSCollation.codePage(forLCID: 0x0804), 936, "Chinese_PRC is simplified (936)")
        t.equal(TDSCollation.codePage(forLCID: 0x0404), 950, "Chinese_Taiwan stays 950")
        t.equal(TDSCollation.codePage(forLCID: 0x0C1A), 1251, "Serbian Cyrillic is 1251")
        t.equal(TDSCollation.codePage(forLCID: 0x041A), 1250, "Croatian stays 1250")
        t.equal(TDSCollation(raw: 0x0400_0409, sortId: 0).codePage, 65001,
                "the UTF-8 flag wins over the locale")
        t.equal(TDSCollation(raw: 0x0000_0409, sortId: 0).codePage, 1252,
                "without the flag English is 1252")
    }
}
