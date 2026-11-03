import Foundation
import TDSKit
import SQLServerKit

/// The kit suites. `extra` runs after them and before the summary, so another file can
/// add suites without having to know about `TestRunner.finish()`.
func runSQLServerKitTests(_ t: TestRunner, extra: (TestRunner) -> Void = { _ in }) -> Int32 {

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

    t.suite("connection profiles") {
        var profile = ConnectionProfile(server: "172.31.112.70", username: "sa")
        t.equal(profile.displayName, "172.31.112.70 (sa)", "falls back to the address typed")

        profile.discoveredServerName = "OMS-01"
        t.equal(profile.displayName, "OMS-01", "the engine's own name wins over the address")
        t.equal(profile.addressDescription, "172.31.112.70 · sa",
                "the address stays on the second line")

        profile.name = "Production OMS"
        t.equal(profile.displayName, "Production OMS", "a name the user gave wins over both")

        let instance = ConnectionProfile(server: "sqlbox\\SQLEXPRESS,1444",
                                         discoveredServerName: "SQLBOX\\SQLEXPRESS",
                                         authentication: .windows,
                                         username: "dba", domain: "CONTOSO")
        t.equal(instance.addressDescription, "sqlbox\\SQLEXPRESS,1444 · CONTOSO\\dba",
                "instance, non-default port and domain account")

        // Saved connections written before the server name was recorded have to keep
        // decoding, or the whole list is lost on upgrade.
        let legacy = Data("""
        [{"id":"8E4F6A1E-0C6B-4D66-9B35-9F3B7C1E2A55","name":"","server":"localhost",
          "authentication":"sqlLogin","username":"sa","domain":"","database":"",
          "savePassword":true,"encryption":"required","trustServerCertificate":true,
          "connectTimeoutSeconds":15,"executionTimeoutSeconds":0,
          "applicationName":"SSMS for Mac","applicationIntentReadOnly":false,
          "multiSubnetFailover":false,"packetSize":4096,
          "createdAt":"2025-01-02T03:04:05Z"}]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try? decoder.decode([ConnectionProfile].self, from: legacy)
        t.expect(decoded?.count == 1, "a profile saved by an older build still decodes",
                 decoded.map { "\($0.count) profiles" } ?? "decode failed")
        t.expect(decoded?.first?.discoveredServerName == nil,
                 "the new field is absent rather than defaulted to a wrong name")
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

    t.suite("data editor batches") {
        typealias Change = TableDataEditor.RowChange
        let builder = TableDataEditor.StatementBuilder(schema: "dbo", table: "T",
                                                       keyColumns: ["Id"],
                                                       identityColumns: ["Id"])

        // The grid sends every column of a new row, the identity column as NULL.
        let newRow = Change(kind: .insert, rowIndex: 0, originalValues: [:],
                            newValues: ["Id": .null, "Name": .string("a")])
        let insert = try builder.script(for: [newRow])
        t.expect(!insert.contains("IDENTITY_INSERT"), "a NULL identity needs no IDENTITY_INSERT", insert)
        t.expect(insert.contains("INSERT INTO [dbo].[T] ([Name])\nVALUES (N'a');"),
                 "the NULL identity column is left out of the insert", insert)

        let explicitRow = Change(kind: .insert, rowIndex: 0, originalValues: [:],
                                 newValues: ["Id": .int(7), "Name": .string("b")])
        let explicit = try builder.script(for: [explicitRow])
        t.expect(explicit.contains("SET IDENTITY_INSERT [dbo].[T] ON;")
                 && explicit.contains("([Id], [Name])\nVALUES (7, N'b');")
                 && explicit.contains("SET IDENTITY_INSERT [dbo].[T] OFF;"),
                 "a typed identity value is inserted under IDENTITY_INSERT", explicit)

        // A row another session changed must end the batch, not just report an error.
        let update = Change(kind: .update, rowIndex: 0,
                            originalValues: ["Id": .int(1), "Name": .string("a")],
                            newValues: ["Id": .int(1), "Name": .string("b")])
        let updated = try builder.script(for: [update])
        t.expect(updated.hasPrefix("SET XACT_ABORT ON;\n\nBEGIN TRANSACTION;"),
                 "XACT_ABORT is on so the THROW rolls the transaction back")
        t.expect(updated.contains("WHERE [Id] = 1;\nIF @@ROWCOUNT <> 1 THROW 50000, "
                                  + "N'The update affected a different number of rows"),
                 "the row count guard throws", updated)
        t.expect(!updated.contains("RAISERROR"), "RAISERROR no longer used: it would not end the batch")
        t.expect(updated.hasSuffix("COMMIT TRANSACTION;\n"), "commit closes the batch")

        let delete = Change(kind: .delete, rowIndex: 0,
                            originalValues: ["Id": .int(1), "Name": .string("a")], newValues: [:])
        let deleted = try builder.script(for: [delete])
        t.expect(deleted.contains("DELETE FROM [dbo].[T]\nWHERE [Id] = 1;\nIF @@ROWCOUNT <> 1 THROW 50000"),
                 "delete has the same guard", deleted)

        // A comma inside a key column name is one column, not two.
        let composite = TableDataEditor.StatementBuilder(schema: "dbo", table: "Child",
                                                         keyColumns: ["Last, First", "ParentId"])
        let keyed = Change(kind: .delete, rowIndex: 0,
                           originalValues: ["Last, First": .string("Doe, John"), "ParentId": .int(2)],
                           newValues: [:])
        let keyedText = try composite.script(for: [keyed])
        t.expect(keyedText.contains("WHERE [Last, First] = N'Doe, John' AND [ParentId] = 2;"),
                 "a key column named with a comma is quoted whole", keyedText)
    }

    t.suite("object lookup quoting") {
        t.equal(ScriptGenerator.objectIDExpression(schema: "dbo", name: "Odd]Na'me"),
                "OBJECT_ID(N'[dbo].[Odd]]Na''me]')", "brackets and quotes are escaped")
        t.equal(ScriptGenerator.objectIDExpression(schema: "s", name: "a.b"),
                "OBJECT_ID(N'[s].[a.b]')", "a dot stays inside the name")
        t.equal(ScriptGenerator.objectIDExpression(schema: "s", name: "x[y"),
                "OBJECT_ID(N'[s].[x[y]')", "an opening bracket needs no escaping")
        t.expect(CatalogQueries.indexes(objectID: 1).contains("AS [FillFactor]"),
                 "FILLFACTOR is reserved, so the alias is quoted")
    }

    t.suite("index scripting") {
        var options = ScriptOptions()
        options.includeDescriptiveHeader = false
        func script(_ index: ScriptIndex) -> String {
            ScriptGenerator.createIndexStatement(index, schema: "dbo", table: "T", options: options)
        }

        let rowstore = script(ScriptIndex(
            name: "IX_Names", type: 2,
            keyColumns: [ScriptIndexColumn(name: "Last, First", isDescending: true)],
            includedColumns: ["Note"], fillFactor: 80))
        t.expect(rowstore.hasPrefix("CREATE NONCLUSTERED INDEX [IX_Names] ON [dbo].[T]\n(\n\t[Last, First] DESC\n)"),
                 "a comma in a column name stays one column", rowstore)
        t.expect(rowstore.contains("\nINCLUDE([Note])\nWITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF")
                 && rowstore.contains("FILLFACTOR = 80) ON [PRIMARY]\nGO\n"),
                 "included columns, options and filegroup", rowstore)

        let clustered = script(ScriptIndex(name: "CCI", type: 5, includedColumns: ["Id", "Amount"]))
        t.equal(clustered,
                "CREATE CLUSTERED COLUMNSTORE INDEX [CCI] ON [dbo].[T]\nWITH (DROP_EXISTING = OFF, "
                + "COMPRESSION_DELAY = 0, DATA_COMPRESSION = COLUMNSTORE) ON [PRIMARY]\nGO\n",
                "a clustered columnstore index has no column list and no rowstore options")

        let nonclustered = script(ScriptIndex(
            name: "NCCI", type: 6, includedColumns: ["Amount", "Note"],
            filterDefinition: "([Amount]>(0))", dataCompression: "COLUMNSTORE_ARCHIVE",
            compressionDelay: 10))
        t.equal(nonclustered,
                "CREATE NONCLUSTERED COLUMNSTORE INDEX [NCCI] ON [dbo].[T]\n(\n\t[Amount],\n\t[Note]\n)"
                + "\nWHERE ([Amount]>(0))\nWITH (DROP_EXISTING = OFF, COMPRESSION_DELAY = 10, "
                + "DATA_COMPRESSION = COLUMNSTORE_ARCHIVE) ON [PRIMARY]\nGO\n",
                "a nonclustered columnstore index lists its columns, filter and columnstore options")

        let primaryXML = script(ScriptIndex(name: "PX", type: 3,
                                            keyColumns: [ScriptIndexColumn(name: "Doc")],
                                            xml: .init(indexType: 0)))
        t.expect(primaryXML.hasPrefix("CREATE PRIMARY XML INDEX [PX] ON [dbo].[T]\n(\n\t[Doc]\n)\nWITH (PAD_INDEX = OFF, SORT_IN_TEMPDB"),
                 "primary XML index names its column without a sort direction", primaryXML)
        t.expect(!primaryXML.contains("ON [PRIMARY]") && !primaryXML.contains("STATISTICS_NORECOMPUTE"),
                 "an XML index takes neither a filegroup nor STATISTICS_NORECOMPUTE", primaryXML)
        let secondaryXML = script(ScriptIndex(name: "SX", type: 3,
                                              keyColumns: [ScriptIndexColumn(name: "Doc")],
                                              xml: .init(indexType: 1, secondaryType: "PATH",
                                                         primaryIndex: "PX")))
        t.expect(secondaryXML.contains("CREATE XML INDEX [SX] ON [dbo].[T]\n(\n\t[Doc]\n)\nUSING XML INDEX [PX] FOR PATH\nWITH ("),
                 "secondary XML index names its primary index and type", secondaryXML)
        let selective = script(ScriptIndex(name: "SEL", type: 3, xml: .init(indexType: 2)))
        t.expect(selective.hasPrefix("-- Selective XML index [SEL]"), "selective XML index becomes a comment", selective)

        let spatial = script(ScriptIndex(
            name: "SIX", type: 4, keyColumns: [ScriptIndexColumn(name: "Shape")],
            spatial: .init(tessellationScheme: "GEOMETRY_GRID", boundingBox: [0, 0, 100, 100],
                           gridLevels: ["MEDIUM", "LOW", "HIGH", "MEDIUM"], cellsPerObject: 12)))
        t.expect(spatial.hasPrefix("CREATE SPATIAL INDEX [SIX] ON [dbo].[T]\n(\n\t[Shape]\n)\nUSING GEOMETRY_GRID\n"
                                   + "WITH (BOUNDING_BOX = (0, 0, 100, 100), GRIDS = (LEVEL_1 = MEDIUM, LEVEL_2 = LOW, "
                                   + "LEVEL_3 = HIGH, LEVEL_4 = MEDIUM), CELLS_PER_OBJECT = 12, PAD_INDEX = OFF"),
                 "geometry grid index carries its tessellation", spatial)
        let autoGrid = script(ScriptIndex(
            name: "SIX2", type: 4, keyColumns: [ScriptIndexColumn(name: "Place")],
            spatial: .init(tessellationScheme: "GEOGRAPHY_AUTO_GRID", cellsPerObject: 8)))
        t.expect(autoGrid.contains("USING GEOGRAPHY_AUTO_GRID\nWITH (CELLS_PER_OBJECT = 8, PAD_INDEX"),
                 "auto grid has neither bounding box nor grids", autoGrid)
        t.expect(script(ScriptIndex(name: "SIX3", type: 4)).hasPrefix("-- Spatial index [SIX3]"),
                 "a spatial index without tessellation data becomes a comment")
        t.expect(script(ScriptIndex(name: "H", type: 7)).hasPrefix("-- Index [H] on [dbo].[T]"),
                 "an unknown index type becomes a comment rather than invalid SQL")

        let key = ScriptKeyConstraint(name: "PK_Child", isPrimaryKey: true, isClustered: true,
                                      columns: [ScriptIndexColumn(name: "Last, First"),
                                                ScriptIndexColumn(name: "ParentId")])
        let keyText = ScriptGenerator.keyConstraintDefinition(key)
        t.expect(keyText.contains("PRIMARY KEY CLUSTERED \n\t(\n\t\t[Last, First] ASC,\n\t\t[ParentId] ASC\n\t)"),
                 "key column list keeps the comma inside the name", keyText)
    }

    t.suite("module set options") {
        var options = ScriptOptions()
        t.equal(ScriptGenerator.setOptionsHeader(ansiNulls: true, quotedIdentifier: false, options: options),
                "SET ANSI_NULLS ON\nGO\nSET QUOTED_IDENTIFIER OFF\nGO\n",
                "the settings come from sys.sql_modules, not a constant")
        options.includeSetOptionsHeader = false
        t.equal(ScriptGenerator.setOptionsHeader(ansiNulls: true, quotedIdentifier: true, options: options),
                "", "default settings honour the option to leave the header out")
        t.expect(ScriptGenerator.setOptionsHeader(ansiNulls: false, quotedIdentifier: true, options: options)
                    .contains("SET ANSI_NULLS OFF"),
                 "an OFF setting is emitted regardless, or the module could not be re-created")
    }

    t.suite("type names") {
        t.equal(ScriptGenerator.formatType(name: "PhoneT", schema: "fix_meta", baseName: "nvarchar",
                                           maxLength: 40, precision: 0, scale: 0, isUserDefined: true),
                "[fix_meta].[PhoneT]", "alias types carry their schema")
        t.equal(ScriptGenerator.formatType(name: "geometry", schema: "sys", baseName: "geometry",
                                           maxLength: -1, precision: 0, scale: 0, isUserDefined: false),
                "geometry", "system CLR types stay bare")
        t.equal(ScriptGenerator.formatType(name: "decimal", schema: "", baseName: "decimal",
                                           maxLength: 9, precision: 12, scale: 0, isUserDefined: false),
                "decimal(12,0)", "a sequence's decimal keeps its precision")
    }

    t.suite("create user") {
        func user(_ auth: String, type: String = "SQL_USER", login: String = "",
                  certificate: String = "") -> String {
            ScriptGenerator.createUserStatement(name: "u", typeDesc: type, authenticationType: auth,
                                                login: login, defaultSchema: "dbo",
                                                certificate: certificate)
        }
        t.equal(user("INSTANCE", login: "l"),
                "CREATE USER [u] FOR LOGIN [l] WITH DEFAULT_SCHEMA = [dbo];\nGO\n", "login-mapped user")
        t.equal(user("NONE"),
                "CREATE USER [u] WITHOUT LOGIN WITH DEFAULT_SCHEMA = [dbo];\nGO\n", "user without login")
        t.equal(user("DATABASE"),
                "CREATE USER [u] WITH PASSWORD = N'<insert a password here>', DEFAULT_SCHEMA = [dbo];\nGO\n",
                "contained user")
        t.equal(user("EXTERNAL", type: "EXTERNAL_USER"),
                "CREATE USER [u] FROM EXTERNAL PROVIDER WITH DEFAULT_SCHEMA = [dbo];\nGO\n", "external user")
        t.equal(user("NONE", type: "CERTIFICATE_MAPPED_USER", certificate: "c"),
                "CREATE USER [u] FOR CERTIFICATE [c] WITH DEFAULT_SCHEMA = [dbo];\nGO\n",
                "certificate-mapped user")
    }

    t.suite("partition function scripting") {
        t.expect(ScriptGenerator.partitionFunctionBoundariesQuery(name: "pf").contains("rv.value, 126)"),
                 "boundaries are rendered with the ISO style 126")
        let dates = ScriptGenerator.partitionFunctionStatement(
            name: "pf", typeName: "datetime", baseTypeName: "datetime", rangeRight: true,
            boundaryValues: ["2024-03-04T10:00:00", "2025-01-01T00:00:00"])
        t.equal(dates,
                "CREATE PARTITION FUNCTION [pf] (datetime)\n    AS RANGE RIGHT\n"
                + "    FOR VALUES (N'2024-03-04T10:00:00', N'2025-01-01T00:00:00');\nGO\n",
                "date boundaries are quoted in the language-neutral T form")
        let numbers = ScriptGenerator.partitionFunctionStatement(
            name: "pf", typeName: "int", baseTypeName: "int", rangeRight: false,
            boundaryValues: ["10", "20"])
        t.expect(numbers.contains("AS RANGE LEFT\n    FOR VALUES (10, 20);"), "numbers stay bare", numbers)
    }

    t.suite("script batch ordering") {
        // A reads Z; F reads A; V reads F: the only valid order interleaves the kinds.
        let objects = [
            ScriptableObject(schema: "dbo", name: "V", kind: .view, isSelected: true),
            ScriptableObject(schema: "dbo", name: "F", kind: .scalarFunction, isSelected: true),
            ScriptableObject(schema: "dbo", name: "A", kind: .view, isSelected: true),
            ScriptableObject(schema: "dbo", name: "Z", kind: .tableValuedFunction, isSelected: true)
        ]
        let graph: [String: Set<String>] = ["dbo.a": ["dbo.z"], "dbo.f": ["dbo.a"], "dbo.v": ["dbo.f"]]
        t.equal(ScriptBatchGenerator.ordered(objects, dependencies: graph).map(\.name),
                ["Z", "A", "F", "V"], "views and functions are ordered together")
        t.equal(ScriptBatchGenerator.ordered(objects, dependencies: [:]).map(\.name),
                ["A", "F", "V", "Z"], "without dependencies the order is by name")
    }

    t.suite("table designer scripts") {
        let id = DesignColumn(name: "Id", typeName: "int", isNullable: false, isPrimaryKey: true,
                              isNew: false, originalName: "Id")
        let code = DesignColumn(name: "Code", typeName: "int", isNullable: false,
                                defaultDefinition: "((0))", isPrimaryKey: false,
                                isNew: false, originalName: "Code")
        // Built by hand, so neither the key nor the default constraint name is known and
        // both have to be resolved on the server.
        let original = TableDesign(schema: "dbo", name: "T", columns: [id, code])
        var edited = original
        edited.columns[0].isPrimaryKey = false
        edited.columns[1].isPrimaryKey = true
        edited.columns[1].defaultDefinition = ""
        let script = try TableDesignService.alterScript(database: "Demo", original: original, edited: edited)
        t.expect(script.hasPrefix("USE [Demo];"), "USE on an ordinary server")
        t.expect(!script.contains("EXEC(N'"), "EXEC() cannot take a function call", script)
        t.expect(script.contains("DECLARE @pk_sql nvarchar(max) = N'ALTER TABLE [dbo].[T] DROP CONSTRAINT ' + QUOTENAME(@pk_name) + N';';\n    EXEC sys.sp_executesql @pk_sql;"),
                 "the key drop is assembled in a variable and run with sp_executesql", script)
        t.expect(script.contains("DECLARE @df_sql1 nvarchar(max) = N'ALTER TABLE [dbo].[T] DROP CONSTRAINT ' + QUOTENAME(@df_name1) + N';';\n    EXEC sys.sp_executesql @df_sql1;"),
                 "the default drop too", script)

        var azure = original
        azure.isAzureSQLDatabase = true
        let azureScript = try TableDesignService.alterScript(database: "Demo", original: azure, edited: edited)
        t.expect(azureScript.hasPrefix("SET XACT_ABORT ON;"), "no USE on Azure SQL Database", azureScript)
    }

    t.suite("flat file values") {
        t.equal(FlatFileImporter.inferType(["02134", "10001"]).type, "nvarchar(50)",
                "zero-padded numbers are text")
        t.equal(FlatFileImporter.inferType(["0", "12"]).type, "int", "a plain zero is a number")
        t.equal(FlatFileImporter.inferType(["0.5", "1.25"]).type, "decimal(3,2)", "0.5 is a decimal")
        t.equal(try FlatFileImporter.literal("", sqlType: "int", nullable: true), "NULL",
                "an empty cell in a nullable column is NULL")
        t.equal(try FlatFileImporter.literal("", sqlType: "nvarchar(50)", nullable: false), "''",
                "an empty cell in a NOT NULL text column is an empty string")
        t.expect((try? FlatFileImporter.literal("", sqlType: "int", nullable: false)) == nil,
                 "an empty cell in a NOT NULL number column is an error")
        t.expect((try? FlatFileImporter.literal("", sqlType: "date", nullable: false)) == nil,
                 "an empty cell in a NOT NULL date column is an error")
        t.expect((try? FlatFileImporter.literal("abc", sqlType: "decimal(5,2)", nullable: true)) == nil,
                 "a non-numeric value is reported rather than stored as NULL")
        t.equal(try FlatFileImporter.literal("02134", sqlType: "nvarchar(50)", nullable: false),
                "N'02134'", "text keeps its leading zero")

        // 100 sampled rows of 12 bytes each ("12345,67890\n"), a 4 byte header, 10,000 bytes
        // of file: about 833 rows, not the 100 that were sampled.
        let sample = Array(repeating: ["12345", "67890"], count: 100)
        t.equal(FlatFileImporter.estimateRowCount(fileBytes: 10_000, header: ["a", "b"],
                                                  sampledRows: sample, delimiter: ",",
                                                  sampleIsComplete: false),
                833, "estimate scales the sample to the file size")
        t.equal(FlatFileImporter.estimateRowCount(fileBytes: 10_000, header: [],
                                                  sampledRows: [["a"], ["b"]], delimiter: ",",
                                                  sampleIsComplete: true),
                2, "a file read in full is counted exactly")
    }

    t.suite("completion matching") {
        func rank(_ candidate: String, _ query: String) -> Int? {
            CompletionMatcher.match(candidate: candidate, query: query)?.rank
        }

        t.expect(rank("Customers", "Customers") != nil, "exact match")
        t.expect(rank("Customers", "cust") != nil, "case-insensitive prefix")
        t.expect(rank("OrderSummary", "os") != nil, "CamelCase acronym")
        t.expect(rank("sys_databases", "sd") != nil, "underscore acronym")
        t.expect(rank("OrderSummary", "sum") != nil, "second word prefix")
        t.expect(rank("OrderSummary", "rder") != nil, "substring")
        t.expect(rank("Customers", "xyz") == nil, "no match returns nil")
        t.expect(rank("abc", "abcd") == nil, "query longer than candidate")

        // Ordering is the whole point: better kinds of match must rank lower.
        let exact = rank("id", "id") ?? .max
        let prefix = rank("identity", "id") ?? .max
        let acronym = rank("ItemDetail", "id") ?? .max
        let substring = rank("void", "id") ?? .max
        t.expect(exact < prefix, "exact beats prefix", "\(exact) vs \(prefix)")
        t.expect(prefix < acronym, "prefix beats acronym", "\(prefix) vs \(acronym)")
        t.expect(acronym < substring, "acronym beats substring", "\(acronym) vs \(substring)")

        // Shorter candidates win among equally good prefix matches.
        let shortName = rank("Order", "or") ?? .max
        let longName = rank("OrderDetailLine", "or") ?? .max
        t.expect(shortName < longName, "shorter prefix match ranks first")

        let positions = CompletionMatcher.match(candidate: "OrderSummary", query: "os")?.positions
        t.equal(positions ?? [], [0, 5], "acronym highlights the word initials")

        let boundaries = CompletionMatcher.wordBoundaries(Array("OrderSummary_2"))
        t.expect(boundaries.contains(0) && boundaries.contains(5) && boundaries.contains(13),
                 "word boundaries at camel humps and after underscores",
                 "\(boundaries)")
    }

    t.suite("alias generation") {
        t.equal(SQLAssist.suggestedAlias(for: "Customers", existing: []), "c", "single word")
        t.equal(SQLAssist.suggestedAlias(for: "OrderDetails", existing: []), "od", "camel case")
        t.equal(SQLAssist.suggestedAlias(for: "sys_databases", existing: []), "sd", "underscored")
        t.equal(SQLAssist.suggestedAlias(for: "Customers", existing: ["c"]), "c2",
                "collision gets a suffix")
        t.equal(SQLAssist.suggestedAlias(for: "Customers", existing: ["c", "c2"]), "c3",
                "second collision")
        t.equal(SQLAssist.suggestedAlias(for: "[Order Details]", existing: []), "od",
                "brackets are stripped")
    }

    t.suite("wildcard expansion") {
        let columns = [
            IntelliSenseColumn(name: "CustomerId", typeName: "int", isNullable: false,
                               isPrimaryKey: true, ordinal: 1),
            IntelliSenseColumn(name: "FullName", typeName: "nvarchar(120)", isNullable: false,
                               isPrimaryKey: false, ordinal: 2),
            IntelliSenseColumn(name: "Order Total", typeName: "money", isNullable: true,
                               isPrimaryKey: false, ordinal: 3)
        ]
        let orders = [
            IntelliSenseColumn(name: "OrderId", typeName: "int", isNullable: false,
                               isPrimaryKey: true, ordinal: 1),
            IntelliSenseColumn(name: "CustomerId", typeName: "int", isNullable: false,
                               isPrimaryKey: false, ordinal: 2)
        ]
        let catalog = IntelliSenseCatalog(
            database: "Demo", fetchedAt: Date(), schemas: ["dbo"],
            tables: [
                IntelliSenseObject(schema: "dbo", name: "Customers", kind: "table",
                                   columns: columns),
                IntelliSenseObject(schema: "dbo", name: "Orders", kind: "table",
                                   columns: orders)
            ],
            routines: [])

        let single = "SELECT * FROM dbo.Customers"
        let expandedSingle = SQLAssist.expandWildcards(script: single, offset: 8, catalog: catalog)
        t.expect(expandedSingle?.text.contains("CustomerId, FullName, [Order Total]") == true,
                 "single table expands and quotes where needed",
                 expandedSingle?.text ?? "nil")

        let joined = "SELECT * FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.CustomerId"
        let expandedJoin = SQLAssist.expandWildcards(script: joined, offset: 8, catalog: catalog)
        t.expect(expandedJoin?.text.contains("c.CustomerId") == true,
                 "multiple sources qualify by alias", expandedJoin?.text ?? "nil")
        t.expect(expandedJoin?.text.contains("o.OrderId") == true,
                 "both sources contribute columns")

        let qualified = "SELECT c.* FROM dbo.Customers c JOIN dbo.Orders o ON o.CustomerId = c.CustomerId"
        let expandedQualified = SQLAssist.expandWildcards(script: qualified, offset: 10,
                                                          catalog: catalog)
        t.expect(expandedQualified?.text.contains("o.OrderId") == false,
                 "alias.* expands only that table", expandedQualified?.text ?? "nil")

        let counted = "SELECT COUNT(*) FROM dbo.Customers"
        t.expect(SQLAssist.expandWildcards(script: counted, offset: 14, catalog: catalog) == nil,
                 "COUNT(*) is left alone")

        let arithmetic = "SELECT 2 * 3 FROM dbo.Customers"
        t.expect(SQLAssist.expandWildcards(script: arithmetic, offset: 10, catalog: catalog) == nil,
                 "multiplication is left alone")
    }

    t.suite("join conditions") {
        let relationship = IntelliSenseRelationship(
            name: "FK_Orders_Customers", parentSchema: "dbo", parentTable: "Orders",
            parentColumns: ["CustomerId"], referencedSchema: "dbo",
            referencedTable: "Customers", referencedColumns: ["CustomerId"])
        let catalog = IntelliSenseCatalog(
            database: "Demo", fetchedAt: Date(), schemas: ["dbo"],
            tables: [
                IntelliSenseObject(schema: "dbo", name: "Customers", kind: "table"),
                IntelliSenseObject(schema: "dbo", name: "Orders", kind: "table")
            ],
            routines: [], relationships: [relationship])

        let script = "SELECT * FROM dbo.Customers c JOIN dbo.Orders o ON "
        let suggestions = SQLAssist.joinConditions(script: script, offset: script.utf16.count,
                                                   joining: "Orders", alias: "o",
                                                   catalog: catalog)
        t.equal(suggestions.count, 1, "one foreign key found")
        t.equal(suggestions.first?.condition ?? "", "o.CustomerId = c.CustomerId",
                "condition uses the aliases in scope")

        t.equal(catalog.relationships(between: "Orders", and: "Customers").count, 1,
                "relationship lookup is direction agnostic")
        t.equal(catalog.relationships(between: "Customers", and: "Orders").count, 1,
                "reverse direction too")
    }

    t.suite("text results") {
        let columns = [
            TDSColumn(index: 0, name: "id", typeInfo: TDSTypeInfo(dataType: .int, length: 4)),
            TDSColumn(index: 1, name: "name",
                      typeInfo: TDSTypeInfo(dataType: .nVarChar, length: 100))
        ]
        let rows: [[TDSValue]] = [
            [.int(1), .string("Ada")],
            [.int(200), .string("برنا")],
            [.int(3), .null]
        ]
        var style = TextResultFormatter.Style()
        style.nullText = "NULL"
        let text = TextResultFormatter(style: style).format(columns: columns, rows: rows)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        t.expect(lines.count >= 5, "header, rule and three rows", "\(lines.count) lines")
        t.expect(lines[1].allSatisfy { $0 == "-" || $0 == " " },
                 "second line is the rule", lines.count > 1 ? lines[1] : "")
        t.expect(text.contains("NULL"), "null renders as the configured text")
        t.expect(!lines.contains { $0.hasSuffix(" ") }, "no trailing whitespace")

        let affected = TextResultFormatter(style: style).rowsAffected(1)
        t.expect(affected.contains("(1 row affected)"), "singular row count", affected)
    }

    extra(t)

    return t.finish()
}
