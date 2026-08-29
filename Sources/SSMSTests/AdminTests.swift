import Foundation
import TDSKit
import SQLServerKit

/// Offline checks for the administration, scripting and results-to-text logic added on
/// top of the original suite. Everything here is pure: no server is involved.
func runAdminTests(_ t: TestRunner) {

    // MARK: - Rename

    t.suite("rename scripting") {
        let script = try? ObjectAdmin.renameScript(objectType: "OBJECT", schema: "dbo",
                                                  parent: nil, currentName: "Orders",
                                                  newName: "SalesOrders")
        t.equal(script, "EXEC sys.sp_rename N'[dbo].[Orders]', N'SalesOrders', N'OBJECT';",
                "table rename quotes the old name and leaves the new one bare")

        let column = try? ObjectAdmin.renameScript(objectType: "COLUMN", schema: "dbo",
                                                  parent: "Orders", currentName: "Qty",
                                                  newName: "Quantity")
        t.equal(column, "EXEC sys.sp_rename N'[dbo].[Orders].[Qty]', N'Quantity', N'COLUMN';",
                "a column rename is qualified by its table")

        let quoted = try? ObjectAdmin.renameScript(objectType: "OBJECT", schema: "my's",
                                                  parent: nil, currentName: "a]b",
                                                  newName: "c")
        t.equal(quoted, "EXEC sys.sp_rename N'[my''s].[a]]b]', N'c', N'OBJECT';",
                "brackets are doubled and the literal's quotes escaped")

        var rejected = false
        do {
            _ = try ObjectAdmin.renameScript(objectType: "OBJECT", schema: "dbo", parent: nil,
                                             currentName: "T", newName: "dbo.T2")
        } catch { rejected = true }
        t.expect(rejected, "a qualified new name is rejected")

        rejected = false
        do {
            _ = try ObjectAdmin.renameScript(objectType: "OBJECT", schema: "dbo", parent: nil,
                                             currentName: "T", newName: "   ")
        } catch { rejected = true }
        t.expect(rejected, "an empty new name is rejected")

        t.equal(ObjectAdmin.renameObjectType(for: .table), "OBJECT", "tables rename as OBJECT")
        t.equal(ObjectAdmin.renameObjectType(for: .column), "COLUMN", "columns rename as COLUMN")
        t.equal(ObjectAdmin.renameObjectType(for: .index), "INDEX", "indexes rename as INDEX")
        t.expect(ObjectAdmin.renameObjectType(for: .databaseFile) == nil,
                 "a database file cannot be renamed with sp_rename")

        // sp_rename cannot rename a database, so that node takes a different statement.
        t.expect(ObjectAdmin.renameObjectType(for: .database) == nil,
                 "a database is not an sp_rename target")
        t.expect(ObjectAdmin.canRename(.database), "but the dialog can still rename it")
        t.expect(!ObjectAdmin.canRename(.databaseFile), "a database file cannot be renamed")
        t.equal(try? ObjectAdmin.renameDatabaseScript(from: "Sales", to: "SalesArchive"),
                "ALTER DATABASE [Sales] MODIFY NAME = [SalesArchive];",
                "a database renames through ALTER DATABASE")

        let databaseNode = ObjectExplorerNode(id: "db", kind: .database, label: "Sales",
                                              iconName: "cylinder", isExpandable: true,
                                              database: "Sales", name: "Sales")
        t.equal(try? ObjectAdmin.renameScript(node: databaseNode, to: "SalesArchive"),
                "ALTER DATABASE [Sales] MODIFY NAME = [SalesArchive];",
                "the node overload routes a database correctly")

        let columnNode = ObjectExplorerNode(id: "c", kind: .column, label: "Qty",
                                            iconName: "doc", isExpandable: false,
                                            database: "Sales", schema: "dbo", name: "Qty",
                                            info: ["parentTable": "Orders"])
        t.equal(try? ObjectAdmin.renameScript(node: columnNode, to: "Quantity"),
                "EXEC sys.sp_rename N'[dbo].[Orders].[Qty]', N'Quantity', N'COLUMN';",
                "the node overload picks up the parent table for a column")
    }

    // MARK: - Drop

    t.suite("drop scripting") {
        func node(_ kind: ObjectNodeKind, schema: String? = "dbo", name: String,
                  info: [String: String] = [:]) -> ObjectExplorerNode {
            ObjectExplorerNode(id: "n/\(name)", kind: kind, label: name, iconName: "doc",
                               isExpandable: false, database: "Sales", schema: schema,
                               name: name, info: info)
        }

        t.equal(try? ObjectAdmin.dropScript(node: node(.table, name: "Orders")),
                "DROP TABLE [dbo].[Orders];", "table")
        t.equal(try? ObjectAdmin.dropScript(node: node(.storedProcedure, name: "p")),
                "DROP PROCEDURE [dbo].[p];", "procedure")
        t.equal(try? ObjectAdmin.dropScript(node: node(.login, schema: nil, name: "sa2")),
                "DROP LOGIN [sa2];", "a login has no schema")

        let index = node(.index, name: "IX_Orders_Date", info: ["parentTable": "Orders"])
        t.equal(try? ObjectAdmin.dropScript(node: index),
                "DROP INDEX [IX_Orders_Date] ON [dbo].[Orders];", "an index drops through its table")

        let key = node(.foreignKey, name: "FK_A_B", info: ["parentTable": "Orders"])
        t.equal(try? ObjectAdmin.dropScript(node: key),
                "ALTER TABLE [dbo].[Orders]\n    DROP CONSTRAINT [FK_A_B];",
                "a constraint drops through ALTER TABLE")

        var failed = false
        do { _ = try ObjectAdmin.dropScript(node: node(.index, name: "IX")) } catch { failed = true }
        t.expect(failed, "an index with no known table cannot be dropped")

        let database = ObjectExplorerNode(id: "db", kind: .database, label: "Sales",
                                          iconName: "cylinder", isExpandable: true,
                                          database: "Sales", name: "Sales")
        let dropDatabase = (try? ObjectAdmin.dropScript(node: database)) ?? ""
        t.expect(dropDatabase.contains("SET SINGLE_USER WITH ROLLBACK IMMEDIATE"),
                 "dropping a database kicks other sessions off first")
        t.equal(BatchSplitter.split(dropDatabase).count, 2, "the database drop is two batches")

        failed = false
        do { _ = try ObjectAdmin.dropScript(node: node(.parameter, name: "@p")) } catch { failed = true }
        t.expect(failed, "a parameter cannot be dropped on its own")
    }

    // MARK: - New database

    t.suite("create database scripting") {
        var options = NewDatabaseOptions(name: "Sales")
        var sql = (try? ObjectAdmin.createDatabaseScript(options)) ?? ""
        t.expect(sql.hasPrefix("CREATE DATABASE [Sales];"),
                 "with no paths the statement is just CREATE DATABASE")
        t.expect(!sql.contains("ON PRIMARY"), "no file clause without a path")

        options.dataFilePath = "/var/opt/mssql/data/Sales.mdf"
        options.logFilePath = "/var/opt/mssql/data/Sales_log.ldf"
        options.dataFileSizeMB = 128
        options.dataFileGrowthMB = 64
        options.dataFileMaxSizeMB = 0
        options.recoveryModel = "simple"
        options.compatibilityLevel = 160
        options.owner = "sa"
        sql = (try? ObjectAdmin.createDatabaseScript(options)) ?? ""
        t.expect(sql.contains("NAME = [Sales]"), "the data file is named after the database")
        t.expect(sql.contains("NAME = [Sales_log]"), "the log file gets the _log suffix")
        t.expect(sql.contains("SIZE = 128MB"), "size")
        t.expect(sql.contains("MAXSIZE = UNLIMITED"), "zero max size means unlimited")
        t.expect(sql.contains("FILEGROWTH = 64MB"), "growth")
        t.expect(sql.contains("SET RECOVERY SIMPLE"), "recovery model is upper cased")
        t.expect(sql.contains("SET COMPATIBILITY_LEVEL = 160"), "compatibility level")
        t.expect(sql.contains("ALTER AUTHORIZATION ON DATABASE::[Sales] TO [sa]"), "owner")
        t.expect(sql.contains("N'/var/opt/mssql/data/Sales.mdf'"), "the path is a literal")

        var rejected = false
        options.collation = "Latin1_General_CI_AS; DROP DATABASE x --"
        do { _ = try ObjectAdmin.createDatabaseScript(options) } catch { rejected = true }
        t.expect(rejected, "a collation that is not an identifier is rejected")

        options.collation = "Persian_100_CI_AS"
        t.expect(((try? ObjectAdmin.createDatabaseScript(options)) ?? "")
            .contains("COLLATE Persian_100_CI_AS"), "a real collation name is accepted")

        rejected = false
        do { _ = try ObjectAdmin.createDatabaseScript(NewDatabaseOptions(name: "  ")) }
        catch { rejected = true }
        t.expect(rejected, "a blank database name is rejected")
    }

    // MARK: - Detach, attach and shrink

    t.suite("detach attach shrink") {
        let detach = ObjectAdmin.detachScript(database: "Sales", dropConnections: true,
                                              updateStatistics: false)
        t.expect(detach.contains("SET SINGLE_USER WITH ROLLBACK IMMEDIATE"),
                 "dropping connections switches to single user first")
        t.expect(detach.contains("@skipchecks = 'true'"),
                 "not updating statistics means skipchecks is on")
        t.equal(BatchSplitter.split(detach).count, 2, "two batches")

        let quiet = ObjectAdmin.detachScript(database: "Sales", dropConnections: false,
                                             updateStatistics: true)
        t.expect(!quiet.contains("SINGLE_USER"), "connections are left alone when not asked")
        t.expect(quiet.contains("@skipchecks = 'false'"), "updating statistics clears skipchecks")

        let attach = (try? ObjectAdmin.attachScript(
            database: "Sales",
            files: [AttachFile(path: "/data/Sales.mdf"), AttachFile(path: "/data/Sales_log.ldf")]))
            ?? ""
        t.expect(attach.hasPrefix("CREATE DATABASE [Sales]"), "attach is a CREATE DATABASE")
        t.expect(attach.contains("FOR ATTACH"), "with FOR ATTACH")
        t.expect(attach.contains("N'/data/Sales_log.ldf'"), "every file is listed")

        var rejected = false
        do { _ = try ObjectAdmin.attachScript(database: "Sales", files: []) } catch { rejected = true }
        t.expect(rejected, "attaching with no files is rejected")

        t.equal(ObjectAdmin.shrinkFileScript(logicalName: "Sales", targetMB: 64, mode: .reorganize),
                "DBCC SHRINKFILE (N'Sales', 64);", "shrink to a target size")
        t.equal(ObjectAdmin.shrinkFileScript(logicalName: "Sales_log", targetMB: 0,
                                             mode: .truncateOnly),
                "DBCC SHRINKFILE (N'Sales_log', TRUNCATEONLY);", "truncate only")
        t.equal(ObjectAdmin.shrinkFileScript(logicalName: "Old", targetMB: 0, mode: .emptyFile),
                "DBCC SHRINKFILE (N'Old', EMPTYFILE);", "empty file")
        t.equal(ObjectAdmin.shrinkFileScript(logicalName: "Sales", targetMB: -5, mode: .reorganize),
                "DBCC SHRINKFILE (N'Sales', 0);", "a negative target clamps to zero")
    }

    // MARK: - Permissions

    t.suite("permission statements") {
        t.equal(PermissionTarget.database.onClause, "", "a database permission has no ON clause")
        t.equal(PermissionTarget.server.onClause, "", "a server permission has no ON clause")
        t.equal(PermissionTarget.schema("Sales").onClause, " ON SCHEMA::[Sales]", "schema scope")
        t.equal(PermissionTarget.object(schema: "dbo", name: "Orders").onClause,
                " ON OBJECT::[dbo].[Orders]", "object scope")

        t.equal(try? ObjectAdmin.permissionStatement(
            action: .grant, permission: "select",
            on: .object(schema: "dbo", name: "Orders"), to: "reporting"),
                "GRANT SELECT ON OBJECT::[dbo].[Orders] TO [reporting];",
                "grant upper cases the permission and quotes the principal")

        t.equal(try? ObjectAdmin.permissionStatement(
            action: .grant, permission: "VIEW DEFINITION", on: .database, to: "app",
            withGrantOption: true),
                "GRANT VIEW DEFINITION TO [app] WITH GRANT OPTION;",
                "a two word permission and the grant option")

        t.equal(try? ObjectAdmin.permissionStatement(
            action: .revoke, permission: "EXECUTE",
            on: .schema("dbo"), to: "app", cascade: true),
                "REVOKE EXECUTE ON SCHEMA::[dbo] FROM [app] CASCADE;",
                "revoke uses FROM and honours CASCADE")

        t.equal(try? ObjectAdmin.permissionStatement(
            action: .deny, permission: "DELETE",
            on: .object(schema: "dbo", name: "Orders"), to: "app", withGrantOption: true),
                "DENY DELETE ON OBJECT::[dbo].[Orders] TO [app];",
                "the grant option only applies to GRANT")

        for bad in ["SELECT; DROP TABLE x", "SELECT--", "", "SELECT  ALL", "SELECT_ALL",
                    "GRANT\nSELECT"] {
            var rejected = false
            do {
                _ = try ObjectAdmin.permissionStatement(action: .grant, permission: bad,
                                                        on: .database, to: "app")
            } catch { rejected = true }
            t.expect(rejected, "'\(bad)' is not accepted as a permission name")
        }

        var rejected = false
        do {
            _ = try ObjectAdmin.permissionStatement(action: .grant, permission: "SELECT",
                                                    on: .database, to: " ")
        } catch { rejected = true }
        t.expect(rejected, "a blank principal is rejected")
    }

    // MARK: - Blocking chains

    t.suite("blocking chains") {
        func session(_ id: Int, blockedBy: Int = 0) -> ActivitySession {
            ActivitySession(sessionID: id, loginName: "u\(id)", status: "suspended",
                            blockingSessionID: blockedBy)
        }

        t.equal(BlockingChain.build(from: [session(51), session(52)]).count, 0,
                "nothing is blocked, so there is no tree")

        // 50 blocks 51 and 52; 51 blocks 53.
        let sessions = [session(50), session(51, blockedBy: 50),
                        session(52, blockedBy: 50), session(53, blockedBy: 51)]
        let roots = BlockingChain.build(from: sessions)
        t.equal(roots.count, 1, "one chain")
        t.equal(roots.first?.session.sessionID, 50, "the head is the session nothing waits on")
        t.equal(roots.first?.children.count, 2, "two direct waiters")
        t.equal(roots.first?.descendantCount, 3, "three sessions are held up")
        t.equal(roots.first?.chainLength, 3, "the longest path is three deep")

        let rows = BlockingChain.rows(from: roots)
        t.equal(rows.count, 4, "every session appears once")
        t.equal(rows.map(\.session.sessionID), [50, 51, 53, 52],
                "the walk is depth first in spid order")
        t.equal(rows.map(\.depth), [0, 1, 2, 1], "depth tracks the position in the chain")
        t.expect(rows.first?.isHead == true, "the head is flagged")
        t.expect(rows.dropFirst().allSatisfy { !$0.isHead }, "nothing else is")

        // A blocker that is not in the list still has to appear, or its waiter vanishes.
        let orphan = BlockingChain.build(from: [session(61, blockedBy: 99)])
        t.equal(orphan.count, 1, "a missing blocker becomes a placeholder root")
        t.equal(orphan.first?.session.sessionID, 99, "with the blocker's own spid")
        t.equal(orphan.first?.children.first?.session.sessionID, 61, "and its waiter beneath it")

        // A cycle must not lose anyone and must not loop forever.
        let cycle = BlockingChain.build(from: [session(70, blockedBy: 71),
                                              session(71, blockedBy: 70)])
        t.equal(BlockingChain.rows(from: cycle).count, 2, "both members of a cycle are reported")

        // Self-blocking is a parallel query waiting on its own siblings, not a chain.
        t.equal(BlockingChain.build(from: [session(80, blockedBy: 80)]).count, 0,
                "a session blocked by itself is not a chain")

        let worst = BlockingChain.worstOffender(in: BlockingChain.build(from: sessions + [
            session(90), session(91, blockedBy: 90)
        ]))
        t.equal(worst?.session.sessionID, 50, "the worst offender holds up the most sessions")
    }

    // MARK: - Agent schedules

    t.suite("agent schedule formatting") {
        t.equal(AgentScheduleFormatter.time(20000), "02:00:00", "HHMMSS integers")
        t.equal(AgentScheduleFormatter.time(235959), "23:59:59", "end of day")
        t.equal(AgentScheduleFormatter.time(0), "00:00:00", "midnight")
        t.equal(AgentScheduleFormatter.date(20260830), "2026-08-30", "yyyymmdd integers")
        t.equal(AgentScheduleFormatter.date(0), "", "no date")

        // Agent packs a duration as the integer HHMMSS, not as a count of seconds.
        t.equal(AgentScheduleFormatter.durationSeconds(fromAgentDuration: 13045), 5445,
                "013045 is one hour thirty minutes forty five seconds")
        t.equal(AgentScheduleFormatter.durationSeconds(fromAgentDuration: 100), 60,
                "000100 is one minute")
        t.equal(AgentScheduleFormatter.durationText(seconds: 5445), "01:30:45", "duration text")
        t.equal(AgentScheduleFormatter.durationText(seconds: 0), "", "a zero duration is blank")

        var text = AgentScheduleFormatter.describe(freqType: 1, freqInterval: 0,
                                                   freqRelativeInterval: 0,
                                                   freqRecurrenceFactor: 0,
                                                   activeStartTime: 90000, activeEndTime: 235959,
                                                   subdayType: 1, subdayInterval: 0)
        t.equal(text, "Occurs once at 09:00:00.", "one off")

        text = AgentScheduleFormatter.describe(freqType: 4, freqInterval: 1,
                                               freqRelativeInterval: 0, freqRecurrenceFactor: 0,
                                               activeStartTime: 20000, activeEndTime: 235959,
                                               subdayType: 1, subdayInterval: 0)
        t.equal(text, "Occurs every day at 02:00:00.", "daily at a time")

        text = AgentScheduleFormatter.describe(freqType: 4, freqInterval: 1,
                                               freqRelativeInterval: 0, freqRecurrenceFactor: 0,
                                               activeStartTime: 0, activeEndTime: 235959,
                                               subdayType: 4, subdayInterval: 15)
        t.expect(text.contains("every 15 minute(s) between 00:00:00 and 23:59:59"),
                 "sub-day intervals")

        // freq_interval is a weekday mask starting at Sunday = 1.
        text = AgentScheduleFormatter.describe(freqType: 8, freqInterval: 2 | 8,
                                               freqRelativeInterval: 0, freqRecurrenceFactor: 2,
                                               activeStartTime: 30000, activeEndTime: 235959,
                                               subdayType: 1, subdayInterval: 0)
        t.equal(text, "Occurs every 2 week(s) on Monday, Wednesday at 03:00:00.", "weekly mask")

        t.equal(AgentScheduleFormatter.describe(freqType: 8, freqInterval: 127,
                                                freqRelativeInterval: 0, freqRecurrenceFactor: 1,
                                                activeStartTime: 0, activeEndTime: 0,
                                                subdayType: 1, subdayInterval: 0),
                "Occurs every week on every day at 00:00:00.", "a full mask reads as every day")

        text = AgentScheduleFormatter.describe(freqType: 16, freqInterval: 15,
                                               freqRelativeInterval: 0, freqRecurrenceFactor: 1,
                                               activeStartTime: 40000, activeEndTime: 235959,
                                               subdayType: 1, subdayInterval: 0)
        t.expect(text.contains("on day 15"), "monthly by day of month")

        text = AgentScheduleFormatter.describe(freqType: 32, freqInterval: 6,
                                               freqRelativeInterval: 16, freqRecurrenceFactor: 3,
                                               activeStartTime: 233000, activeEndTime: 235959,
                                               subdayType: 1, subdayInterval: 0)
        t.expect(text.contains("on the last Friday"), "monthly relative")

        t.equal(AgentScheduleFormatter.describe(freqType: 64, freqInterval: 0,
                                                freqRelativeInterval: 0, freqRecurrenceFactor: 0,
                                                activeStartTime: 0, activeEndTime: 0,
                                                subdayType: 1, subdayInterval: 0),
                "Starts whenever SQL Server Agent starts.", "on agent start")
    }

    // MARK: - Script project ordering

    t.suite("generate scripts ordering") {
        func object(_ kind: ObjectNodeKind, _ name: String,
                    schema: String = "dbo") -> ScriptableObject {
            ScriptableObject(kind: kind, schema: schema, name: name)
        }

        let unordered = [object(.storedProcedure, "p1"), object(.table, "Orders"),
                         object(.view, "v1"), object(.schema, "Sales", schema: "Sales"),
                         object(.userDefinedTableType, "OrderList"), object(.trigger, "tr1")]
        let ordered = ScriptProject.ordered(unordered)
        let kinds = ordered.map(\.kind)
        t.equal(kinds.first, .schema, "schemas come first")
        t.equal(kinds.last, .trigger, "triggers come last")
        t.expect(kinds.firstIndex(of: .table)! < kinds.firstIndex(of: .view)!,
                 "tables precede views")
        t.expect(kinds.firstIndex(of: .userDefinedTableType)! < kinds.firstIndex(of: .table)!,
                 "table types precede the tables that use them")
        t.expect(kinds.firstIndex(of: .view)! < kinds.firstIndex(of: .storedProcedure)!,
                 "views precede procedures")
        t.equal(ordered.count, unordered.count, "nothing is dropped")

        // A view that selects from another view has to be created second.
        let views = [object(.view, "vTop"), object(.view, "vBase"), object(.view, "vMiddle")]
        let edges = [(from: "dbo.vTop", to: "dbo.vMiddle"), (from: "dbo.vMiddle", to: "dbo.vBase")]
        let sortedViews = ScriptProject.ordered(views, edges: edges).map(\.name)
        t.equal(sortedViews, ["vBase", "vMiddle", "vTop"], "dependencies order within a tier")

        // Alphabetical order is the tie break, so the output is reproducible.
        t.equal(ScriptProject.ordered([object(.table, "B"), object(.table, "A")]).map(\.name),
                ["A", "B"], "ties are broken alphabetically")

        // Two procedures that call each other are legal in SQL Server; neither may vanish.
        let recursive = [object(.storedProcedure, "pA"), object(.storedProcedure, "pB")]
        let cyclic = [(from: "dbo.pA", to: "dbo.pB"), (from: "dbo.pB", to: "dbo.pA")]
        t.equal(ScriptProject.ordered(recursive, edges: cyclic).count, 2,
                "a dependency cycle keeps both objects")

        // An edge pointing outside the selection must not strand anything.
        t.equal(ScriptProject.ordered([object(.view, "v1")],
                                      edges: [(from: "dbo.v1", to: "dbo.gone")]).count, 1,
                "an edge to an object that is not selected is ignored")
    }

    // MARK: - Results to text

    t.suite("results to text") {
        let columns = [
            TDSColumn(index: 0, name: "id", typeInfo: TDSTypeInfo(dataType: .int, length: 4)),
            TDSColumn(index: 1, name: "name",
                      typeInfo: TDSTypeInfo(dataType: .nVarChar, length: 100))
        ]
        let rows: [[TDSValue]] = [
            [.int(1), .string("Ada")],
            [.int(1000), .string("Grace Hopper")],
            [.null, .null]
        ]

        var options = TextResultOptions()
        options.lineEnding = "\n"
        let text = TextResultFormatter(options: options).format(columns: columns, rows: rows)
        let lines = text.components(separatedBy: "\n")

        t.equal(lines[0], "id   name", "headers are padded to the widest value")
        t.equal(lines[1], "---- ------------", "the rule matches the column widths")
        t.equal(lines[2], "   1 Ada", "numbers are right aligned")
        t.equal(lines[3], "1000 Grace Hopper", "the widest number sets the width")
        t.equal(lines[4], "NULL NULL", "nulls render as the null text")
        t.expect(text.contains("(3 rows affected)"), "the row count follows the rows")

        var narrow = TextResultOptions()
        narrow.lineEnding = "\n"
        narrow.maxColumnWidth = 5
        let clipped = TextResultFormatter(options: narrow)
            .format(columns: columns, rows: rows)
        t.expect(clipped.contains("Grace"), "a long value is truncated to the column cap")
        t.expect(!clipped.contains("Grace Hopper"), "and not printed in full")

        var single = TextResultOptions()
        single.lineEnding = "\n"
        let one = TextResultFormatter(options: single)
            .format(columns: columns, rows: [[.int(7), .string("x")]])
        t.expect(one.contains("(1 row affected)"), "one row is singular")

        var delimited = TextResultOptions()
        delimited.lineEnding = "\n"
        delimited.includeRowCount = false
        let tabbed = TextResultFormatter(options: delimited)
            .formatDelimited(columns: columns, rows: rows)
        t.equal(tabbed.components(separatedBy: "\n")[1], "1\tAda", "delimited mode does not pad")

        var empty = TextResultOptions()
        empty.lineEnding = "\n"
        t.expect(TextResultFormatter(options: empty).format(columns: [], rows: [])
            .contains("(0 rows affected)"), "no columns still reports a row count")
    }

    // MARK: - Template parameters

    t.suite("template parameters") {
        let script = """
        SELECT <select_list, nvarchar(max), *>
        FROM <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
        WHERE <search_condition, nvarchar(max), 1 = 1>
          AND a <> b
          AND c < d
        """
        let parameters = TemplateParameters.parse(script)
        t.equal(parameters.count, 4, "four placeholders")
        t.equal(parameters[0].name, "select_list", "name")
        t.equal(parameters[0].dataType, "nvarchar(max)", "type")
        t.equal(parameters[0].value, "*", "default value")
        t.equal(parameters[2].name, "table_name", "order follows the script")
        t.expect(!parameters.contains { $0.name.isEmpty }, "no empty names")
        t.expect(!parameters.contains { $0.name == "" || $0.name.contains("<") },
                 "an operator is never picked up as a parameter")

        let substituted = TemplateParameters.substitute(script, with: parameters.map {
            var copy = $0
            if copy.name == "table_name" { copy.value = "Orders" }
            return copy
        })
        t.expect(substituted.contains("[dbo]") == false, "substitution does not add brackets")
        t.expect(substituted.contains("dbo.Orders"), "the value replaces the placeholder")
        t.expect(substituted.contains("a <> b"), "a not-equals operator survives")
        t.expect(substituted.contains("c < d"), "a less-than survives")

        // A value containing commas belongs to the third field, not to a fourth.
        let commas = TemplateParameters.parse("AFTER <events, nvarchar(60), INSERT, UPDATE>")
        t.equal(commas.count, 1, "one parameter")
        t.equal(commas[0].value, "INSERT, UPDATE", "commas stay in the value")

        // An empty value keeps its placeholder so an unfilled field stays visible.
        let blank = TemplateParameters.parse("WHERE <Search Conditions,,>")
        t.equal(blank.count, 1, "an all-blank template still parses")
        t.equal(blank[0].name, "Search Conditions", "name with spaces")
        t.equal(TemplateParameters.substitute("WHERE <Search Conditions,,>", with: blank),
                "WHERE <Search Conditions,,>", "a blank value leaves the placeholder in place")

        // Repeated placeholders are listed once but replaced everywhere.
        let repeated = "SELECT <c, sysname, Id> FROM t ORDER BY <c, sysname, Id>"
        t.equal(TemplateParameters.parse(repeated).count, 1, "duplicates collapse")
        t.equal(TemplateParameters.substitute(repeated, with: TemplateParameters.parse(repeated)),
                "SELECT Id FROM t ORDER BY Id", "and every occurrence is replaced")

        t.equal(TemplateParameters.parse("SELECT 1").count, 0, "a script with no template fields")
        t.equal(TemplateParameters.parse("IF XACT_STATE() <> 0 ROLLBACK").count, 0,
                "an empty angle pair is not a parameter")
    }

    t.suite("template library") {
        t.expect(!TSQLTemplateLibrary.all.isEmpty, "the library is not empty")
        t.expect(TSQLTemplateLibrary.categories.count >= 6, "several categories")
        t.expect(Set(TSQLTemplateLibrary.all.map(\.id)).count == TSQLTemplateLibrary.all.count,
                 "template ids are unique")
        for template in TSQLTemplateLibrary.all {
            t.expect(!template.body.isEmpty, "\(template.id) has a body")
            // A malformed placeholder would be silently unfillable, so every template's
            // fields are checked to parse.
            for parameter in TemplateParameters.parse(template.body) {
                t.expect(!parameter.name.isEmpty, "\(template.id) parameter has a name")
            }
        }
        t.expect(!TSQLTemplateLibrary.templates(in: "Table").isEmpty, "the Table category")
        t.expect(TSQLTemplateLibrary.templates(in: "Nope").isEmpty, "an unknown category")
    }

    // MARK: - Server rates and uptime

    t.suite("server rates") {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var earlier = ServerSnapshot(capturedAt: start)
        earlier.batchRequestsTotal = 1000
        earlier.transactionsTotal = 500
        var later = ServerSnapshot(capturedAt: start.addingTimeInterval(10))
        later.batchRequestsTotal = 1200
        later.transactionsTotal = 700

        let rates = ServerRates.between(earlier, later)
        t.equal(rates.batchRequestsPerSecond, 20, "200 batches over 10 seconds")
        t.equal(rates.transactionsPerSecond, 20, "200 transactions over 10 seconds")
        t.equal(rates.interval, 10, "the interval is carried through")

        // A restart resets the counters; a negative delta must not become a negative rate.
        var restarted = ServerSnapshot(capturedAt: start.addingTimeInterval(20))
        restarted.batchRequestsTotal = 5
        t.equal(ServerRates.between(later, restarted).batchRequestsPerSecond, 0,
                "a counter that went backwards reports zero")

        t.equal(ServerRates.between(later, later).batchRequestsPerSecond, 0,
                "two readings at the same instant report zero")

        t.equal(ServerAdmin.uptimeText(minutes: 0), "", "no uptime")
        t.equal(ServerAdmin.uptimeText(minutes: 1), "1 minute", "one minute")
        t.equal(ServerAdmin.uptimeText(minutes: 90), "1 hour 30 minutes", "an hour and a half")
        t.equal(ServerAdmin.uptimeText(minutes: 1440 * 12 + 260), "12 days 4 hours",
                "days drop the minutes")
    }

    // MARK: - Query Store

    t.suite("query store") {
        t.equal(try? QueryStoreReports.setStateScript(database: "Sales", state: "read_write"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);",
                "read write")
        t.equal(try? QueryStoreReports.setStateScript(database: "Sales", state: "READ ONLY"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = ON (OPERATION_MODE = READ_ONLY);",
                "a space is accepted where the underscore goes")
        t.equal(try? QueryStoreReports.setStateScript(database: "Sales", state: "off"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = OFF;", "off has no options clause")
        t.equal(try? QueryStoreReports.setStateScript(database: "Sales", state: "READ_WRITE",
                                                     useCurrentDatabase: true),
                "ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);",
                "Azure SQL Database only accepts ALTER DATABASE CURRENT")

        var rejected = false
        do { _ = try QueryStoreReports.setStateScript(database: "Sales", state: "ON; DROP") }
        catch { rejected = true }
        t.expect(rejected, "an unknown state is rejected rather than interpolated")

        var options = QueryStoreOptions(actualState: "READ_WRITE",
                                        currentStorageSizeMB: 50, maxStorageSizeMB: 200)
        t.expect(options.isEnabled, "READ_WRITE is enabled")
        t.equal(options.usedPercent, 25, "a quarter of the storage is used")
        options.maxStorageSizeMB = 0
        t.equal(options.usedPercent, 0, "no maximum means no percentage")
        options.actualState = "OFF"
        t.expect(!options.isEnabled, "OFF is not enabled")

        let regression = QueryStoreRegression(recentAverage: 150, baselineAverage: 100)
        t.equal(regression.changePercent, 50, "50 percent worse")
        t.equal(QueryStoreRegression(recentAverage: 10, baselineAverage: 0).changePercent, 0,
                "no baseline means no change figure")

        t.expect(QueryStoreMetric.duration.isMicroseconds, "duration is microseconds")
        t.expect(!QueryStoreMetric.logicalReads.isMicroseconds, "reads are page counts")
    }

    // MARK: - Error log classification

    t.suite("error log classification") {
        func severity(_ message: String) -> ServerLogEntry.Severity {
            ServerLogEntry(id: 0, date: "", source: "spid1", message: message).severity
        }
        t.expect(severity("Error: 18456, Severity: 14, State: 1.") == .error, "an error line")
        t.expect(severity("Login failed for user 'sa'.") == .error, "a failure")
        t.expect(severity("Warning: The join order has been enforced.") == .warning, "a warning")
        t.expect(severity("Could not connect to the availability replica.") == .warning,
                 "could not is a warning")
        t.expect(severity("SQL Server is now ready for client connections.") == .information,
                 "a plain message is information")

        let archive = ServerLogArchive(archiveNumber: 0)
        t.equal(archive.title, "Current", "archive zero is the current log")
        t.equal(ServerLogArchive(archiveNumber: 3).title, "Archive #3", "older logs are numbered")
    }

    // MARK: - Dependencies

    t.suite("dependency node kinds") {
        func kind(_ type: String) -> ObjectNodeKind {
            ObjectDependency(dependencyType: type).nodeKind
        }
        t.expect(kind("U") == .table, "U is a table")
        t.expect(kind("V") == .view, "V is a view")
        t.expect(kind("P") == .storedProcedure, "P is a procedure")
        t.expect(kind("FN") == .scalarFunction, "FN is a scalar function")
        t.expect(kind("IF") == .tableValuedFunction, "IF is an inline table function")
        t.expect(kind("TR") == .trigger, "TR is a trigger")
        t.expect(kind("ZZ") == .unknown, "an unknown type stays unknown")

        let dependency = ObjectDependency(schema: "dbo", name: "Orders", dependencyType: "U")
        t.equal(dependency.qualifiedName, "dbo.Orders", "qualified name")
        t.equal(ObjectDependency(name: "Orders").qualifiedName, "Orders",
                "no schema means no prefix")
    }
}
