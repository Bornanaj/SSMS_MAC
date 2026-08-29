import Foundation

/// One template from the Template Explorer.
public struct TSQLTemplate: Sendable, Hashable, Identifiable {
    public var id: String { "\(category)/\(name)" }

    public var category: String
    public var name: String
    public var body: String

    public init(category: String, name: String, body: String) {
        self.category = category
        self.name = name
        self.body = body
    }
}

/// One `<name, type, value>` placeholder found in a script.
public struct TemplateParameter: Sendable, Hashable, Identifiable {
    public var id: String { placeholder }

    /// The full `<...>` text, which is what gets replaced.
    public var placeholder: String
    public var name: String
    public var dataType: String
    /// The default from the template, and the initial contents of the edit field.
    public var value: String

    public init(placeholder: String, name: String, dataType: String, value: String) {
        self.placeholder = placeholder
        self.name = name
        self.dataType = dataType
        self.value = value
    }
}

/// Reads and rewrites the `<name, type, value>` placeholders SSMS uses in templates and
/// in the scripts it generates for INSERT, UPDATE and EXEC.
///
/// The format is exactly three comma-separated parts, and the third may itself contain
/// commas — `<Columns, , 'a, b'>` is one parameter, not three — so the split is bounded
/// rather than greedy.
public enum TemplateParameters {

    /// Every distinct placeholder, in the order it first appears.
    public static func parse(_ script: String) -> [TemplateParameter] {
        var found: [TemplateParameter] = []
        var seen = Set<String>()
        let characters = Array(script)
        var index = 0

        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            // A placeholder never spans a line, which is what stops `a < b` in an
            // expression from swallowing the rest of the script.
            var end = index + 1
            var closed = false
            while end < characters.count {
                if characters[end] == ">" { closed = true; break }
                if characters[end] == "\n" || characters[end] == "<" { break }
                end += 1
            }
            guard closed else {
                index += 1
                continue
            }

            let inner = String(characters[(index + 1)..<end])
            let placeholder = "<" + inner + ">"
            if let parameter = parameter(fromInner: inner, placeholder: placeholder),
               !seen.contains(placeholder) {
                seen.insert(placeholder)
                found.append(parameter)
            }
            index = end + 1
        }
        return found
    }

    private static func parameter(fromInner inner: String,
                                  placeholder: String) -> TemplateParameter? {
        // Split on the first two commas only; everything after belongs to the value.
        let parts = inner.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return nil }
        let name = parts[0]
        guard !name.isEmpty else { return nil }
        return TemplateParameter(placeholder: placeholder,
                                 name: name,
                                 dataType: parts[1],
                                 value: parts[2])
    }

    /// Replaces each placeholder with its parameter's value. A parameter left blank keeps
    /// its placeholder, so an unfilled field is visible in the editor rather than silently
    /// producing `WHERE `.
    public static func substitute(_ script: String, with parameters: [TemplateParameter]) -> String {
        var out = script
        for parameter in parameters where !parameter.value.isEmpty {
            out = out.replacingOccurrences(of: parameter.placeholder, with: parameter.value)
        }
        return out
    }
}

/// The built-in Template Explorer tree.
///
/// These are the templates people reach for most often, written against the same T-SQL
/// the rest of the app generates so a template and a "Script as CREATE" produce
/// comparable text.
public enum TSQLTemplateLibrary {

    public static let all: [TSQLTemplate] = database + table + index + view + programmability
        + security + backupAndRestore + performance

    /// Category names in the order the explorer shows them.
    public static var categories: [String] {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    public static func templates(in category: String) -> [TSQLTemplate] {
        all.filter { $0.category == category }
    }

    // MARK: Database

    private static let database: [TSQLTemplate] = [
        TSQLTemplate(category: "Database", name: "Create Database", body: """
        -- Create a database
        USE [master];
        GO

        CREATE DATABASE <database_name, sysname, MyDatabase>
        ON PRIMARY
        ( NAME = <logical_data_name, sysname, MyDatabase>,
          FILENAME = <data_path, nvarchar(260), '/var/opt/mssql/data/MyDatabase.mdf'>,
          SIZE = <data_size, int, 64>MB,
          FILEGROWTH = <data_growth, int, 64>MB )
        LOG ON
        ( NAME = <logical_log_name, sysname, MyDatabase_log>,
          FILENAME = <log_path, nvarchar(260), '/var/opt/mssql/data/MyDatabase_log.ldf'>,
          SIZE = <log_size, int, 16>MB,
          FILEGROWTH = <log_growth, int, 16>MB );
        GO

        ALTER DATABASE <database_name, sysname, MyDatabase>
            SET RECOVERY <recovery_model, nvarchar(20), SIMPLE>;
        GO
        """),
        TSQLTemplate(category: "Database", name: "Drop Database", body: """
        USE [master];
        GO

        ALTER DATABASE <database_name, sysname, MyDatabase>
            SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        GO

        DROP DATABASE <database_name, sysname, MyDatabase>;
        GO
        """),
        TSQLTemplate(category: "Database", name: "Database Space Used", body: """
        SELECT
            f.name                                            AS logical_name,
            f.type_desc,
            CAST(f.size * 8.0 / 1024 AS decimal(18, 2))       AS size_mb,
            CAST(FILEPROPERTY(f.name, 'SpaceUsed') * 8.0 / 1024 AS decimal(18, 2)) AS used_mb,
            CAST((f.size - FILEPROPERTY(f.name, 'SpaceUsed')) * 8.0 / 1024
                 AS decimal(18, 2))                           AS free_mb,
            f.physical_name
        FROM sys.database_files AS f
        ORDER BY f.type, f.file_id;
        """)
    ]

    // MARK: Table

    private static let table: [TSQLTemplate] = [
        TSQLTemplate(category: "Table", name: "Create Table", body: """
        CREATE TABLE <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
        (
            <column1_name, sysname, Id>          int IDENTITY(1, 1) NOT NULL,
            <column2_name, sysname, Name>        nvarchar(200)      NOT NULL,
            <column3_name, sysname, CreatedAt>   datetime2(3)       NOT NULL
                CONSTRAINT <default_name, sysname, DF_MyTable_CreatedAt>
                DEFAULT (SYSUTCDATETIME()),
            CONSTRAINT <pk_name, sysname, PK_MyTable> PRIMARY KEY CLUSTERED
                (<column1_name, sysname, Id> ASC)
        );
        GO
        """),
        TSQLTemplate(category: "Table", name: "Add Column", body: """
        ALTER TABLE <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
            ADD <column_name, sysname, NewColumn> <data_type, sysname, nvarchar(100)> NULL;
        GO
        """),
        TSQLTemplate(category: "Table", name: "Add Foreign Key", body: """
        ALTER TABLE <schema_name, sysname, dbo>.<table_name, sysname, MyTable> WITH CHECK
            ADD CONSTRAINT <fk_name, sysname, FK_MyTable_Parent>
            FOREIGN KEY (<column_name, sysname, ParentId>)
            REFERENCES <parent_schema, sysname, dbo>.<parent_table, sysname, Parent>
                (<parent_column, sysname, Id>)
            ON DELETE <delete_action, nvarchar(20), NO ACTION>;
        GO

        ALTER TABLE <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
            CHECK CONSTRAINT <fk_name, sysname, FK_MyTable_Parent>;
        GO
        """),
        TSQLTemplate(category: "Table", name: "Create Temporal Table", body: """
        CREATE TABLE <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
        (
            <column1_name, sysname, Id>    int IDENTITY(1, 1) NOT NULL PRIMARY KEY CLUSTERED,
            <column2_name, sysname, Name>  nvarchar(200)      NOT NULL,
            ValidFrom datetime2(7) GENERATED ALWAYS AS ROW START NOT NULL,
            ValidTo   datetime2(7) GENERATED ALWAYS AS ROW END   NOT NULL,
            PERIOD FOR SYSTEM_TIME (ValidFrom, ValidTo)
        )
        WITH (SYSTEM_VERSIONING = ON
              (HISTORY_TABLE = <schema_name, sysname, dbo>.<history_table, sysname, MyTableHistory>));
        GO
        """),
        TSQLTemplate(category: "Table", name: "Row Counts and Space", body: """
        SELECT
            s.name                                            AS schema_name,
            t.name                                            AS table_name,
            SUM(CASE WHEN p.index_id < 2 THEN p.row_count ELSE 0 END) AS rows,
            CAST(SUM(p.reserved_page_count) * 8.0 / 1024 AS decimal(18, 2)) AS reserved_mb
        FROM sys.dm_db_partition_stats AS p
        JOIN sys.tables AS t ON t.object_id = p.object_id
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        GROUP BY s.name, t.name
        ORDER BY reserved_mb DESC;
        """)
    ]

    // MARK: Index

    private static let index: [TSQLTemplate] = [
        TSQLTemplate(category: "Index", name: "Create Nonclustered Index", body: """
        CREATE NONCLUSTERED INDEX <index_name, sysname, IX_MyTable_Name>
            ON <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
            (<key_columns, nvarchar(max), [Name] ASC>)
            INCLUDE (<included_columns, nvarchar(max), [CreatedAt]>)
            WITH (ONLINE = OFF, FILLFACTOR = 100);
        GO
        """),
        TSQLTemplate(category: "Index", name: "Rebuild or Reorganize by Fragmentation", body: """
        SELECT
            s.name                                            AS schema_name,
            o.name                                            AS table_name,
            i.name                                            AS index_name,
            CAST(ips.avg_fragmentation_in_percent AS decimal(5, 2)) AS fragmentation_pct,
            ips.page_count,
            CASE WHEN ips.avg_fragmentation_in_percent > 30 THEN 'REBUILD'
                 WHEN ips.avg_fragmentation_in_percent >= 5 THEN 'REORGANIZE'
                 ELSE 'None' END                              AS recommendation
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
        JOIN sys.indexes AS i ON i.object_id = ips.object_id AND i.index_id = ips.index_id
        JOIN sys.objects AS o ON o.object_id = ips.object_id
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE ips.page_count >= <minimum_pages, int, 1000> AND i.name IS NOT NULL
        ORDER BY ips.avg_fragmentation_in_percent DESC;
        """),
        TSQLTemplate(category: "Index", name: "Missing Index Suggestions", body: """
        SELECT TOP (<row_limit, int, 25>)
            DB_NAME(mid.database_id)                          AS database_name,
            OBJECT_SCHEMA_NAME(mid.object_id, mid.database_id) AS schema_name,
            OBJECT_NAME(mid.object_id, mid.database_id)        AS table_name,
            migs.avg_user_impact,
            migs.user_seeks + migs.user_scans                  AS searches,
            mid.equality_columns,
            mid.inequality_columns,
            mid.included_columns
        FROM sys.dm_db_missing_index_details AS mid
        JOIN sys.dm_db_missing_index_groups AS mig ON mig.index_handle = mid.index_handle
        JOIN sys.dm_db_missing_index_group_stats AS migs
             ON migs.group_handle = mig.index_group_handle
        ORDER BY migs.avg_user_impact * (migs.user_seeks + migs.user_scans) DESC;
        """),
        TSQLTemplate(category: "Index", name: "Unused Indexes", body: """
        SELECT
            s.name                                            AS schema_name,
            o.name                                            AS table_name,
            i.name                                            AS index_name,
            us.user_seeks, us.user_scans, us.user_lookups, us.user_updates
        FROM sys.indexes AS i
        JOIN sys.objects AS o ON o.object_id = i.object_id
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        LEFT JOIN sys.dm_db_index_usage_stats AS us
             ON us.object_id = i.object_id AND us.index_id = i.index_id
            AND us.database_id = DB_ID()
        WHERE i.index_id > 1 AND o.is_ms_shipped = 0
          AND ISNULL(us.user_seeks, 0) + ISNULL(us.user_scans, 0)
              + ISNULL(us.user_lookups, 0) = 0
        ORDER BY us.user_updates DESC;
        """)
    ]

    // MARK: View

    private static let view: [TSQLTemplate] = [
        TSQLTemplate(category: "View", name: "Create View", body: """
        CREATE OR ALTER VIEW <schema_name, sysname, dbo>.<view_name, sysname, MyView>
        AS
        SELECT <select_list, nvarchar(max), *>
        FROM <source_schema, sysname, dbo>.<source_table, sysname, MyTable>
        WHERE <search_condition, nvarchar(max), 1 = 1>;
        GO
        """),
        TSQLTemplate(category: "View", name: "Create Indexed View", body: """
        CREATE VIEW <schema_name, sysname, dbo>.<view_name, sysname, MyIndexedView>
        WITH SCHEMABINDING
        AS
        SELECT
            <group_column, sysname, CustomerId>,
            COUNT_BIG(*)                                      AS row_count
        FROM <source_schema, sysname, dbo>.<source_table, sysname, Orders>
        GROUP BY <group_column, sysname, CustomerId>;
        GO

        CREATE UNIQUE CLUSTERED INDEX <index_name, sysname, IX_MyIndexedView>
            ON <schema_name, sysname, dbo>.<view_name, sysname, MyIndexedView>
            (<group_column, sysname, CustomerId>);
        GO
        """)
    ]

    // MARK: Programmability

    private static let programmability: [TSQLTemplate] = [
        TSQLTemplate(category: "Stored Procedure", name: "Create Procedure", body: """
        CREATE OR ALTER PROCEDURE <schema_name, sysname, dbo>.<procedure_name, sysname, MyProcedure>
            @<parameter1_name, sysname, Id> <parameter1_type, sysname, int>,
            @<parameter2_name, sysname, Name> <parameter2_type, sysname, nvarchar(200)> = NULL
        AS
        BEGIN
            SET NOCOUNT ON;
            SET XACT_ABORT ON;

            <body, nvarchar(max), SELECT 1 AS Placeholder;>
        END;
        GO
        """),
        TSQLTemplate(category: "Stored Procedure", name: "Procedure with Transaction", body: """
        CREATE OR ALTER PROCEDURE <schema_name, sysname, dbo>.<procedure_name, sysname, MyProcedure>
        AS
        BEGIN
            SET NOCOUNT ON;
            SET XACT_ABORT ON;

            BEGIN TRY
                BEGIN TRANSACTION;

                <body, nvarchar(max), SELECT 1 AS Placeholder;>

                COMMIT TRANSACTION;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
                THROW;
            END CATCH;
        END;
        GO
        """),
        TSQLTemplate(category: "Function", name: "Create Scalar Function", body: """
        CREATE OR ALTER FUNCTION <schema_name, sysname, dbo>.<function_name, sysname, MyFunction>
            (@<parameter_name, sysname, Value> <parameter_type, sysname, int>)
        RETURNS <return_type, sysname, int>
        AS
        BEGIN
            RETURN <return_expression, nvarchar(max), @Value * 2>;
        END;
        GO
        """),
        TSQLTemplate(category: "Function", name: "Create Inline Table-valued Function", body: """
        CREATE OR ALTER FUNCTION <schema_name, sysname, dbo>.<function_name, sysname, MyFunction>
            (@<parameter_name, sysname, Id> <parameter_type, sysname, int>)
        RETURNS TABLE
        AS
        RETURN
        (
            SELECT <select_list, nvarchar(max), *>
            FROM <source_schema, sysname, dbo>.<source_table, sysname, MyTable>
            WHERE <key_column, sysname, Id> = @<parameter_name, sysname, Id>
        );
        GO
        """),
        TSQLTemplate(category: "Trigger", name: "Create After Trigger", body: """
        CREATE OR ALTER TRIGGER <schema_name, sysname, dbo>.<trigger_name, sysname, TR_MyTable_Audit>
            ON <schema_name, sysname, dbo>.<table_name, sysname, MyTable>
            AFTER <events, nvarchar(60), INSERT, UPDATE>
        AS
        BEGIN
            SET NOCOUNT ON;
            IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
                RETURN;

            <body, nvarchar(max), SELECT 1 AS Placeholder;>
        END;
        GO
        """),
        TSQLTemplate(category: "Programmability", name: "Create Sequence", body: """
        CREATE SEQUENCE <schema_name, sysname, dbo>.<sequence_name, sysname, MySequence>
            AS bigint
            START WITH <start_value, bigint, 1>
            INCREMENT BY <increment, bigint, 1>
            MINVALUE <minimum_value, bigint, 1>
            NO MAXVALUE
            CACHE <cache_size, int, 50>;
        GO
        """),
        TSQLTemplate(category: "Programmability", name: "Create Synonym", body: """
        CREATE SYNONYM <schema_name, sysname, dbo>.<synonym_name, sysname, MySynonym>
            FOR <target_object, nvarchar(max), [OtherDatabase].[dbo].[MyTable]>;
        GO
        """)
    ]

    // MARK: Security

    private static let security: [TSQLTemplate] = [
        TSQLTemplate(category: "Security", name: "Create Login and User", body: """
        USE [master];
        GO

        CREATE LOGIN <login_name, sysname, MyLogin>
            WITH PASSWORD = N'<password, nvarchar(128), StrongPassword1!>',
                 DEFAULT_DATABASE = <default_database, sysname, master>,
                 CHECK_POLICY = ON;
        GO

        USE <database_name, sysname, MyDatabase>;
        GO

        CREATE USER <user_name, sysname, MyLogin> FOR LOGIN <login_name, sysname, MyLogin>;
        GO

        ALTER ROLE <role_name, sysname, db_datareader>
            ADD MEMBER <user_name, sysname, MyLogin>;
        GO
        """),
        TSQLTemplate(category: "Security", name: "Grant Object Permissions", body: """
        GRANT <permission, nvarchar(60), SELECT>
            ON OBJECT::<schema_name, sysname, dbo>.<object_name, sysname, MyTable>
            TO <principal, sysname, MyUser>;
        GO
        """),
        TSQLTemplate(category: "Security", name: "Effective Permissions of a Principal", body: """
        SELECT
            p.state_desc,
            p.permission_name,
            p.class_desc,
            ISNULL(OBJECT_SCHEMA_NAME(p.major_id), N'')       AS schema_name,
            ISNULL(OBJECT_NAME(p.major_id), N'')              AS object_name
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp ON dp.principal_id = p.grantee_principal_id
        WHERE dp.name = N'<principal, sysname, MyUser>'
        ORDER BY p.class_desc, schema_name, object_name, p.permission_name;
        """),
        TSQLTemplate(category: "Security", name: "Create Database Role", body: """
        CREATE ROLE <role_name, sysname, MyRole> AUTHORIZATION [dbo];
        GO

        GRANT <permission, nvarchar(60), SELECT>
            ON SCHEMA::<schema_name, sysname, dbo> TO <role_name, sysname, MyRole>;
        GO
        """)
    ]

    // MARK: Backup and restore

    private static let backupAndRestore: [TSQLTemplate] = [
        TSQLTemplate(category: "Backup and Restore", name: "Full Backup", body: """
        BACKUP DATABASE <database_name, sysname, MyDatabase>
            TO DISK = N'<backup_path, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
            WITH INIT, COMPRESSION, CHECKSUM, STATS = 10,
                 NAME = N'<backup_name, nvarchar(128), MyDatabase-Full Database Backup>';
        GO
        """),
        TSQLTemplate(category: "Backup and Restore", name: "Log Backup", body: """
        BACKUP LOG <database_name, sysname, MyDatabase>
            TO DISK = N'<backup_path, nvarchar(260), /var/opt/mssql/backup/MyDatabase.trn>'
            WITH NOINIT, COMPRESSION, CHECKSUM, STATS = 10;
        GO
        """),
        TSQLTemplate(category: "Backup and Restore", name: "Restore With Move", body: """
        RESTORE FILELISTONLY
            FROM DISK = N'<backup_path, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>';
        GO

        RESTORE DATABASE <database_name, sysname, MyDatabase>
            FROM DISK = N'<backup_path, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
            WITH FILE = 1,
                 MOVE N'<logical_data_name, sysname, MyDatabase>'
                   TO N'<data_path, nvarchar(260), /var/opt/mssql/data/MyDatabase.mdf>',
                 MOVE N'<logical_log_name, sysname, MyDatabase_log>'
                   TO N'<log_path, nvarchar(260), /var/opt/mssql/data/MyDatabase_log.ldf>',
                 REPLACE, RECOVERY, STATS = 5;
        GO
        """),
        TSQLTemplate(category: "Backup and Restore", name: "Backup History", body: """
        SELECT TOP (<row_limit, int, 50>)
            b.database_name,
            b.type,
            b.backup_start_date,
            b.backup_finish_date,
            CAST(b.backup_size / 1048576.0 AS decimal(18, 2))  AS size_mb,
            m.physical_device_name
        FROM msdb.dbo.backupset AS b
        JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
        WHERE b.database_name = N'<database_name, sysname, MyDatabase>'
        ORDER BY b.backup_finish_date DESC;
        """)
    ]

    // MARK: Performance

    private static let performance: [TSQLTemplate] = [
        TSQLTemplate(category: "Performance", name: "Currently Running Requests", body: """
        SELECT
            r.session_id, r.blocking_session_id, r.status, r.command,
            r.wait_type, r.wait_time, r.cpu_time, r.total_elapsed_time,
            DB_NAME(r.database_id)                            AS database_name,
            SUBSTRING(t.text,
                      r.statement_start_offset / 2 + 1,
                      CASE WHEN r.statement_end_offset = -1 THEN DATALENGTH(t.text)
                           ELSE (r.statement_end_offset - r.statement_start_offset) / 2 + 1 END)
                                                              AS running_statement
        FROM sys.dm_exec_requests AS r
        CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
        WHERE r.session_id <> @@SPID
        ORDER BY r.total_elapsed_time DESC;
        """),
        TSQLTemplate(category: "Performance", name: "Top Queries by Average Duration", body: """
        SELECT TOP (<row_limit, int, 25>)
            CAST(qs.total_elapsed_time / NULLIF(qs.execution_count, 0) / 1000.0
                 AS decimal(18, 2))                           AS avg_duration_ms,
            qs.execution_count,
            CAST(qs.total_worker_time / NULLIF(qs.execution_count, 0) / 1000.0
                 AS decimal(18, 2))                           AS avg_cpu_ms,
            qs.total_logical_reads / NULLIF(qs.execution_count, 0) AS avg_reads,
            SUBSTRING(t.text, qs.statement_start_offset / 2 + 1,
                      CASE WHEN qs.statement_end_offset = -1 THEN DATALENGTH(t.text)
                           ELSE (qs.statement_end_offset - qs.statement_start_offset) / 2 + 1 END)
                                                              AS statement_text
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
        ORDER BY avg_duration_ms DESC;
        """),
        TSQLTemplate(category: "Performance", name: "Blocking Chains", body: """
        WITH blocked AS (
            SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time,
                   r.wait_resource
            FROM sys.dm_exec_requests AS r
            WHERE r.blocking_session_id <> 0
        )
        SELECT
            b.blocking_session_id                             AS blocker_spid,
            b.session_id                                      AS blocked_spid,
            b.wait_type, b.wait_time, b.wait_resource,
            s.login_name, s.host_name, s.program_name,
            t.text                                            AS blocker_statement
        FROM blocked AS b
        LEFT JOIN sys.dm_exec_sessions AS s ON s.session_id = b.blocking_session_id
        OUTER APPLY (
            SELECT text FROM sys.dm_exec_connections AS c
            CROSS APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle)
            WHERE c.session_id = b.blocking_session_id
        ) AS t
        ORDER BY b.wait_time DESC;
        """),
        TSQLTemplate(category: "Performance", name: "Wait Statistics", body: """
        SELECT TOP (<row_limit, int, 25>)
            w.wait_type,
            w.waiting_tasks_count,
            w.wait_time_ms,
            w.signal_wait_time_ms,
            CAST(100.0 * w.wait_time_ms / NULLIF(SUM(w.wait_time_ms) OVER (), 0)
                 AS decimal(5, 2))                            AS pct
        FROM sys.dm_os_wait_stats AS w
        WHERE w.wait_type NOT LIKE N'SLEEP%'
          AND w.wait_type NOT IN (N'CLR_SEMAPHORE', N'BROKER_TASK_STOP',
                                  N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT',
                                  N'LOGMGR_QUEUE', N'CHECKPOINT_QUEUE',
                                  N'REQUEST_FOR_DEADLOCK_SEARCH', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
                                  N'DIRTY_PAGE_POLL', N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP')
          AND w.wait_time_ms > 0
        ORDER BY w.wait_time_ms DESC;
        """),
        TSQLTemplate(category: "Performance", name: "Query Store Top Consumers", body: """
        SELECT TOP (<row_limit, int, 25>)
            q.query_id, p.plan_id,
            CAST(SUM(rs.count_executions * rs.avg_duration) / 1000.0
                 AS decimal(18, 2))                           AS total_duration_ms,
            SUM(rs.count_executions)                          AS executions,
            SUBSTRING(qt.query_sql_text, 1, 2000)             AS query_text
        FROM sys.query_store_runtime_stats AS rs
        JOIN sys.query_store_runtime_stats_interval AS rsi
             ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
        JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
        JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE rsi.start_time >= DATEADD(hour, -<hours, int, 24>, SYSDATETIMEOFFSET())
        GROUP BY q.query_id, p.plan_id, SUBSTRING(qt.query_sql_text, 1, 2000)
        ORDER BY total_duration_ms DESC;
        """)
    ]
}
