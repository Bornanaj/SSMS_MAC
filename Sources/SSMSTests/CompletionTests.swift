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
        t.expect(alias.pendingColumns == nil, "nothing needs reading: the columns are there")

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
        t.equal(unread.pendingColumns, ObjectReference(schema: "dbo", name: "DeliveryVendor"),
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
        t.expect(answered.pendingColumns == nil, "with nothing left to read")

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
