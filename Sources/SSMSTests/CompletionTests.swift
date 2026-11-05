import Foundation
import TDSKit
import SQLServerKit

/// What the completion list actually offers, at a caret, against a known catalog.
///
/// This is the suite that was missing. Every IntelliSense regression so far — the dot
/// that opened nothing, the alias that inserted itself into a WHERE clause, the member
/// list that came back empty — was invisible to the tests because the logic sat on an
/// actor that needed a server. It does not any more.
func runCompletionTests(_ t: TestRunner) {

    let customers = IntelliSenseObject(
        schema: "dbo", name: "Customers", kind: "table",
        columns: [
            IntelliSenseColumn(name: "CustomerId", typeName: "int", isNullable: false,
                               isPrimaryKey: true, ordinal: 1),
            IntelliSenseColumn(name: "FullName", typeName: "nvarchar(120)", isNullable: false,
                               isPrimaryKey: false, ordinal: 2),
            IntelliSenseColumn(name: "City", typeName: "nvarchar(60)", isNullable: true,
                               isPrimaryKey: false, ordinal: 3)
        ])
    let orders = IntelliSenseObject(
        schema: "sales", name: "Orders", kind: "table",
        columns: [
            IntelliSenseColumn(name: "OrderId", typeName: "int", isNullable: false,
                               isPrimaryKey: true, ordinal: 1),
            IntelliSenseColumn(name: "CustomerId", typeName: "int", isNullable: false,
                               isPrimaryKey: false, ordinal: 2),
            IntelliSenseColumn(name: "Placed", typeName: "datetime2(7)", isNullable: false,
                               isPrimaryKey: false, ordinal: 3)
        ])
    let archive = IntelliSenseObject(schema: "dbo", name: "DeliveryVendor", kind: "table")
    let procedure = IntelliSenseObject(schema: "sales", name: "RecalculateTotals",
                                       kind: "procedure")

    let catalog = IntelliSenseCatalog(
        database: "Demo", fetchedAt: Date(), schemas: ["dbo", "sales"],
        tables: [customers, orders, archive], routines: [procedure])
    let engine = CompletionEngine(catalog: catalog)

    /// Completions at the caret marked `|` in the script.
    func at(_ marked: String, engine: CompletionEngine = engine) -> CompletionResult {
        guard let caret = marked.firstIndex(of: "|") else {
            return CompletionResult(items: [], isMemberContext: false, hasCatalog: false)
        }
        let script = marked.replacingOccurrences(of: "|", with: "")
        let offset = marked.distance(from: marked.startIndex, to: caret)
        return engine.result(script: script, offset: offset)
    }

    func labels(_ result: CompletionResult) -> [String] { result.items.map(\.label) }

    t.suite("completion after a dot") {
        // The case that kept coming back: an alias, then a dot, then nothing.
        let alias = at("SELECT * FROM sales.Orders AS o WHERE o.|")
        t.expect(alias.isMemberContext, "a qualifier is a member context")
        t.equal(labels(alias).sorted(), ["CustomerId", "OrderId", "Placed"],
                "the alias answers with that table's columns")
        t.expect(alias.pendingColumns.isEmpty, "nothing needs reading: the columns are there")

        // The same, written without AS, and with the table named in full.
        let bareAlias = at("SELECT * FROM sales.Orders o WHERE o.|")
        t.equal(labels(bareAlias).sorted(), ["CustomerId", "OrderId", "Placed"],
                "an alias without AS is still an alias")
        let byName = at("SELECT * FROM dbo.Customers WHERE Customers.|")
        t.equal(labels(byName).sorted(), ["City", "CustomerId", "FullName"],
                "a table can qualify its own columns")

        // A dot in the middle of typing a column name filters, it does not reset.
        let partial = at("SELECT * FROM dbo.Customers AS c WHERE c.Ci|")
        t.equal(labels(partial).sorted(), ["City", "CustomerId", "FullName"],
                "the list is still the member list while a name is being typed")

        // A schema before the dot lists what is in it, not columns.
        let schema = at("SELECT * FROM sales.|")
        t.expect(labels(schema).contains("Orders"), "a schema lists its tables",
                 labels(schema).joined(separator: ","))
        t.expect(labels(schema).contains("RecalculateTotals"), "and its routines")

        // EXEC narrows a schema to the routines in it.
        let exec = at("EXEC sales.|")
        t.equal(labels(exec), ["RecalculateTotals"], "EXEC offers procedures only")

        // A table whose columns have not been read yet asks for them rather than
        // answering with an empty list.
        let unread = at("SELECT * FROM dbo.DeliveryVendor AS v WHERE v.|")
        t.expect(unread.items.isEmpty, "there is nothing to offer yet")
        t.equal(unread.pendingColumns, [ObjectReference(schema: "dbo", name: "DeliveryVendor")],
                "and the engine says which object to read")

        // Once those columns land, the same caret answers.
        var filled = archive
        filled.columns = [IntelliSenseColumn(name: "VendorId", typeName: "int",
                                             isNullable: false, isPrimaryKey: true, ordinal: 1)]
        let secondTry = CompletionEngine(catalog: IntelliSenseCatalog(
            database: "Demo", fetchedAt: Date(), schemas: ["dbo", "sales"],
            tables: [customers, orders, filled], routines: [procedure]))
        let answered = at("SELECT * FROM dbo.DeliveryVendor AS v WHERE v.|", engine: secondTry)
        t.equal(labels(answered), ["VendorId"], "and then it answers")
        t.expect(answered.pendingColumns.isEmpty, "with nothing left to read")

        // An unknown qualifier offers nothing rather than falling back to keywords.
        let unknown = at("SELECT * FROM dbo.Customers AS c WHERE zz.|")
        t.expect(unknown.items.isEmpty, "an unknown qualifier has no members")
        t.expect(unknown.isMemberContext,
                 "and says so, so the editor does not offer keywords instead")

        // An empty list after a dot is the one case that reads as a broken editor, so
        // every one of them carries the reason the popup shows instead.
        t.expect(unknown.message?.contains("zz") == true,
                 "an unknown qualifier names itself", unknown.message ?? "none")
        t.expect(unread.message?.contains("DeliveryVendor") == true,
                 "a table still being read says so", unread.message ?? "none")
        let noCatalog = at("SELECT * FROM dbo.Customers AS c WHERE c.|",
                           engine: CompletionEngine(catalog: nil))
        t.expect(noCatalog.message?.isEmpty == false,
                 "and so does a window whose catalog never arrived", noCatalog.message ?? "none")
        t.expect(alias.message == nil, "a list that has rows carries no message")
    }

    t.suite("completion scope") {
        // Most T-SQL scripts have no semicolons, so the statement around the caret
        // has to be found from its keywords, not from a terminator that is not there.
        let twoQueries = at("SELECT * FROM dbo.Customers t\n\nSELECT * FROM sales.Orders t WHERE t.|")
        t.equal(labels(twoQueries).sorted(), ["CustomerId", "OrderId", "Placed"],
                "an alias resolves within its own statement, not the first one in the tab")

        let whereScope = at("SELECT * FROM dbo.Customers c\n\nSELECT * FROM sales.Orders o WHERE |")
        t.expect(labels(whereScope).contains("Placed"), "the current statement's columns are offered")
        t.expect(!labels(whereScope).contains("FullName"),
                 "and the previous statement's are not",
                 labels(whereScope).prefix(6).joined(separator: ","))

        let laterQuery = at("SELECT * FROM sales.Orders o WHERE |\n\nSELECT * FROM dbo.Customers c")
        t.expect(!labels(laterQuery).contains("FullName"),
                 "nor a later statement's", labels(laterQuery).prefix(6).joined(separator: ","))

        // A SELECT inside parentheses is a subquery, not a new statement.
        let subquery = at("SELECT * FROM sales.Orders o WHERE o.CustomerId IN "
                          + "(SELECT CustomerId FROM dbo.Customers) AND o.|")
        t.equal(labels(subquery).sorted(), ["CustomerId", "OrderId", "Placed"],
                "a subquery does not cut the statement in two")

        // UNION joins two SELECTs into one statement.
        let union = at("SELECT CustomerId FROM dbo.Customers c UNION ALL "
                       + "SELECT OrderId FROM sales.Orders o WHERE o.|")
        t.equal(labels(union).sorted(), ["CustomerId", "OrderId", "Placed"],
                "UNION keeps the second SELECT's sources")

        // SET inside an UPDATE is a clause, not a SET statement.
        let updateSet = at("UPDATE sales.Orders SET Placed = GETDATE() WHERE |")
        t.expect(labels(updateSet).contains("OrderId"), "UPDATE's table is still in scope after SET",
                 labels(updateSet).prefix(6).joined(separator: ","))

        // A table hint is not a CTE.
        let hint = at("SELECT * FROM dbo.Customers c\nSELECT * FROM sales.Orders o WITH (NOLOCK) WHERE o.|")
        t.equal(labels(hint).sorted(), ["CustomerId", "OrderId", "Placed"],
                "WITH (NOLOCK) does not start a statement")

        // The alias suggested for a new table reference only avoids the aliases of
        // the statement being written.
        let aliasScope = at("SELECT * FROM dbo.Customers c\n\nSELECT * FROM |")
        let customersItem = aliasScope.items.first { $0.label == "Customers" }
        t.equal(customersItem?.insertText, "Customers AS c",
                "an alias from another statement is free to reuse")
    }

    t.suite("completion from sources the script defines") {
        func details(_ result: CompletionResult, label: String) -> [String] {
            result.items.filter { $0.label == label }.map(\.detail)
        }

        // UPDATE alias SET ... FROM table alias: the alias is the FROM's, not a table.
        let updateAlias = at("UPDATE o SET o.| FROM sales.Orders o")
        t.equal(labels(updateAlias).sorted(), ["CustomerId", "OrderId", "Placed"],
                "UPDATE alias resolves to the FROM source")
        let updateWhere = at("UPDATE o SET Placed = GETDATE() FROM sales.Orders o WHERE o.|")
        t.equal(labels(updateWhere).sorted(), ["CustomerId", "OrderId", "Placed"],
                "and so does the WHERE after it")

        // A CTE has the columns of its select list.
        let cte = at("WITH recent AS (SELECT OrderId, Placed FROM sales.Orders)\n"
                     + "SELECT * FROM recent r WHERE r.|")
        t.equal(labels(cte), ["OrderId", "Placed"], "a CTE lists its select list")
        let cteStar = at("WITH recent AS (SELECT * FROM sales.Orders)\n"
                         + "SELECT * FROM recent WHERE recent.|")
        t.equal(labels(cteStar).sorted(), ["CustomerId", "OrderId", "Placed"],
                "a star in a CTE expands from the catalog")
        let cteNamed = at("WITH recent (Id, PlacedAt) AS (SELECT OrderId, Placed FROM sales.Orders)\n"
                          + "SELECT * FROM recent r WHERE r.|")
        t.equal(labels(cteNamed), ["Id", "PlacedAt"], "a CTE column list renames them")
        let cteAliased = at("WITH recent AS (SELECT o.OrderId AS Id, o.Placed, COUNT(*) Total "
                            + "FROM sales.Orders o GROUP BY o.OrderId, o.Placed)\n"
                            + "SELECT * FROM recent r WHERE r.|")
        t.equal(labels(cteAliased), ["Id", "Placed", "Total"],
                "aliases, qualified names and bare aliases all name a column")
        let twoCtes = at("WITH a AS (SELECT OrderId FROM sales.Orders), "
                         + "b AS (SELECT a.OrderId AS Id FROM a)\nSELECT * FROM b WHERE b.|")
        t.equal(labels(twoCtes), ["Id"], "a second CTE can be built on the first")

        // A derived table is the same, named after its alias.
        let derived = at("SELECT * FROM (SELECT OrderId, Placed FROM sales.Orders) AS d WHERE d.|")
        t.equal(labels(derived), ["OrderId", "Placed"], "a derived table lists its select list")
        let derivedBare = at("SELECT * FROM (SELECT OrderId FROM sales.Orders) d JOIN dbo.Customers c ON d.|")
        t.equal(labels(derivedBare), ["OrderId"], "with or without AS")

        // What a subquery reads is not in scope outside it, but the outer query is
        // in scope inside the subquery.
        let outside = at("SELECT * FROM (SELECT OrderId FROM sales.Orders o) d WHERE |")
        t.expect(labels(outside).contains("OrderId") && !labels(outside).contains("Placed"),
                 "outside the subquery only the derived table's columns are offered",
                 labels(outside).prefix(6).joined(separator: ","))
        t.expect(details(outside, label: "OrderId").allSatisfy { $0.hasPrefix("d ·") },
                 "and they belong to the derived table", details(outside, label: "OrderId").joined(separator: ";"))
        let inside = at("SELECT * FROM sales.Orders o WHERE EXISTS "
                        + "(SELECT 1 FROM dbo.Customers c WHERE c.CustomerId = o.|)")
        t.equal(labels(inside).sorted(), ["CustomerId", "OrderId", "Placed"],
                "a correlated subquery still sees the outer alias")

        // Temp tables and table variables are defined earlier in the batch.
        let selectInto = at("SELECT OrderId, Placed INTO #recent FROM sales.Orders\n\n"
                            + "SELECT * FROM #recent WHERE #recent.|")
        t.equal(labels(selectInto), ["OrderId", "Placed"], "SELECT INTO defines a temp table")
        let selectIntoAlias = at("SELECT * INTO #recent FROM sales.Orders\n\n"
                                 + "SELECT * FROM #recent r WHERE r.|")
        t.equal(labels(selectIntoAlias).sorted(), ["CustomerId", "OrderId", "Placed"],
                "with a star, and through an alias")
        let created = at("CREATE TABLE #ids (Id int NOT NULL PRIMARY KEY, Label nvarchar(50) NULL, "
                         + "CONSTRAINT CK CHECK (Id > 0))\nSELECT * FROM #ids i WHERE i.|")
        t.equal(labels(created), ["Id", "Label"], "CREATE TABLE defines one too")
        let variable = at("DECLARE @ids TABLE (Id int, Label nvarchar(50))\n"
                          + "SELECT * FROM @ids i WHERE i.|")
        t.equal(labels(variable), ["Id", "Label"], "and so does a table variable")
        let variableDirect = at("DECLARE @ids TABLE (Id int, Label nvarchar(50))\n"
                                + "SELECT * FROM @ids WHERE @ids.|")
        t.equal(labels(variableDirect), ["Id", "Label"], "a table variable can qualify itself")
        let insertTemp = at("CREATE TABLE #ids (Id int, Label nvarchar(50))\nINSERT INTO #ids (|")
        t.expect(labels(insertTemp).contains("Label"), "INSERT INTO a temp table offers its columns",
                 labels(insertTemp).prefix(6).joined(separator: ","))

        // A CTE whose select list names nothing is in scope but has nothing to offer,
        // and the popup says that rather than claiming it does not exist.
        let unnamed = at("WITH x AS (SELECT 1 + 2 FROM sales.Orders)\nSELECT * FROM x WHERE x.|")
        t.expect(unnamed.items.isEmpty && unnamed.message?.contains("no named columns") == true,
                 "an unnamed select list is reported as such", unnamed.message ?? "none")

        // A local source in a WHERE lists its columns with the rest.
        let cteWhere = at("WITH recent AS (SELECT OrderId, Placed FROM sales.Orders)\n"
                          + "SELECT * FROM recent r WHERE |")
        t.expect(labels(cteWhere).contains("Placed") && !labels(cteWhere).contains("CustomerId"),
                 "a CTE's columns are offered in its WHERE", labels(cteWhere).prefix(6).joined(separator: ","))
    }

    t.suite("completion before the columns have been read") {
        // While only the object names are in, a WHERE or SELECT list cannot offer
        // columns; the engine names every table in scope that still needs reading so
        // the window can fetch them, instead of silently offering keywords only.
        let whereClause = at("SELECT * FROM dbo.DeliveryVendor v WHERE |")
        t.equal(whereClause.pendingColumns, [ObjectReference(schema: "dbo", name: "DeliveryVendor")],
                "a WHERE names the unread table")
        t.expect(labels(whereClause).contains("Customers"), "and still offers what it can")

        let join = at("SELECT * FROM dbo.DeliveryVendor v JOIN sales.Orders o ON |")
        t.equal(join.pendingColumns, [ObjectReference(schema: "dbo", name: "DeliveryVendor")],
                "only the tables without columns are asked for")
        let selectList = at("SELECT v.| FROM dbo.DeliveryVendor v JOIN dbo.DeliveryVendor w ON 1 = 1")
        t.equal(selectList.pendingColumns, [ObjectReference(schema: "dbo", name: "DeliveryVendor")],
                "and each only once")

        // A CTE reading an unread table through a star needs that table.
        let cte = at("WITH x AS (SELECT * FROM dbo.DeliveryVendor)\nSELECT * FROM x WHERE x.|")
        t.equal(cte.pendingColumns, [ObjectReference(schema: "dbo", name: "DeliveryVendor")],
                "a star in a CTE asks for the table behind it")
        t.expect(cte.message?.contains("DeliveryVendor") == true, "and says so", cte.message ?? "none")
    }

    t.suite("completion across databases") {
        // The catalog is the current database's. A three-part name that points at
        // another database must not be answered with a same-named table from this one.
        let other = at("SELECT * FROM Archive.dbo.Customers c WHERE c.|")
        t.expect(other.items.isEmpty, "another database's table is not guessed at",
                 labels(other).joined(separator: ","))
        t.expect(other.message?.contains("Archive") == true,
                 "and the reason names that database", other.message ?? "none")
        t.expect(other.pendingColumns.isEmpty, "and nothing is fetched for it")

        // The current database named in full is still the current database.
        let same = at("SELECT * FROM Demo.dbo.Customers c WHERE c.|")
        t.equal(labels(same).sorted(), ["City", "CustomerId", "FullName"],
                "a three-part name for this database resolves")
        let bracketed = at("SELECT * FROM [demo].[dbo].[Customers] AS c WHERE c.|")
        t.equal(labels(bracketed).sorted(), ["City", "CustomerId", "FullName"],
                "whatever its case or quoting")
    }

    t.suite("completion in context") {
        // A table reference takes an alias; the same table in a WHERE clause does not.
        let fromClause = at("SELECT * FROM |")
        let orders = fromClause.items.first { $0.label == "Orders" }
        t.expect(orders?.insertText.hasPrefix("Orders AS ") == true,
                 "FROM inserts the alias too", orders?.insertText ?? "none")
        let whereClause = at("SELECT * FROM sales.Orders AS o WHERE |")
        let inWhere = whereClause.items.first { $0.label == "Orders" }
        t.equal(inWhere?.insertText, "Orders", "a WHERE clause inserts the bare name")
        t.expect(labels(whereClause).contains("Placed"),
                 "and the columns in scope come first", labels(whereClause).prefix(5).joined(separator: ","))

        // Keywords are there when nothing else fits.
        let blank = at("|")
        t.expect(labels(blank).contains("SELECT"), "an empty script offers keywords")
        t.expect(labels(blank).contains("Customers"), "and the tables")

        // Nothing is offered inside a string or a comment.
        t.expect(at("SELECT 'o.|'").items.isEmpty, "a string literal suppresses the list")
        t.expect(at("SELECT 1 -- o.|").items.isEmpty, "so does a line comment")
        t.expect(at("/* o.| */ SELECT 1").items.isEmpty, "and a block comment")

        // A variable completes from what the batch declared.
        let variables = at("DECLARE @customerId int; SELECT @|")
        t.expect(labels(variables).contains("@customerId"), "declared variables are offered",
                 labels(variables).joined(separator: ","))

        // With no catalog at all the engine still answers with keywords, which is what
        // a window whose catalog has not loaded yet should show.
        let empty = CompletionEngine(catalog: nil)
        let keywordsOnly = at("SELECT |", engine: empty)
        t.expect(!keywordsOnly.hasCatalog, "the result says there is no catalog")
        t.expect(labels(keywordsOnly).contains("GROUP"), "and keywords are still offered")
    }
}
