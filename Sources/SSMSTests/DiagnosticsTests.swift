import Foundation
import TDSKit
import SQLServerKit

/// Offline checks for the diagnostics services: Query Store, the error log viewer and the
/// blocking chain builder. Everything here is pure — no server is involved.
func runDiagnosticsTests(_ t: TestRunner) {

    // MARK: - Query Store

    t.suite("query store state scripts") {
        t.equal(try? QueryStoreService.setStateScript(database: "Sales", state: "read_write"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);",
                "read write")
        t.equal(try? QueryStoreService.setStateScript(database: "Sales", state: "READ ONLY"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = ON (OPERATION_MODE = READ_ONLY);",
                "a space is accepted where the underscore goes")
        t.equal(try? QueryStoreService.setStateScript(database: "Sales", state: "off"),
                "ALTER DATABASE [Sales] SET QUERY_STORE = OFF;", "off has no options clause")
        t.equal(try? QueryStoreService.setStateScript(database: "we]rd", state: "off"),
                "ALTER DATABASE [we]]rd] SET QUERY_STORE = OFF;",
                "the database name goes through the identifier quoter")

        // Azure SQL Database has no cross-database ALTER and no reachable master.
        t.equal(try? QueryStoreService.setStateScript(database: "Sales", state: "READ_WRITE",
                                                     useCurrentDatabase: true),
                "ALTER DATABASE CURRENT SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);",
                "Azure uses ALTER DATABASE CURRENT")
        t.equal(QueryStoreService.clearScript(database: "Sales"),
                "ALTER DATABASE [Sales] SET QUERY_STORE CLEAR ALL;", "clear")
        t.equal(QueryStoreService.clearScript(database: "Sales", useCurrentDatabase: true),
                "ALTER DATABASE CURRENT SET QUERY_STORE CLEAR ALL;", "clear on Azure")

        // The state is interpolated, not parameterised, so anything unrecognised has to be
        // refused rather than passed through.
        for bad in ["ON; DROP DATABASE Sales", "", "READWRITE", "READ_ONLY)"] {
            var rejected = false
            do { _ = try QueryStoreService.setStateScript(database: "Sales", state: bad) }
            catch { rejected = true }
            t.expect(rejected, "'\(bad)' is refused")
        }
    }

    t.suite("query store models") {
        var options = QueryStoreOptions(actualState: "READ_WRITE",
                                        currentStorageMB: 50, maxStorageMB: 200)
        t.expect(options.isEnabled, "READ_WRITE is enabled")
        t.equal(options.usedPercent, 25, "a quarter of the storage is used")

        options.currentStorageMB = 400
        t.equal(options.usedPercent, 100, "a store past its limit clamps at 100")

        options.maxStorageMB = 0
        t.equal(options.usedPercent, 0, "no maximum means no percentage")

        options.actualState = "OFF"
        t.expect(!options.isEnabled, "OFF is not enabled")
        options.actualState = "READ_ONLY"
        t.expect(options.isEnabled, "read-only still counts as enabled")

        let regression = QueryStoreRegression(recentAverage: 150, baselineAverage: 100)
        t.equal(regression.changePercent, 50, "50 percent worse")
        t.equal(QueryStoreRegression(recentAverage: 10, baselineAverage: 0).changePercent, 0,
                "no baseline means no change figure")

        t.expect(QueryStoreMetric.duration.isMicroseconds, "duration is microseconds")
        t.expect(QueryStoreMetric.cpuTime.isMicroseconds, "CPU time is microseconds")
        t.expect(!QueryStoreMetric.logicalReads.isMicroseconds, "reads are page counts")
        t.equal(QueryStoreMetric.duration.unit, "ms", "duration reports milliseconds")
        t.equal(QueryStoreMetric.executionCount.unit, "", "a count has no unit")

        // Execution count is a total, so there is nothing to regress against.
        t.expect(QueryStoreMetric.executionCount.regressionMetric == .duration,
                 "the regression report falls back to duration for execution count")
        t.expect(QueryStoreMetric.cpuTime.regressionMetric == .cpuTime,
                 "every other metric regresses against itself")
        t.equal(QueryStoreMetric.allCases.count, 7, "seven metrics")
        t.expect(Set(QueryStoreMetric.allCases.map(\.title)).count == 7, "titles are distinct")
    }

    // MARK: - Blocking chains

    t.suite("blocking chains") {
        func session(_ id: Int, blockedBy: Int = 0) -> ActivitySession {
            ActivitySession(sessionID: id, loginName: "u\(id)", status: "suspended",
                            blockingSessionID: blockedBy)
        }

        t.equal(BlockingChain.build(from: []).count, 0, "no sessions, no tree")
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

        // A blocker that is not in the input still has to appear, or its waiter vanishes.
        let orphan = BlockingChain.build(from: [session(61, blockedBy: 99)])
        t.equal(orphan.count, 1, "a missing blocker becomes a placeholder root")
        t.equal(orphan.first?.session.sessionID, 99, "with the blocker's own spid")
        t.equal(orphan.first?.session.status, "gone", "and a status that says so")
        t.equal(orphan.first?.children.first?.session.sessionID, 61, "its waiter sits beneath it")

        // A cycle must not lose anyone and must not loop forever.
        let cycle = BlockingChain.build(from: [session(70, blockedBy: 71),
                                              session(71, blockedBy: 70)])
        t.equal(BlockingChain.rows(from: cycle).count, 2, "both members of a cycle are reported")

        // Self-blocking is a parallel query waiting on its own siblings, not a chain.
        t.equal(BlockingChain.build(from: [session(80, blockedBy: 80)]).count, 0,
                "a session blocked by itself is not a chain")

        // Two independent chains, so the worst offender has to be picked by size.
        let two = sessions + [session(90), session(91, blockedBy: 90)]
        t.equal(BlockingChain.build(from: two).count, 2, "two separate chains")
        t.equal(BlockingChain.worstOffender(in: BlockingChain.build(from: two))?
            .session.sessionID, 50, "the worst offender holds up the most sessions")
        t.expect(BlockingChain.worstOffender(in: []) == nil, "no chains, no offender")

        // A long single chain beats a wide shallow one on tie-broken chain length.
        let deep = [session(10), session(11, blockedBy: 10), session(12, blockedBy: 11),
                    session(20), session(21, blockedBy: 20), session(22, blockedBy: 20)]
        let deepRoots = BlockingChain.build(from: deep)
        t.equal(deepRoots.count, 2, "two chains")
        t.equal(deepRoots.first { $0.session.sessionID == 10 }?.chainLength, 3, "three deep")
        t.equal(deepRoots.first { $0.session.sessionID == 20 }?.chainLength, 2, "two deep")
    }

    // MARK: - Error log

    t.suite("error log classification") {
        func severity(_ message: String) -> ServerLogEntry.Severity {
            ServerLogEntry(id: 0, loggedAt: "", source: "spid1", message: message).severity
        }
        t.expect(severity("Error: 18456, Severity: 14, State: 1.") == .error, "an error line")
        t.expect(severity("Login failed for user 'sa'.") == .error, "a failure")
        t.expect(severity("Cannot open database \"Sales\".") == .error, "cannot")
        t.expect(severity("Warning: The join order has been enforced.") == .warning, "a warning")
        t.expect(severity("Could not connect to the availability replica.") == .warning,
                 "could not is a warning")
        t.expect(severity("Using 'dbghelp.dll' — this feature is deprecated.") == .warning,
                 "deprecation is a warning")
        t.expect(severity("SQL Server is now ready for client connections.") == .information,
                 "a plain message is information")
        t.expect(severity("") == .information, "an empty line is information")

        t.equal(ServerLogEntry.Severity.error.symbol, "xmark.octagon.fill", "error symbol")
        t.equal(ServerLogEntry.Severity.information.symbol, "info.circle", "information symbol")

        let archive = ServerLogArchive(number: 0)
        t.equal(archive.title, "Current", "archive zero is the current log")
        t.equal(ServerLogArchive(number: 3).title, "Archive #3", "older logs are numbered")

        t.equal(ServerLogKind.sqlServer.rawValue, 1,
                "sp_readerrorlog takes 1 for the SQL Server log")
        t.equal(ServerLogKind.sqlAgent.rawValue, 2, "and 2 for the Agent log")
        t.equal(ServerLogKind.allCases.count, 2, "two logs")
    }
}
