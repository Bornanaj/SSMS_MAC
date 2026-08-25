import Foundation
import TDSKit
import SQLServerKit

func runSQLServerKitTests(_ t: TestRunner) -> Int32 {

    t.suite("lexer") {
        let lexer = TSQLLexer()
        let tokens = lexer.significantTokens(
            "SELECT [My Col], N'it''s', 0x1F, 3.14e-2, @var, @@ROWCOUNT, #tmp FROM dbo.T -- tail")
        let kinds = tokens.map(\.kind)
        t.expect(kinds.contains(.keyword), "keywords are recognised")
        t.expect(kinds.contains(.quotedIdentifier), "bracketed identifiers")
        t.expect(kinds.contains(.string), "N-prefixed strings")
        t.expect(kinds.contains(.number), "numbers")
        t.expect(kinds.contains(.variable), "variables")
        t.expect(kinds.contains(.tempTable), "temp tables")
        t.expect(!kinds.contains(.lineComment), "significantTokens drops comments")

        let stringToken = tokens.first { $0.kind == .string }
        t.equal(stringToken?.text, "N'it''s'", "escaped quote stays inside the literal")

        let nested = lexer.tokenize("/* outer /* inner */ still outer */ SELECT 1")
        let comment = nested.first { $0.kind == .blockComment }
        t.expect(comment?.text.hasSuffix("still outer */") == true, "nested block comments")
    }

    t.suite("batch splitter") {
        var batches = BatchSplitter.split("SELECT 1\nGO\nSELECT 2\nGO\nSELECT 3")
        t.equal(batches.count, 3, "three batches")
        t.equal(batches[1].text.trimmingCharacters(in: .whitespacesAndNewlines), "SELECT 2",
                "middle batch text")
        // The batch keeps the newline that followed GO, so the server counts that as its
        // first line. What matters is that mapping a server line back lands on the right
        // document line: SELECT 2 is line 2 of the batch and line 3 of the script.
        let mapped = batches[1].startLine + 2 - 1
        t.equal(mapped, 3, "server line numbers map back to the script")

        batches = BatchSplitter.split("SELECT 'GO'\nSELECT 1")
        t.equal(batches.count, 1, "GO inside a string is not a separator")

        batches = BatchSplitter.split("SELECT 1 -- GO\nSELECT 2")
        t.equal(batches.count, 1, "GO inside a comment is not a separator")

        batches = BatchSplitter.split("INSERT INTO t VALUES (1)\nGO 5")
        t.equal(batches.count, 1, "GO with a count")
        t.equal(batches[0].repeatCount, 5, "repeat count parsed")

        batches = BatchSplitter.split("SELECT 1\n  go  \nSELECT 2")
        t.equal(batches.count, 2, "GO is case and whitespace insensitive")

        batches = BatchSplitter.split("SELECT 1, GO_TOTAL FROM t")
        t.equal(batches.count, 1, "an identifier starting with GO is not a separator")
    }

    t.suite("identifier quoting") {
        t.equal(SQLIdentifier.quote("Order"), "[Order]", "simple quoting")
        t.equal(SQLIdentifier.quote("we]rd"), "[we]]rd]", "closing bracket is doubled")
        t.equal(SQLIdentifier.quote(schema: "dbo", name: "T"), "[dbo].[T]", "two part name")
        t.equal(SQLIdentifier.quote(database: "db", schema: "s", name: "t"), "[db].[s].[t]",
                "three part name")
        t.equal(SQLIdentifier.literal("it's"), "N'it''s'", "literal escaping")
        t.expect(SQLIdentifier.isRegular("Customers"), "plain name needs no quoting")
        t.expect(!SQLIdentifier.isRegular("Order"), "reserved word needs quoting")
        t.expect(!SQLIdentifier.isRegular("My Col"), "name with a space needs quoting")
        t.expect(!SQLIdentifier.isRegular("2Fast"), "leading digit needs quoting")
    }

    t.suite("formatter") {
        let formatter = SQLFormatter(style: SQLFormatter.Style())
        let output = formatter.format(
            "select a,b from t where a=1 and b=2 order by a")
        t.expect(output.contains("SELECT"), "keywords are upper cased")
        t.expect(output.contains("\nFROM t"), "FROM starts a line")
        t.expect(output.contains("\nWHERE"), "WHERE starts a line")
        t.expect(output.contains("\n    AND"), "AND is indented one level")

        let preserved = formatter.format("SELECT 'select 1 from x' AS s -- select\n")
        t.expect(preserved.contains("'select 1 from x'"), "string literals are untouched")
        t.expect(preserved.contains("-- select"), "comments are preserved")
    }

    t.suite("csv parsing") {
        // Swift treats CRLF as one Character, which used to break row splitting.
        let crlf = "a,b,c\r\n1,2,3\r\n4,5,6"
        let rows = CSVParser.parse(crlf, delimiter: ",", limit: 0)
        t.equal(rows.count, 3, "CRLF files split into rows")
        t.equal(rows[0].count, 3, "three columns")
        t.equal(rows[2][2], "6", "last field")

        let quoted = "name,note\n\"Doe, John\",\"line1\nline2\"\n\"say \"\"hi\"\"\",x"
        let parsed = CSVParser.parse(quoted, delimiter: ",", limit: 0)
        t.equal(parsed.count, 3, "embedded newline stays in its field")
        t.equal(parsed[1][0], "Doe, John", "delimiter inside quotes")
        t.equal(parsed[1][1], "line1\nline2", "newline inside quotes")
        t.equal(parsed[2][0], "say \"hi\"", "doubled quotes unescape")

        t.equal(FlatFileImporter.sniffDelimiter(in: "a;b;c\n1;2;3\n"), ";", "semicolon detected")
        t.equal(FlatFileImporter.sniffDelimiter(in: "a\tb\tc\n1\t2\t3\n"), "\t", "tab detected")
        t.equal(FlatFileImporter.sniffDelimiter(in: "a,b\n1,2\n"), ",", "comma detected")
    }

    t.suite("type inference") {
        t.equal(FlatFileImporter.inferType(["1", "2", "3"]).type, "int", "integers")
        t.equal(FlatFileImporter.inferType(["1", "", "3"]).nullable, true, "blank means nullable")
        t.equal(FlatFileImporter.inferType(["0", "1", "true"]).type, "bit", "booleans")
        t.equal(FlatFileImporter.inferType(["1.25", "3.5"]).type, "decimal(3,2)", "decimals")
        t.equal(FlatFileImporter.inferType(["2024-02-29", "2026-01-01"]).type, "date", "dates")
        t.equal(FlatFileImporter.inferType([UUID().uuidString]).type, "uniqueidentifier", "guids")
        t.equal(FlatFileImporter.inferType(["short", "text"]).type, "nvarchar(50)", "short text")
        t.equal(FlatFileImporter.inferType([String(repeating: "x", count: 300)]).type,
                "nvarchar(4000)", "long text")
        t.equal(FlatFileImporter.sanitiseColumnName("Order Total (USD)"), "Order_Total__USD_",
                "column names are sanitised")
        t.equal(FlatFileImporter.sanitiseColumnName("2024"), "_2024", "leading digit is prefixed")
    }

    t.suite("csv export quoting") {
        let exporter = ResultExporter()
        var options = ExportOptions()
        options.includeHeaders = true
        options.lineEnding = "\n"
        options.writeByteOrderMark = false

        let columns = [
            TDSColumn(index: 0, name: "name", typeInfo: TDSTypeInfo(dataType: .nVarChar, length: 100)),
            TDSColumn(index: 1, name: "amount", typeInfo: TDSTypeInfo(dataType: .int, length: 4))
        ]
        let rows: [[TDSValue]] = [
            [.string("Doe, John"), .int(5)],
            [.string("say \"hi\""), .null],
            [.string("line1\nline2"), .int(-3)]
        ]
        let text = (try? exporter.string(columns: columns, rows: rows,
                                         format: .csv, options: options)) ?? ""
        t.expect(text.contains("\"Doe, John\""), "comma forces quoting")
        t.expect(text.contains("\"say \"\"hi\"\"\""), "quotes are doubled")
        t.expect(text.contains("\"line1\nline2\""), "newline forces quoting")

        // The parser must be able to read back exactly what the exporter wrote.
        let reparsed = CSVParser.parse(text, delimiter: ",", limit: 0)
        t.equal(reparsed.count, 4, "round trip row count")
        t.equal(reparsed[1][0], "Doe, John", "round trip field with comma")
        t.equal(reparsed[3][0], "line1\nline2", "round trip field with newline")
    }

    t.suite("script rewriting") {
        let created = "CREATE PROCEDURE dbo.p AS SELECT 1"
        t.equal(ScriptGenerator.rewriteLeadingCreate(created, to: "ALTER"),
                "ALTER PROCEDURE dbo.p AS SELECT 1", "CREATE becomes ALTER")

        let orAlter = "CREATE OR ALTER VIEW dbo.v AS SELECT 1"
        t.equal(ScriptGenerator.rewriteLeadingCreate(orAlter, to: "ALTER"),
                "ALTER VIEW dbo.v AS SELECT 1", "CREATE OR ALTER collapses")

        let commented = "-- header\n/* note */\nCREATE FUNCTION dbo.f() RETURNS int AS BEGIN RETURN 1 END"
        let rewritten = ScriptGenerator.rewriteLeadingCreate(commented, to: "ALTER")
        t.expect(rewritten.hasPrefix("-- header"), "leading comments survive")
        t.expect(rewritten.contains("ALTER FUNCTION"), "CREATE after comments is rewritten")

        t.equal(ScriptGenerator.formatType(name: "nvarchar", baseName: "nvarchar", maxLength: 100,
                                           precision: 0, scale: 0, isUserDefined: false),
                "nvarchar(50)", "nvarchar length is halved into characters")
        t.equal(ScriptGenerator.formatType(name: "varchar", baseName: "varchar", maxLength: -1,
                                           precision: 0, scale: 0, isUserDefined: false),
                "varchar(max)", "max length")
        t.equal(ScriptGenerator.formatType(name: "decimal", baseName: "decimal", maxLength: 9,
                                           precision: 18, scale: 2, isUserDefined: false),
                "decimal(18,2)", "decimal precision and scale")
        t.equal(ScriptGenerator.formatType(name: "datetime2", baseName: "datetime2", maxLength: 8,
                                           precision: 0, scale: 7, isUserDefined: false),
                "datetime2(7)", "datetime2 scale")
    }

    t.suite("server info") {
        var info = ServerInfo()
        info.productVersion = "16.0.4265.3"
        info.productLevel = "RTM"
        info.productUpdateLevel = "CU26"
        info.engineEdition = 3
        t.equal(info.majorVersion, 16, "major version parsed")
        t.equal(info.friendlyVersion, "SQL Server 2022 (RTM-CU26)", "friendly version")
        t.expect(!info.isAzure, "on-premises edition")

        info.engineEdition = 5
        t.expect(info.isAzureSQLDatabase, "engine edition 5 is Azure SQL Database")
        t.equal(info.friendlyVersion, "Azure SQL Database", "azure friendly version")

        info.productVersion = "10.50.1600"
        info.engineEdition = 3
        t.equal(info.friendlyVersion.hasPrefix("SQL Server 2008 R2") ? "2008R2" : info.friendlyVersion,
                "2008R2", "10.50 is 2008 R2")
    }

    t.suite("data editor scripting") {
        // The editor is exercised end to end by the CLI; here we pin the value coercion
        // rules that the grid depends on.
        t.equal(TDSValue.string("it's").sqlLiteral, "N'it''s'", "string literal escaping")
        t.equal(TDSValue.null.sqlLiteral, "NULL", "null literal")
        t.equal(TDSValue.binary([0x01, 0xAB]).sqlLiteral, "0x01AB", "binary literal")
        t.equal(TDSValue.bool(true).sqlLiteral, "1", "bit literal")
        t.equal(TDSValue.int(-42).sqlLiteral, "-42", "int literal")
    }

    return t.finish()
}
