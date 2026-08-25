import Foundation
import TDSKit

// MARK: - Models

/// One file handed to `CREATE DATABASE ... FOR ATTACH`.
///
/// `path` is always a path on the server's filesystem. The engine opens the file itself,
/// so a path that exists on the Mac running this app is meaningless unless the server
/// happens to be the same machine.
public struct AttachableFile: Sendable, Hashable, Identifiable {

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case data = "ROWS"
        case log = "LOG"
        case filestream = "FILESTREAM"

        public var title: String {
            switch self {
            case .data: return "Data"
            case .log: return "Log"
            case .filestream: return "FILESTREAM"
            }
        }

        /// Maps `sys.database_files.type_desc` onto the three kinds attach cares about.
        public init(typeDesc: String) {
            switch typeDesc.uppercased() {
            case "LOG": self = .log
            case "FILESTREAM", "FILESTREAM_DATA": self = .filestream
            default: self = .data
            }
        }
    }

    public var id: String { "\(type.rawValue)|\(path)" }

    public var path: String
    public var type: Kind
    /// The name the file carries inside the database, e.g. `AdventureWorks_Log`. Attach
    /// does not need it, but SSMS shows it so the user can tell two .ndf files apart.
    public var logicalName: String

    public init(path: String, type: Kind = .data, logicalName: String = "") {
        self.path = path
        self.type = type
        self.logicalName = logicalName
    }
}

// MARK: - Database tasks

/// Everything SSMS collects under Database > Tasks: detach, attach, shrink, take
/// offline and online, rename, integrity checks and the disk usage report.
///
/// The script-producing members are pure so a dialog can show the exact T-SQL before
/// anything is sent; `runScript(_:database:)` executes what was shown.
public struct DatabaseTasks: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Detach

    public func detachScript(database: String,
                             dropConnections: Bool,
                             updateStatistics: Bool) -> String {
        let statements = detachStatements(database: database,
                                          dropConnections: dropConnections,
                                          updateStatistics: updateStatistics)
        return Self.script(useDatabase: "master", statements: statements)
    }

    public func detach(database: String,
                       dropConnections: Bool,
                       updateStatistics: Bool) async throws {
        try await requireNonAzure("Detaching a database")
        let statements = detachStatements(database: database,
                                          dropConnections: dropConnections,
                                          updateStatistics: updateStatistics)
        // Detach runs from master: the connection issuing it must not be inside the
        // database, and SINGLE_USER would otherwise disconnect us before sp_detach_db.
        do {
            for statement in statements {
                try await run(statement, database: "master")
            }
        } catch {
            if dropConnections {
                // A half-finished detach leaves the database in single user mode, which
                // locks everyone out until someone notices. Put it back before rethrowing.
                let restore = "ALTER DATABASE \(SQLIdentifier.quote(database)) SET MULTI_USER;"
                try? await run(restore, database: "master")
            }
            throw error
        }
    }

    private func detachStatements(database: String,
                                  dropConnections: Bool,
                                  updateStatistics: Bool) -> [String] {
        var statements: [String] = []
        if dropConnections {
            let name = SQLIdentifier.quote(database)
            statements.append("ALTER DATABASE \(name) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;")
        }
        // sp_detach_db's @skipchecks is inverted: 'false' means "do run UPDATE STATISTICS".
        let skipChecks = updateStatistics ? "false" : "true"
        let call = "EXEC master.dbo.sp_detach_db @dbname = \(SQLIdentifier.literal(database)),"
            + " @skipchecks = \(SQLIdentifier.literal(skipChecks));"
        statements.append(call)
        return statements
    }

    // MARK: - Attach

    public func attachScript(databaseName: String, files: [AttachableFile]) -> String {
        let usable = Self.usableFiles(files)
        guard !usable.isEmpty else {
            return "-- Add the primary data file (.mdf) before generating an attach script.\n"
        }
        let statement = Self.attachStatement(databaseName: databaseName, files: usable)
        return Self.script(useDatabase: "master", statements: [statement])
    }

    public func attach(databaseName: String, files: [AttachableFile]) async throws {
        try await requireNonAzure("Attaching a database")
        let name = databaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SQLServerError.unsupportedOperation("Attach needs a name for the database.")
        }
        let usable = Self.usableFiles(files)
        guard !usable.isEmpty else {
            throw SQLServerError.unsupportedOperation(
                "Attach needs at least the primary data file (.mdf).")
        }
        let statement = Self.attachStatement(databaseName: name, files: usable)
        try await run(statement, database: "master")
    }

    private static func attachStatement(databaseName: String, files: [AttachableFile]) -> String {
        let specs: [String] = files.map { file in
            "    ( FILENAME = \(SQLIdentifier.literal(file.path)) )"
        }
        // With no log file in the list the engine has to build a fresh one, and that is a
        // different terminating clause rather than an option on FOR ATTACH.
        let hasLog: Bool = files.contains { $0.type == .log }
        let clause: String = hasLog ? "FOR ATTACH" : "FOR ATTACH_REBUILD_LOG"
        let header = "CREATE DATABASE \(SQLIdentifier.quote(databaseName)) ON"
        return "\(header)\n\(specs.joined(separator: ",\n"))\n\(clause);"
    }

    private static func usableFiles(_ files: [AttachableFile]) -> [AttachableFile] {
        files.compactMap { file in
            let path = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return AttachableFile(path: path, type: file.type, logicalName: file.logicalName)
        }
    }

    /// The files that make up a database, in file_id order, ready to be fed back to attach.
    public func filesFor(database: String) async throws -> [AttachableFile] {
        let info = await session.serverInfo
        let sql: String
        let context: String
        if info.isAzureSQLDatabase {
            // sys.master_files is not readable on Azure SQL Database; the per-database
            // catalog view is, from inside the database itself.
            sql = """
            SELECT f.name         AS LogicalName,
                   f.physical_name AS PhysicalName,
                   f.type_desc     AS TypeDesc
            FROM sys.database_files AS f
            ORDER BY f.file_id;
            """
            context = database
        } else {
            sql = """
            SELECT f.name          AS LogicalName,
                   f.physical_name AS PhysicalName,
                   f.type_desc     AS TypeDesc
            FROM sys.master_files AS f
            INNER JOIN sys.databases AS d ON d.database_id = f.database_id
            WHERE d.name = \(SQLIdentifier.literal(database))
            ORDER BY f.file_id;
            """
            context = "master"
        }

        let rows = try await self.rows(sql, database: context)
        return rows.map { row in
            AttachableFile(path: row.string("PhysicalName"),
                           type: AttachableFile.Kind(typeDesc: row.string("TypeDesc")),
                           logicalName: row.string("LogicalName"))
        }
    }

    // MARK: - Shrink

    /// `releaseSpace` is SSMS's "Release unused space" choice: it truncates the free space
    /// at the end of each file without moving pages, and `targetPercent` no longer applies.
    public func shrinkDatabaseScript(_ database: String,
                                     targetPercent: Int,
                                     releaseSpace: Bool) -> String {
        let percent = min(max(targetPercent, 0), 99)
        let name = SQLIdentifier.literal(database)
        let statement: String
        if releaseSpace {
            statement = "DBCC SHRINKDATABASE (\(name), TRUNCATEONLY);"
        } else {
            statement = "DBCC SHRINKDATABASE (\(name), \(percent));"
        }
        return Self.script(useDatabase: database, statements: [statement])
    }

    /// `targetMB` is the size the file should end up at; 0 means "as small as possible".
    public func shrinkFileScript(database: String, logicalName: String, targetMB: Int) -> String {
        let target = max(targetMB, 0)
        let file = SQLIdentifier.literal(logicalName)
        return Self.script(useDatabase: database,
                           statements: ["DBCC SHRINKFILE (\(file), \(target));"])
    }

    // MARK: - Online state

    public func setOffline(database: String, rollbackImmediate: Bool) async throws {
        try await requireNonAzure("Taking a database offline")
        let rollback = rollbackImmediate ? " WITH ROLLBACK IMMEDIATE" : ""
        let sql = "ALTER DATABASE \(SQLIdentifier.quote(database)) SET OFFLINE\(rollback);"
        try await run(sql, database: "master")
    }

    public func setOnline(database: String) async throws {
        try await requireNonAzure("Bringing a database online")
        let sql = "ALTER DATABASE \(SQLIdentifier.quote(database)) SET ONLINE;"
        try await run(sql, database: "master")
    }

    // MARK: - Rename

    public func renameScript(database: String, newName: String) -> String {
        let master = SQLIdentifier.quote("master")
        let old = SQLIdentifier.quote(database)
        let new = SQLIdentifier.quote(newName)
        return """
        USE \(master);
        GO
        -- MODIFY NAME needs exclusive access, so every other session is disconnected first.
        ALTER DATABASE \(old) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        GO
        ALTER DATABASE \(old) MODIFY NAME = \(new);
        GO
        ALTER DATABASE \(new) SET MULTI_USER;
        GO

        """
    }

    // MARK: - Integrity

    /// DBCC CHECKDB / CHECKTABLE output lines. A clean run reports a single summary line.
    public func checkIntegrity(database: String, table: String?) async throws -> [String] {
        let info = await session.serverInfo
        let trimmedTable = table?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let sql: String
        let context: String
        if !trimmedTable.isEmpty {
            // CHECKTABLE takes no database argument, so it has to run inside the database.
            sql = "DBCC CHECKTABLE (\(Self.tableTarget(trimmedTable))) WITH NO_INFOMSGS;"
            context = database
        } else if info.isAzureSQLDatabase {
            // Azure SQL Database only ever checks the database the connection is in.
            sql = "DBCC CHECKDB WITH NO_INFOMSGS;"
            context = database
        } else {
            sql = "DBCC CHECKDB (\(SQLIdentifier.literal(database))) WITH NO_INFOMSGS;"
            context = "master"
        }

        // Corruption is reported as severity 16 messages, so the run must not throw them
        // away: the whole point of the check is to show the user what DBCC found.
        let lines = try await collectMessages(sql, database: context)
        guard lines.isEmpty else { return lines }
        let target = trimmedTable.isEmpty ? "'\(database)'" : "'\(trimmedTable)' in '\(database)'"
        return ["DBCC completed. No integrity errors were reported for \(target)."]
    }

    /// `dbo.Person` becomes `N'[dbo].[Person]'`; a bare name is quoted as written.
    private static func tableTarget(_ table: String) -> String {
        guard let separator = table.firstIndex(of: ".") else {
            return SQLIdentifier.literal(SQLIdentifier.quote(table))
        }
        let schema = String(table[table.startIndex..<separator])
        let name = String(table[table.index(after: separator)...])
        return SQLIdentifier.literal(SQLIdentifier.quote(schema: schema, name: name))
    }

    // MARK: - Disk usage

    /// The Disk Usage report: the sp_spaceused summary followed by a line per file.
    public func diskUsage(database: String) async throws -> [(name: String, value: String)] {
        var report: [(name: String, value: String)] = []

        // sp_spaceused returns two result sets whose column names differ between
        // versions, so the labels are taken from the columns rather than hard coded.
        let summary = try await session.metadataQuery("EXEC sys.sp_spaceused;", database: database)
        if let failure = summary.errors.first { throw failure }
        for set in summary.resultSets {
            guard let row = set.rows.first else { continue }
            for (column, value) in zip(set.columns, row) {
                let text = value.displayString(nullText: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                report.append((name: Self.humanized(column.name), value: text))
            }
        }

        let fileSQL = """
        SELECT f.name                                              AS LogicalName,
               f.type_desc                                         AS TypeDesc,
               CAST(f.size AS bigint)                              AS SizePages,
               CAST(ISNULL(FILEPROPERTY(f.name, 'SpaceUsed'), 0) AS bigint) AS UsedPages,
               f.physical_name                                     AS PhysicalName
        FROM sys.database_files AS f
        ORDER BY f.file_id;
        """
        let fileRows = try await rows(fileSQL, database: database)
        for row in fileRows {
            let logical = row.string("LogicalName")
            let kind = AttachableFile.Kind(typeDesc: row.string("TypeDesc"))
            let sizeMB = Self.megabytes(pages: row.int64("SizePages"))
            let usedMB = Self.megabytes(pages: row.int64("UsedPages"))
            let percent = sizeMB > 0 ? (usedMB / sizeMB) * 100 : 0
            let value = String(format: "%.2f MB used of %.2f MB (%.0f%%)", usedMB, sizeMB, percent)
            report.append((name: "File \(logical) (\(kind.title))", value: value))
        }

        return report
    }

    // MARK: - Script execution

    /// Runs a generated script batch by batch on one connection and returns every line the
    /// server printed. DBCC and sp_detach_db report through messages, not result sets, so
    /// the sink is the only place their output appears.
    @discardableResult
    public func runScript(_ script: String, database: String?) async throws -> [String] {
        let batches = BatchSplitter.split(script).filter { !$0.isEmpty }
        guard !batches.isEmpty else { return [] }

        let collector = DatabaseTaskMessages()
        let connection = try await session.openConnection(database: database)
        do {
            for batch in batches {
                let repeats = max(batch.repeatCount, 1)
                for _ in 0..<repeats {
                    try await connection.execute(batch.text) { event in
                        switch event {
                        case .info(let message), .error(let message):
                            collector.append(message)
                        default:
                            break
                        }
                    }
                    // execute() only streams errors, so a failed batch has to be caught
                    // here before the next one runs against a half-changed database.
                    if let fatal = collector.fatal { throw fatal }
                }
            }
            try? await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
        return collector.lines
    }

    /// Like `runScript` but keeps going through server errors and returns them as text.
    private func collectMessages(_ sql: String, database: String?) async throws -> [String] {
        let collector = DatabaseTaskMessages()
        let connection = try await session.openConnection(database: database)
        do {
            try await connection.execute(sql) { event in
                switch event {
                case .info(let message), .error(let message):
                    collector.append(message)
                default:
                    break
                }
            }
            try? await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
        return collector.lines
    }

    // MARK: - Helpers

    private func requireNonAzure(_ operation: String) async throws {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else {
            throw SQLServerError.unsupportedOperation(
                "\(operation) is not supported on Azure SQL Database. Azure SQL Database has no "
                + "user visible database files, so detach, attach and offline have no meaning "
                + "there; copy the database or export a BACPAC instead.")
        }
    }

    private func rows(_ sql: String, database: String?) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }

    /// Maintenance runs long, so it gets a connection of its own and leaves the Object
    /// Explorer's shared metadata connection responsive.
    @discardableResult
    private func run(_ sql: String, database: String?) async throws -> TDSQueryResult {
        let connection = try await session.openConnection(database: database)
        do {
            let result = try await connection.query(sql)
            try? await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }

    private static func script(useDatabase: String, statements: [String]) -> String {
        var lines: [String] = ["USE \(SQLIdentifier.quote(useDatabase));", "GO"]
        for statement in statements {
            lines.append(statement)
            lines.append("GO")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func megabytes(pages: Int64) -> Double {
        Double(pages) * 8.0 / 1024.0
    }

    /// `index_size` becomes `Index size`, `unallocated space` becomes `Unallocated space`.
    private static func humanized(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return raw }
        return String(first).uppercased() + spaced.dropFirst()
    }
}

// MARK: - Message collection

/// DBCC and sp_detach_db report through info and error tokens rather than result sets,
/// and the stream sink is called off the caller's isolation, so the buffer needs a lock.
private final class DatabaseTaskMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private var firstFatal: TDSServerMessage?

    func append(_ message: TDSServerMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        // Severity 11 and above is what SQL Server treats as an error the client must see.
        if message.severity >= 11, firstFatal == nil { firstFatal = message }
        if !text.isEmpty { buffer.append(text) }
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    var fatal: TDSServerMessage? {
        lock.lock()
        defer { lock.unlock() }
        return firstFatal
    }
}
