import Foundation
import TDSKit
import SQLServerKit

/// Offline suites for Schema Compare and Data Compare: everything that can be checked
/// without a server — text diffs, module normalization, the script parser, comparison,
/// deployment ordering, value equality and synchronization scripts.
func runCompareTests(_ t: TestRunner) {

    // MARK: - Fixtures

    func snapshot(_ script: String, origin: String) -> SchemaSnapshot {
        var parser = SchemaScriptParser(defaultCollation: "SQL_Latin1_General_CP1_CI_AS")
        parser.parse(script: script, file: "\(origin).sql")
        return parser.snapshot(origin: origin, databaseName: origin)
    }

    func difference(_ comparison: SchemaComparison, _ name: String) -> SchemaDifference? {
        comparison.differences.first { $0.displayName.caseInsensitiveCompare(name) == .orderedSame }
    }

    func snapshotObject(_ snapshot: SchemaSnapshot, _ name: String) -> SchemaObject? {
        snapshot.objects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    let sourceScript = """
    CREATE SCHEMA [Sales] AUTHORIZATION [dbo]
    GO
    CREATE TABLE [dbo].[Customer] (
        [Id] int IDENTITY(1,1) NOT NULL,
        [Name] nvarchar(100) NOT NULL,
        [Email] nvarchar(200) NULL,
        CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([Id])
    )
    GO
    CREATE TABLE [Sales].[Orders] (
        [Id] int NOT NULL,
        [CustomerId] int NOT NULL,
        [Total] decimal(10,2) NOT NULL CONSTRAINT [DF_Orders_Total] DEFAULT ((0)),
        CONSTRAINT [PK_Orders] PRIMARY KEY CLUSTERED ([Id]),
        CONSTRAINT [CK_Orders_Total] CHECK ([Total] >= (0))
    )
    GO
    ALTER TABLE [Sales].[Orders] ADD CONSTRAINT [FK_Orders_Customer]
        FOREIGN KEY ([CustomerId]) REFERENCES [dbo].[Customer] ([Id])
    GO
    CREATE NONCLUSTERED INDEX [IX_Orders_Customer] ON [Sales].[Orders] ([CustomerId]) INCLUDE ([Total])
    GO
    CREATE VIEW [dbo].[vCustomerOrders]
    AS
    SELECT c.Id, c.Name, COUNT(o.Id) AS Orders
    FROM dbo.Customer AS c LEFT JOIN Sales.Orders AS o ON o.CustomerId = c.Id
    GROUP BY c.Id, c.Name
    GO
    CREATE PROCEDURE [dbo].[GetCustomer] @Id int
    AS
    BEGIN
        SELECT Id, Name FROM dbo.Customer WHERE Id = @Id
    END
    GO
    """

    let targetScript = """
    CREATE TABLE [dbo].[Customer] (
        [Id] int IDENTITY(1,1) NOT NULL,
        [Name] nvarchar(50) NOT NULL,
        CONSTRAINT [PK_Customer] PRIMARY KEY CLUSTERED ([Id])
    )
    GO
    CREATE TABLE [dbo].[Legacy] (
        [Id] int NOT NULL PRIMARY KEY
    )
    GO
    CREATE VIEW [dbo].[vCustomerOrders]
    AS
    SELECT c.Id, c.Name, 0 AS Orders FROM dbo.Customer AS c
    GO
    create proc dbo.GetCustomer @Id int
    as
    begin
      select Id, Name
      from dbo.Customer
      where Id = @Id
    end
    GO
    """

    // MARK: - Text diff

    t.suite("text diff") {
        let rows = TextDiff.sideBySide(left: "a\nb\nc\nd", right: "a\nB\nc\nd\ne")
        t.equal(rows.count, 5, "rows are aligned")
        t.equal(rows[0].kind, .same, "unchanged line")
        t.equal(rows[1].kind, .changed, "edited line pairs up")
        t.equal(rows[4].kind, .added, "line only on the right")
        t.equal(TextDiff.differenceStarts(rows), [1, 4], "difference navigation stops")
        let similar = TextDiff.sideBySide(left: "SELECT  1", right: "SELECT 1",
                                          options: TextDiff.Options(ignoreWhitespace: true))
        t.equal(similar.first?.kind, .similar, "whitespace-only change is similar")
        let changed = TextDiff.sideBySide(left: "SELECT Name FROM T", right: "SELECT Email FROM T")
        t.expect(!(changed.first?.leftHighlights.isEmpty ?? true), "changed word is highlighted")
        let operations = TextDiff.operations(Array("kitten"), Array("sitting"), equal: ==)
        let kept = operations.filter { if case .equal = $0 { return true }; return false }.count
        t.equal(kept, 4, "longest common subsequence of kitten/sitting")
    }

    // MARK: - Module text

    t.suite("module text") {
        let header = ModuleText.header(of: "-- note\nCREATE OR ALTER PROC [dbo].[DoIt] AS SELECT 1")
        t.equal(header?.nameParts ?? [], ["dbo", "DoIt"], "header name parts")
        t.equal(header?.kind, "PROCEDURE", "PROC is read as PROCEDURE")
        let normalization = ModuleText.Normalization()
        let a = ModuleText.comparable("CREATE PROCEDURE [dbo].[p] AS\n  SELECT  1", normalization: normalization,
                                      canonicalName: "[dbo].[p]")
        let b = ModuleText.comparable("create proc dbo.p as select 1", normalization: normalization,
                                      canonicalName: "[dbo].[p]")
        t.equal(a, b, "case, whitespace, brackets and PROC/PROCEDURE are ignored")
        let strict = ModuleText.Normalization(ignoreWhitespace: false, caseSensitive: true)
        t.expect(ModuleText.comparable("SELECT 1", normalization: strict)
                 != ModuleText.comparable("select 1", normalization: strict), "case sensitive when asked")
        t.equal(ModuleText.expression("((0))"), ModuleText.expression("0"), "stored defaults lose parentheses")
        t.equal(ModuleText.expression("([Price]>=(0))"), ModuleText.expression("Price >= 0"),
                "check expressions compare canonically")
        t.expect(ModuleText.expression("N'A'") != ModuleText.expression("N'a'"), "string literals keep case")
        let names = ModuleText.referencedNames(in: "SELECT * FROM Customer c JOIN Sales.Orders o ON 1=1")
        t.expect(names.contains("dbo.customer") && names.contains("sales.orders"), "references resolve schemas",
                 "\(names.sorted())")
    }

    // MARK: - Parser

    let source = snapshot(sourceScript, origin: "Source")
    let target = snapshot(targetScript, origin: "Target")

    t.suite("script parser") {
        let types: [SchemaObjectType] = source.objects.map(\.key.type)
        t.equal(types.filter { $0 == .table }.count, 2, "two tables")
        t.expect(types.contains(.schema) && types.contains(.view) && types.contains(.storedProcedure),
                 "schema, view and procedure")
        let orders = source.objects.first { $0.key.name == "Orders" }
        t.equal(orders?.key.schema, "Sales", "schema of Orders")
        t.equal(orders?.table?.columns.count, 3, "Orders columns")
        t.equal(orders?.table?.foreignKeys.count, 1, "ALTER TABLE foreign key is attached")
        t.equal(orders?.indexes.count, 1, "separate CREATE INDEX is attached")
        t.equal(orders?.table?.checkConstraints.count, 1, "check constraint")
        t.expect(orders?.table?.columns.first { $0.name == "Total" }?.defaultConstraint != nil, "inline default")
        let customer = source.objects.first { $0.key.name == "Customer" }
        t.expect(customer?.table?.columns.first?.identity != nil, "identity column")
        t.expect(source.warnings.isEmpty, "no parser warnings", source.warnings.joined(separator: "; "))
    }

    // MARK: - Comparison

    let comparison = SchemaComparer().compare(source: source, target: target)

    t.suite("schema comparison") {
        t.equal(difference(comparison, "dbo.Customer")?.status, .different, "altered table")
        t.equal(difference(comparison, "Sales.Orders")?.status, .onlyInSource, "new table")
        t.equal(difference(comparison, "dbo.Legacy")?.status, .onlyInTarget, "dropped table")
        t.equal(difference(comparison, "dbo.vCustomerOrders")?.status, .different, "changed view")
        t.equal(difference(comparison, "dbo.GetCustomer")?.status, .identical,
                "formatting-only procedure change is identical")
        let details = difference(comparison, "dbo.Customer")?.details ?? []
        t.expect(details.contains { $0.contains("Name") }, "details name the widened column",
                 details.joined(separator: " | "))
        t.expect(details.contains { $0.contains("Email") }, "details name the added column")

        var strict = SchemaCompareOptions()
        strict.ignoreWhitespace = false
        strict.caseSensitiveDefinitions = true
        let exact = SchemaComparer(options: strict).compare(source: source, target: target)
        t.equal(difference(exact, "dbo.GetCustomer")?.status, .different,
                "procedure differs when whitespace and case count")

        let filter = SchemaFilter(excludedTypes: [.view],
                                  rules: [SchemaFilterRule(action: .exclude, types: [.table], field: .name,
                                                           op: .equals, value: "Legacy")])
        let filtered = SchemaComparer(filter: filter).compare(source: source, target: target)
        t.expect(difference(filtered, "dbo.vCustomerOrders") == nil, "excluded object type")
        t.expect(difference(filtered, "dbo.Legacy") == nil, "filter rule")
        t.expect(difference(filtered, "dbo.Customer") != nil, "other tables stay")
    }

    // MARK: - Deployment

    t.suite("schema deployment") {
        let plan = SchemaDeploymentPlanner(comparison: comparison, targetDatabaseName: "Target").plan()
        let script = plan.script
        func position(_ text: String) -> Int {
            guard let range = script.range(of: text) else { return -1 }
            return script.distance(from: script.startIndex, to: range.lowerBound)
        }
        t.expect(position("BEGIN TRANSACTION") >= 0 && position("@Success") >= 0, "transactional wrapper")
        t.expect(position("CREATE SCHEMA [Sales]") >= 0, "schema dependency is created")
        t.expect(position("CREATE SCHEMA [Sales]") < position("CREATE TABLE [Sales].[Orders]"),
                 "schema before its table")
        t.expect(position("CREATE TABLE [Sales].[Orders]") < position("FOREIGN KEY"),
                 "foreign keys after the tables they join")
        t.expect(position("ALTER TABLE [dbo].[Customer] ADD") >= 0 || position("[Email]") >= 0,
                 "added column is scripted")
        t.expect(position("DROP TABLE [dbo].[Legacy]") >= 0, "dropped table")
        t.expect(position("CREATE PROCEDURE") < 0 && position("ALTER PROCEDURE") < 0,
                 "identical procedure is left alone")
        t.expect(plan.warnings.contains { $0.object.contains("Legacy") }, "dropping a table warns")

        let onlyOrders: Set<String> = Set(comparison.differences.filter { $0.displayName == "Sales.Orders" }.map(\.id))
        let partial = SchemaDeploymentPlanner(comparison: comparison).plan(selectedIDs: onlyOrders)
        t.expect(partial.script.contains("CREATE SCHEMA [Sales]"), "selected object pulls in its schema")
        t.expect(!partial.script.contains("DROP TABLE [dbo].[Legacy]"), "unselected drop is skipped")

        var options = comparison.options
        options.doNotUseTransactions = true
        var plain = comparison
        plain.options = options
        let untransacted = SchemaDeploymentPlanner(comparison: plain).plan().script
        t.expect(!untransacted.contains("BEGIN TRANSACTION"), "transactions can be switched off")
    }

    // MARK: - Round trips

    t.suite("schema round trips") {
        // Everything the writer scripts must parse back to the same objects.
        let writer = SchemaScriptWriter()
        var scripted = ""
        for object in source.objects { scripted += writer.script(for: object) + "\nGO\n" }
        let reparsed = snapshot(scripted, origin: "Reparsed")
        let again = SchemaComparer().compare(source: source, target: reparsed)
        let differing = again.differences.filter { $0.status != .identical }.map(\.displayName)
        t.expect(differing.isEmpty, "scripted objects parse back identical", differing.joined(separator: ", "))

        do {
            let data = try SchemaSnapshotFile.encode(source)
            let decoded = try SchemaSnapshotFile.decode(data)
            let fromFile = SchemaComparer().compare(source: source, target: decoded)
            t.expect(!fromFile.hasDifferences, "snapshot file round trip")
        } catch {
            t.expect(false, "snapshot file round trip", "\(error)")
        }
    }

    // MARK: - Options and projects

    t.suite("compare options") {
        var options = SchemaCompareOptions()
        let unknown = options.apply(list: "-IgnoreWhitespace, ignoreComments, NoSuchOption")
        t.expect(!options.ignoreWhitespace && options.ignoreComments, "switches apply by name")
        t.equal(unknown, ["NoSuchOption"], "unknown names are reported")
        do {
            // Options saved before a new one existed still load, with defaults for the rest.
            let partial = Data(#"{"ignoreComments": true}"#.utf8)
            let decoded = try JSONDecoder().decode(SchemaCompareOptions.self, from: partial)
            t.expect(decoded.ignoreComments && decoded.ignoreWhitespace, "partial options decode with defaults")
        } catch {
            t.expect(false, "partial options decode", "\(error)")
        }

        var data = DataCompareOptions()
        data.apply(list: "forceBinaryCollation, -disableForeignKeys, rowsPerBatch=50, floatDecimalPlaces=3")
        t.expect(data.forceBinaryCollation && !data.disableForeignKeys, "data switches")
        t.expect(data.rowsPerBatch == 50 && data.floatDecimalPlaces == 3, "numeric settings")

        var project = CompareProject(kind: .data, name: "Nightly",
                                     source: CompareEndpoint(kind: .database, database: "A"),
                                     target: CompareEndpoint(kind: .database, database: "B"))
        project.data?.options = data
        project.data?.tablePairs = ["dbo.Old": "dbo.New"]
        do {
            let decoded = try CompareProject.decode(project.encoded())
            t.equal(decoded.kind, .data, "project kind")
            t.equal(decoded.data?.options.rowsPerBatch, 50, "project options")
            t.equal(decoded.data?.tablePairs["dbo.Old"], "dbo.New", "project table pairs")
            t.equal(decoded.target.database, "B", "project endpoints")
        } catch {
            t.expect(false, "project round trip", "\(error)")
        }
    }

    // MARK: - Data values

    t.suite("data value comparison") {
        let comparer = DataValueComparer(options: DataCompareOptions())
        let ci = DataValueComparer.TextRule(collation: "SQL_Latin1_General_CP1_CI_AS")
        let cs = DataValueComparer.TextRule(collation: "Latin1_General_CS_AS")
        let bin = DataValueComparer.TextRule(collation: "Latin1_General_BIN2")
        t.expect(comparer.equal(.string("Tehran"), .string("TEHRAN"), rule: ci), "case-insensitive collation")
        t.expect(!comparer.equal(.string("Tehran"), .string("TEHRAN"), rule: cs), "case-sensitive collation")
        t.expect(!comparer.equal(.string("a"), .string("A"), rule: bin), "binary collation")
        t.expect(comparer.equal(.string("abc"), .string("abc   "), rule: cs), "trailing spaces are ignored")
        t.expect(comparer.equal(.int(5), .decimal(TDSDecimal(digits: "500", scale: 2, isNegative: false)), rule: .exact),
                 "numbers compare by value across types")
        t.expect(!comparer.equal(.null, .string(""), rule: .exact), "NULL is not an empty string")
        t.equal(comparer.keyComponent(.string("Ali "), rule: ci), comparer.keyComponent(.string("ALI"), rule: ci),
                "equal keys produce the same dictionary key")

        var rounding = DataCompareOptions()
        rounding.floatDecimalPlaces = 2
        rounding.treatEmptyStringsAsNull = true
        let loose = DataValueComparer(options: rounding)
        t.expect(loose.equal(.double(1.004), .double(1.0), rule: .exact), "floats rounded to decimal places")
        t.expect(loose.equal(.null, .string(""), rule: .exact), "empty string as NULL when asked")
    }

    t.suite("sql literals") {
        var date = TDSTemporal(kind: .dateTime)
        date.year = 2024
        date.month = 3
        date.day = 4
        date.hour = 10
        date.nanosecond = 123_000_000
        t.equal(SQLLiteral.render(.temporal(date)), "'2024-03-04T10:00:00.123'",
                "datetime literal is language neutral")
        var day = TDSTemporal(kind: .date)
        day.year = 2024
        day.month = 3
        day.day = 4
        t.equal(SQLLiteral.render(.temporal(day)), "'20240304'", "date literal is language neutral")
        t.equal(SQLLiteral.render(.double(.nan)), "NULL", "NaN has no literal")
        t.equal(SQLLiteral.hex([0x00, 0xAB, 0xFF]), "00ABFF", "hex digits")
        t.equal(SQLLiteral.render(.string("it's")), "N'it''s'", "quotes are escaped")
    }

    // MARK: - Data synchronization

    t.suite("data synchronization script") {
        let idColumn = DataColumnInfo(name: "Id", dataType: "int", isNullable: false, isIdentity: true)
        let nameColumn = DataColumnInfo(name: "Name", dataType: "nvarchar(50)", isNullable: false,
                                        collation: "SQL_Latin1_General_CP1_CI_AS")
        let key = DataKeyInfo(kind: .primaryKey, name: "PK_Customer", columns: ["Id"])
        let customer = DataTableInfo(schema: "dbo", name: "Customer", isView: false, columns: [idColumn, nameColumn],
                                     keys: [key], enabledTriggers: ["trgAudit"])
        let orderColumns = [DataColumnInfo(name: "Id", dataType: "int", isNullable: false),
                            DataColumnInfo(name: "CustomerId", dataType: "int", isNullable: false)]
        let orders = DataTableInfo(schema: "dbo", name: "Orders", isView: false, columns: orderColumns,
                                   keys: [DataKeyInfo(kind: .primaryKey, name: "PK_Orders", columns: ["Id"])])

        let mapped = DataCompareMapper.map(source: [customer, orders], target: [customer, orders])
        t.equal(mapped.mappings.count, 2, "tables pair by name")
        t.expect(mapped.mappings.allSatisfy { $0.keySource == .primaryKey && $0.isIncluded },
                 "primary keys are chosen")

        var customerResult = DataTableResult(mapping: mapped.mappings[0])
        customerResult.rows = [
            DataRowDifference(id: 0, status: .onlyInSource, key: [.int(3)], source: [.string("Sara")], target: nil),
            DataRowDifference(id: 1, status: .different, key: [.int(1)], source: [.string("Ali")],
                              target: [.string("Aly")], differingColumns: [0]),
            DataRowDifference(id: 2, status: .onlyInTarget, key: [.int(9)], source: nil, target: [.string("Old")]),
            DataRowDifference(id: 3, status: .onlyInSource, key: [.int(4)], source: [.string("Skip")], target: nil,
                              isSelected: false)
        ]
        customerResult.onlyInSource = 2
        customerResult.different = 1
        customerResult.onlyInTarget = 1
        var ordersResult = DataTableResult(mapping: mapped.mappings[1])
        ordersResult.rows = [
            DataRowDifference(id: 0, status: .onlyInSource, key: [.int(7)], source: [.int(3)], target: nil)
        ]
        ordersResult.onlyInSource = 1
        let foreignKey = DataForeignKeyInfo(name: "FK_Orders_Customer", table: "dbo.orders",
                                            referencedTable: "dbo.customer", quotedTable: "[dbo].[Orders]",
                                            isEnabled: true, isTrusted: true)
        let comparison = DataComparison(sourceDescription: "A", targetDescription: "B", sourceDatabase: "A",
                                        targetDatabase: "B", options: DataCompareOptions(),
                                        tables: [ordersResult, customerResult], targetForeignKeys: [foreignKey])

        let plan = DataSyncScripter(comparison: comparison).plan()
        let script = plan.script
        func position(_ text: String) -> Int {
            guard let range = script.range(of: text) else { return -1 }
            return script.distance(from: script.startIndex, to: range.lowerBound)
        }
        t.equal(plan.totalInserts, 2, "only ticked rows are inserted")
        t.equal(plan.totalUpdates, 1, "one update")
        t.equal(plan.totalDeletes, 1, "one delete")
        t.expect(position("UPDATE [dbo].[Customer] SET [Name] = N'Ali' WHERE [Id] = 1") >= 0, "update statement")
        t.expect(position("DELETE FROM [dbo].[Customer] WHERE [Id] = 9") >= 0, "delete statement")
        t.expect(position("N'Skip'") < 0, "unticked row is left out")
        t.expect(position("SET IDENTITY_INSERT [dbo].[Customer] ON") >= 0, "identity values are kept")
        t.expect(position("NOCHECK CONSTRAINT [FK_Orders_Customer]") >= 0, "enabled foreign keys are disabled")
        t.expect(position("WITH CHECK CHECK CONSTRAINT [FK_Orders_Customer]") >= 0,
                 "trusted foreign keys are re-checked")
        t.expect(position("DISABLE TRIGGER [dbo].[trgAudit]") >= 0
                 && position("ENABLE TRIGGER [dbo].[trgAudit]") > position("DISABLE TRIGGER [dbo].[trgAudit]"),
                 "enabled triggers are switched off around the changes")
        t.expect(position("INSERT INTO [dbo].[Customer]") < position("INSERT INTO [dbo].[Orders]"),
                 "parents are inserted before children")

        var noDeletes = DataCompareOptions()
        noDeletes.deployDeletes = false
        noDeletes.disableForeignKeys = false
        let partial = DataSyncScripter(comparison: comparison, options: noDeletes).plan()
        t.equal(partial.totalDeletes, 0, "deletes can be switched off")
        t.expect(!partial.script.contains("NOCHECK"), "foreign keys stay on when asked")
    }

    // MARK: - Regressions

    t.suite("parser regressions") {
        // An inline PRIMARY KEY / UNIQUE must not swallow the column attributes written after it.
        let inline = snapshot("""
        CREATE TABLE [dbo].[InlineKeys] (
            [Id] int NOT NULL PRIMARY KEY IDENTITY(1,1),
            [Guid] uniqueidentifier NOT NULL UNIQUE ROWGUIDCOL,
            [Code] nvarchar(10) UNIQUE NONCLUSTERED WITH (FILLFACTOR = 80) ON [PRIMARY] SPARSE NULL,
            [Email] nvarchar(200) UNIQUE MASKED WITH (FUNCTION = 'email()') NOT NULL
        )
        GO
        """, origin: "Inline")
        let inlineTable = snapshotObject(inline, "InlineKeys")?.table
        t.expect(inlineTable?.column(named: "Id")?.identity != nil, "IDENTITY after an inline PRIMARY KEY is kept")
        t.equal(inlineTable?.column(named: "Id")?.isNullable, false, "inline key column stays NOT NULL")
        t.equal(inlineTable?.primaryKey?.columns.map(\.name) ?? [], ["Id"], "inline primary key column")
        t.equal(inlineTable?.column(named: "Guid")?.isRowGuidCol, true, "ROWGUIDCOL after an inline UNIQUE is kept")
        t.equal(inlineTable?.column(named: "Code")?.isSparse, true, "SPARSE after an inline UNIQUE with options is kept")
        t.equal(inlineTable?.column(named: "Code")?.isNullable, true, "nullability after an inline UNIQUE is kept")
        t.equal(inlineTable?.column(named: "Email")?.maskingFunction, "email()", "MASKED WITH after an inline UNIQUE is kept")
        t.equal(inlineTable?.column(named: "Email")?.isNullable, false, "NOT NULL after a masked inline UNIQUE is kept")
        t.equal(inlineTable?.uniqueConstraints.count, 3, "three unique constraints")
        t.equal(inlineTable?.uniqueConstraints.first { $0.columns.first?.name == "Code" }?.options.fillFactor, 80,
                "inline unique constraint options")

        // PRIMARY not followed by KEY used to loop forever appending unique constraints.
        let stray = snapshot("""
        CREATE TABLE [dbo].[Stray] ([Id] int NOT NULL, [C] int NULL INDEX [IX_C] NONCLUSTERED ON PRIMARY)
        GO
        """, origin: "Stray")
        let strayObject = snapshotObject(stray, "Stray")
        t.equal(strayObject?.table?.columns.count, 2, "stray PRIMARY still yields both columns")
        t.equal(strayObject?.table?.uniqueConstraints.count, 0, "stray PRIMARY adds no unique constraint")
        t.equal(strayObject?.indexes.map(\.name) ?? [], ["IX_C"], "inline INDEX is kept")

        // DEFAULT without parentheses: NULL, literals and function calls.
        let defaults = snapshot("""
        CREATE TABLE [dbo].[Defaults] (
            [N] int NULL DEFAULT NULL,
            [Z] int NOT NULL DEFAULT 0,
            [D] datetime NOT NULL CONSTRAINT [DF_D] DEFAULT GETDATE(),
            [X] nvarchar(10) NULL DEFAULT N'x',
            [P] int NOT NULL DEFAULT (1)
        )
        GO
        """, origin: "Defaults")
        let defaultsObject = snapshotObject(defaults, "Defaults")
        func defaultExpression(_ column: String) -> String {
            ModuleText.expression(defaultsObject?.table?.column(named: column)?.defaultConstraint?.definition ?? "<none>")
        }
        t.equal(defaultExpression("N"), "null", "DEFAULT NULL")
        t.equal(defaultsObject?.table?.column(named: "N")?.isNullable, true, "DEFAULT NULL leaves the column nullable")
        t.equal(defaultExpression("Z"), "0", "DEFAULT 0")
        t.equal(defaultExpression("D"), ModuleText.expression("GETDATE()"), "DEFAULT GETDATE()")
        t.equal(defaultsObject?.table?.column(named: "D")?.defaultConstraint?.name, "DF_D", "named bare default")
        t.equal(defaultExpression("X"), ModuleText.expression("N'x'"), "DEFAULT N'x'")
        t.equal(defaultExpression("P"), "1", "DEFAULT (1)")
        if let defaultsObject {
            let scripted = SchemaScriptWriter().script(for: defaultsObject)
            t.expect(scripted.contains("DEFAULT (NULL)") && !scripted.contains("DEFAULT ()"),
                     "NULL default scripts as (NULL)", scripted)
        }

        // SET ANSI_NULLS, QUOTED_IDENTIFIER ON names several options at once.
        let settings = snapshot("""
        SET ANSI_NULLS, QUOTED_IDENTIFIER ON
        GO
        CREATE PROCEDURE [dbo].[Both] AS SELECT 1
        GO
        SET ANSI_NULLS, QUOTED_IDENTIFIER OFF
        GO
        CREATE PROCEDURE [dbo].[Neither] AS SELECT 1
        GO
        SET QUOTED_IDENTIFIER OFF
        GO
        SET ANSI_NULLS ON
        GO
        CREATE PROCEDURE [dbo].[Mixed] AS SELECT 1
        GO
        """, origin: "Settings")
        let both = snapshotObject(settings, "Both")
        let neither = snapshotObject(settings, "Neither")
        let mixed = snapshotObject(settings, "Mixed")
        t.expect(both?.usesAnsiNulls == true && both?.usesQuotedIdentifier == true, "SET a, b ON sets both")
        t.expect(neither?.usesAnsiNulls == false && neither?.usesQuotedIdentifier == false, "SET a, b OFF clears both")
        t.expect(mixed?.usesAnsiNulls == true && mixed?.usesQuotedIdentifier == false, "single SET statements still apply")

        // GRANT CREATE TABLE is one statement, not GRANT + CREATE.
        let granted = snapshot("""
        CREATE ROLE [app_role] AUTHORIZATION [dbo]
        GO
        GRANT CREATE TABLE, CREATE VIEW TO [app_role]
        GO
        DENY CREATE PROCEDURE TO [app_role]
        GO
        """, origin: "Granted")
        let role = granted.objects.first { $0.type == .role }
        let rolePermissions = Set(role?.permissions.map { "\($0.state) \($0.permission)" } ?? [])
        t.expect(rolePermissions.contains("GRANT CREATE TABLE") && rolePermissions.contains("GRANT CREATE VIEW")
                 && rolePermissions.contains("DENY CREATE PROCEDURE"), "database-level CREATE permissions are read",
                 rolePermissions.sorted().joined(separator: ", "))
        t.expect(granted.warnings.isEmpty, "no warning for GRANT CREATE", granted.warnings.joined(separator: "; "))

        // A module keeps its final semicolon, so it compares equal to the live definition.
        let ending = snapshot("""
        CREATE PROCEDURE [dbo].[Ends] AS
        BEGIN
            SELECT 1
        END;
        GO
        CREATE ASSEMBLY [Asm] FROM 0x4D5A;
        GO
        """, origin: "Ending")
        let ends = snapshotObject(ending, "Ends")
        t.expect(ends?.body.hasSuffix("END;") ?? false, "module body keeps its trailing semicolon", ends?.body ?? "")
        t.expect(!(snapshotObject(ending, "Asm")?.body.hasSuffix(";") ?? true),
                 "other statements still lose the trailing semicolon")
        let liveEnds = SchemaObject(type: .storedProcedure, schema: "dbo", name: "Ends",
                                    body: "CREATE PROCEDURE [dbo].[Ends] AS\nBEGIN\n    SELECT 1\nEND;\n", subtype: "P")
        let liveEnding = SchemaSnapshot(origin: "Live", defaultCollation: "SQL_Latin1_General_CP1_CI_AS", objects: [liveEnds])
        t.equal(difference(SchemaComparer().compare(source: ending, target: liveEnding), "dbo.Ends")?.status, .identical,
                "scripted END; equals the live END;")
        let rewritten = snapshot(SchemaScriptWriter().script(for: liveEnds), origin: "Rewritten")
        t.equal(difference(SchemaComparer().compare(source: rewritten, target: liveEnding), "dbo.Ends")?.status, .identical,
                "a scripts folder written from the database reads back identical")
    }

    t.suite("normalizer regressions") {
        let defaultCollation = "SQL_Latin1_General_CP1_CI_AS"
        let writer = SchemaScriptWriter()

        // Alias-type columns never get a COLLATE clause (Msg 452), even from older snapshots.
        var phone = ColumnDefinition(name: "Phone", dataType: "[dbo].[Phone]", isUserDefinedType: true, isNullable: true)
        phone.collation = defaultCollation
        t.equal(writer.columnDefinition(phone), "[Phone] [dbo].[Phone] NULL", "no COLLATE on a user-defined type")
        var contacts = SchemaObject(type: .table, schema: "dbo", name: "Contacts")
        contacts.table = TableDefinition(columns: [phone])
        let scriptedContacts = snapshot("""
        CREATE TYPE [dbo].[Phone] FROM varchar(20) NULL
        GO
        CREATE TABLE [dbo].[Contacts] ([Phone] [dbo].[Phone] NULL)
        GO
        """, origin: "Scripted")
        let liveContacts = SchemaSnapshot(origin: "Live", defaultCollation: defaultCollation, objects: [contacts])
        t.equal(difference(SchemaComparer().compare(source: scriptedContacts, target: liveContacts), "dbo.Contacts")?.status,
                .identical, "a stored collation on an alias-type column is not a difference")

        // Columnstore indexes: the catalog reports lock options off; they are not real options.
        var columnstoreOptions = IndexOptions()
        columnstoreOptions.allowRowLocks = false
        columnstoreOptions.allowPageLocks = false
        columnstoreOptions.dataCompression = "COLUMNSTORE"
        var columnstore = SchemaObject(type: .table, schema: "dbo", name: "Cs")
        columnstore.table = TableDefinition(columns: [ColumnDefinition(name: "Id", dataType: "int", isNullable: false),
                                                     ColumnDefinition(name: "V", dataType: "nvarchar(50)", isNullable: true)],
                                            dataCompression: "COLUMNSTORE")
        columnstore.indexes = [
            IndexDefinition(name: "CCI_Cs", kind: .clusteredColumnstore, columns: [], options: columnstoreOptions),
            IndexDefinition(name: "NCI_Cs", kind: .nonclusteredColumnstore, columns: [], includedColumns: ["V"],
                            options: columnstoreOptions)
        ]
        let scriptedColumnstore = snapshot("""
        CREATE TABLE [dbo].[Cs] ([Id] int NOT NULL, [V] nvarchar(50) NULL)
        GO
        CREATE CLUSTERED COLUMNSTORE INDEX [CCI_Cs] ON [dbo].[Cs]
        GO
        CREATE NONCLUSTERED COLUMNSTORE INDEX [NCI_Cs] ON [dbo].[Cs] ([V])
        GO
        """, origin: "Scripted")
        let liveColumnstore = SchemaSnapshot(origin: "Live", defaultCollation: defaultCollation, objects: [columnstore])
        let columnstoreComparison = SchemaComparer().compare(source: scriptedColumnstore, target: liveColumnstore)
        t.equal(difference(columnstoreComparison, "dbo.Cs")?.status, .identical,
                "columnstore lock options and table compression do not count")
        let create = writer.createTableStatement(columnstore, name: "[dbo].[Cs]")
        t.expect(!create.contains("DATA_COMPRESSION"), "CREATE TABLE never asks for columnstore compression", create)

        // Spatial indexes script their column and tessellation, or a comment, never "()".
        var spatial = IndexDefinition(name: "SIX_Geo", kind: .spatial, columns: [IndexColumn(name: "Shape")], dataSpace: "")
        spatial.spatialTessellation = "GEOMETRY_GRID"
        spatial.spatialBoundingBox = "BOUNDING_BOX = (0, 0, 500, 200), GRIDS = (LEVEL_1 = MEDIUM, LEVEL_2 = MEDIUM, "
            + "LEVEL_3 = MEDIUM, LEVEL_4 = MEDIUM), CELLS_PER_OBJECT = 16"
        let spatialStatement = writer.createIndexStatement(spatial, on: "[dbo].[Geo]")
        t.expect(spatialStatement.hasPrefix("CREATE SPATIAL INDEX [SIX_Geo] ON [dbo].[Geo] ([Shape]) USING GEOMETRY_GRID "
                                            + "WITH (BOUNDING_BOX = (0, 0, 500, 200), GRIDS = ("),
                 "spatial index scripts its column, tessellation and options", spatialStatement)
        let blank = IndexDefinition(name: "SIX_Blank", kind: .spatial, columns: [], dataSpace: "")
        let blankStatement = writer.createIndexStatement(blank, on: "[dbo].[Geo]")
        t.expect(!blankStatement.contains("()") && blankStatement.hasPrefix("/*"),
                 "a spatial index without a column becomes a comment, not invalid SQL", blankStatement)
        var geo = SchemaObject(type: .table, schema: "dbo", name: "Geo")
        geo.table = TableDefinition(columns: [ColumnDefinition(name: "Id", dataType: "int", isNullable: false),
                                              ColumnDefinition(name: "Shape", dataType: "geometry", isNullable: true)])
        geo.indexes = [spatial]
        let scriptedGeo = snapshot("CREATE TABLE [dbo].[Geo] ([Id] int NOT NULL, [Shape] geometry NULL)\nGO\n"
                                   + spatialStatement + "\nGO\n", origin: "Scripted")
        let liveGeo = SchemaSnapshot(origin: "Live", defaultCollation: defaultCollation, objects: [geo])
        t.equal(difference(SchemaComparer().compare(source: scriptedGeo, target: liveGeo), "dbo.Geo")?.status, .identical,
                "scripted spatial index reads back identical")

        // Table types: the default collation is not part of the body; IgnoreCollations covers the rest.
        let typed = snapshot("""
        CREATE TYPE [dbo].[Names] AS TABLE (
            [Name] nvarchar(50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
            [Code] char(3) COLLATE Latin1_General_BIN NOT NULL
        )
        GO
        """, origin: "Typed")
        let typedBody = typed.objects.first { $0.type == .tableType }?.body ?? ""
        t.expect(!typedBody.contains("SQL_Latin1_General_CP1_CI_AS") && typedBody.contains("COLLATE Latin1_General_BIN"),
                 "table type keeps only non-default collations", typedBody)
        let liveBody = writer.tableTypeBody(
            quotedName: "[dbo].[Names]",
            columns: [ColumnDefinition(name: "Name", dataType: "nvarchar(50)", collation: defaultCollation),
                      ColumnDefinition(name: "Code", dataType: "char(3)", isNullable: false, collation: "Latin1_General_BIN")],
            indexes: [], checks: [], memoryOptimized: false, defaultCollation: defaultCollation)
        t.equal(liveBody, typedBody, "live table type body matches the scripted one")
        let plain = snapshot("CREATE TYPE [dbo].[Names] AS TABLE ([Name] nvarchar(50) NULL, [Code] char(3) NOT NULL)\nGO\n",
                             origin: "Plain")
        t.equal(difference(SchemaComparer().compare(source: typed, target: plain), "dbo.Names")?.status, .different,
                "a non-default collation on a table type column counts")
        var ignoringCollations = SchemaCompareOptions()
        ignoringCollations.ignoreCollations = true
        let ignored = SchemaComparer(options: ignoringCollations).compare(source: typed, target: plain)
        t.equal(difference(ignored, "dbo.Names")?.status, .identical, "IgnoreCollations covers table types")
        t.expect(!(difference(ignored, "dbo.Names")?.sourceScript.contains("COLLATE") ?? true),
                 "ignored collations are not scripted for table types")

        // IgnoreIndexes covers primary keys and unique constraints, as its description promises.
        let keyed = snapshot("""
        CREATE TABLE [dbo].[Keyed] (
            [Id] int NOT NULL, [Code] int NOT NULL,
            CONSTRAINT [PK_Keyed] PRIMARY KEY CLUSTERED ([Id]),
            CONSTRAINT [UQ_Keyed] UNIQUE ([Code])
        )
        GO
        CREATE NONCLUSTERED INDEX [IX_Keyed] ON [dbo].[Keyed] ([Code])
        GO
        """, origin: "Keyed")
        let heap = snapshot("CREATE TABLE [dbo].[Keyed] ([Id] int NOT NULL, [Code] int NOT NULL)\nGO\n", origin: "Heap")
        var ignoringIndexes = SchemaCompareOptions()
        ignoringIndexes.ignoreIndexes = true
        let unkeyed = SchemaComparer(options: ignoringIndexes).compare(source: keyed, target: heap)
        t.equal(difference(unkeyed, "dbo.Keyed")?.status, .identical, "IgnoreIndexes ignores keys and unique constraints")
        let unkeyedScript = difference(unkeyed, "dbo.Keyed")?.sourceScript ?? ""
        t.expect(!unkeyedScript.contains("PRIMARY KEY") && !unkeyedScript.contains("UNIQUE")
                 && !unkeyedScript.contains("CREATE NONCLUSTERED INDEX"), "ignored keys are not scripted", unkeyedScript)
        t.equal(difference(SchemaComparer().compare(source: keyed, target: heap), "dbo.Keyed")?.status, .different,
                "keys still count by default")
    }

    t.suite("deployment warnings") {
        let wanted = snapshot("""
        CREATE TABLE [dbo].[Members] (
            [Id] int NOT NULL CONSTRAINT [PK_Members] PRIMARY KEY,
            [Code] nvarchar(10) NULL,
            [Tag] nvarchar(10) NULL,
            [Alt] nvarchar(10) NULL,
            [Fixed] nvarchar(10) NOT NULL,
            CONSTRAINT [UQ_Members_Code] UNIQUE ([Code]),
            CONSTRAINT [UQ_Members_Fixed] UNIQUE ([Fixed])
        )
        GO
        CREATE UNIQUE NONCLUSTERED INDEX [UX_Members_Tag] ON [dbo].[Members] ([Tag])
        GO
        CREATE UNIQUE NONCLUSTERED INDEX [UX_Members_Alt] ON [dbo].[Members] ([Alt]) WHERE [Alt] IS NOT NULL
        GO
        """, origin: "Wanted")
        let existing = snapshot("CREATE TABLE [dbo].[Members] ([Id] int NOT NULL CONSTRAINT [PK_Members] PRIMARY KEY)\nGO\n",
                                origin: "Existing")
        let plan = SchemaDeploymentPlanner(comparison: SchemaComparer().compare(source: wanted, target: existing),
                                           targetDatabaseName: "Existing").plan()
        let high = plan.warnings.filter { $0.severity == .high }.map(\.message)
        t.expect(high.contains { $0.contains("[UQ_Members_Code]") && $0.contains("[Code]") },
                 "a unique constraint over a new nullable column warns", high.joined(separator: " | "))
        t.expect(high.contains { $0.contains("[UX_Members_Tag]") }, "a unique index over a new nullable column warns")
        t.expect(!high.contains { $0.contains("[UX_Members_Alt]") }, "a filtered unique index that excludes NULLs does not warn")
        t.expect(!high.contains { $0.contains("[UQ_Members_Fixed]") }, "a unique constraint over a NOT NULL column does not warn")
    }
}
