import Foundation

// MARK: - Model

/// One entry in the Template Explorer library: a named T-SQL script written with the
/// SSMS placeholder syntax `<name, type, default>`.
public struct SQLTemplate: Sendable, Hashable, Identifiable {
    public var id: String
    public var category: String
    public var name: String
    public var body: String

    public init(id: String, category: String, name: String, body: String) {
        self.id = id
        self.category = category
        self.name = name
        self.body = body
    }
}

/// A placeholder discovered in a script. `value` starts out as the template's default and
/// is what the "Specify Values for Template Parameters" dialog edits.
public struct TemplateParameter: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var type: String
    public var value: String

    public init(id: String, name: String, type: String, value: String) {
        self.id = id
        self.name = name
        self.type = type
        self.value = value
    }

    public init(name: String, type: String, value: String) {
        self.init(id: TemplateParameter.key(name: name, type: type),
                  name: name, type: type, value: value)
    }

    /// Two placeholders are the same parameter when both the name and the declared type
    /// match, which is exactly how SSMS collapses repeated placeholders in one script.
    static func key(name: String, type: String) -> String {
        name + "\u{1}" + type
    }
}

// MARK: - Library and placeholder handling

public enum SQLTemplates {

    public static let all: [SQLTemplate] = SQLTemplates.buildLibrary()

    /// Categories in library order, not alphabetical: the ordering is deliberate so the
    /// tree reads the way SSMS groups its own templates.
    public static var categories: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for template in all where seen.insert(template.category).inserted {
            ordered.append(template.category)
        }
        return ordered
    }

    public static func templates(in category: String) -> [SQLTemplate] {
        all.filter { $0.category == category }
    }

    public static func template(id: String) -> SQLTemplate? {
        all.first { $0.id == id }
    }

    /// Parses the SSMS placeholder syntax `<name, type, default>`.
    ///
    /// Repeated placeholders collapse into a single parameter (first occurrence wins for
    /// the default) so that filling in a name once updates every use of it.
    public static func parameters(in body: String) -> [TemplateParameter] {
        var seen: Set<String> = []
        var result: [TemplateParameter] = []
        for placeholder in scan(body) {
            let key: String = TemplateParameter.key(name: placeholder.name, type: placeholder.type)
            guard seen.insert(key).inserted else { continue }
            result.append(TemplateParameter(id: key, name: placeholder.name,
                                            type: placeholder.type, value: placeholder.defaultValue))
        }
        return result
    }

    /// Replaces every placeholder with the matching parameter's value. Placeholders with no
    /// matching parameter are left untouched rather than blanked out.
    public static func substitute(_ body: String, with parameters: [TemplateParameter]) -> String {
        let placeholders: [Placeholder] = scan(body)
        guard !placeholders.isEmpty else { return body }

        var exact: [String: String] = [:]
        var byName: [String: String] = [:]
        for parameter in parameters {
            let key: String = TemplateParameter.key(name: parameter.name, type: parameter.type)
            exact[key] = parameter.value
            if byName[parameter.name] == nil { byName[parameter.name] = parameter.value }
        }

        var result = ""
        result.reserveCapacity(body.count)
        var cursor: String.Index = body.startIndex
        for placeholder in placeholders {
            result.append(contentsOf: body[cursor..<placeholder.range.lowerBound])
            let key: String = TemplateParameter.key(name: placeholder.name, type: placeholder.type)
            if let value = exact[key] ?? byName[placeholder.name] {
                result.append(value)
            } else {
                result.append(contentsOf: body[placeholder.range])
            }
            cursor = placeholder.range.upperBound
        }
        result.append(contentsOf: body[cursor...])
        return result
    }

    // MARK: - Scanner

    struct Placeholder {
        var range: Range<String.Index>
        var name: String
        var type: String
        var defaultValue: String
    }

    /// Finds `<name, type, default>` runs. T-SQL uses `<`, `>` and `<>` as operators, so a
    /// candidate only counts when it stays on one line, contains no nested `<`, and has at
    /// least one comma — that is enough to keep `WHERE a < b` out of the parameter list.
    static func scan(_ body: String) -> [Placeholder] {
        var result: [Placeholder] = []
        let end: String.Index = body.endIndex
        var index: String.Index = body.startIndex

        while index < end {
            guard body[index] == "<" else {
                index = body.index(after: index)
                continue
            }
            var cursor: String.Index = body.index(after: index)
            var closing: String.Index?
            while cursor < end {
                let character: Character = body[cursor]
                if character == "\n" || character == "\r" || character == "<" { break }
                if character == ">" {
                    closing = cursor
                    break
                }
                cursor = body.index(after: cursor)
            }
            guard let close = closing else {
                index = body.index(after: index)
                continue
            }
            let inner = String(body[body.index(after: index)..<close])
            guard let fields = splitFields(inner) else {
                index = body.index(after: index)
                continue
            }
            let upper: String.Index = body.index(after: close)
            result.append(Placeholder(range: index..<upper, name: fields.name,
                                      type: fields.type, defaultValue: fields.value))
            index = upper
        }
        return result
    }

    private static func splitFields(_ inner: String) -> (name: String, type: String, value: String)? {
        guard inner.count <= 400 else { return nil }
        guard let firstComma = inner.firstIndex(of: ",") else { return nil }

        let rawName = String(inner[inner.startIndex..<firstComma])
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // A parameter name is an identifier-ish token; anything else is an operator we
        // happened to walk over.
        let allowed: CharacterSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@#$ "))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }

        let remainder = inner[inner.index(after: firstComma)...]
        guard let secondComma = remainder.firstIndex(of: ",") else {
            let type = remainder.trimmingCharacters(in: .whitespaces)
            return (name, type, "")
        }
        let type = String(remainder[remainder.startIndex..<secondComma])
            .trimmingCharacters(in: .whitespaces)
        let value = String(remainder[remainder.index(after: secondComma)...])
            .trimmingCharacters(in: .whitespaces)
        return (name, type, value)
    }

    // MARK: - Library

    private static func buildLibrary() -> [SQLTemplate] {
        var library: [SQLTemplate] = []
        library += databaseTemplates
        library += tableTemplates
        library += indexTemplates
        library += procedureTemplates
        library += functionTemplates
        library += triggerTemplates
        library += viewTemplates
        library += securityTemplates
        library += maintenanceTemplates
        library += queryTemplates
        return library
    }
}

// MARK: - Database

extension SQLTemplates {

    private static let databaseCategory = "Database"

    private static var databaseTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "database.create", category: databaseCategory, name: "Create Database", body: """
                -- =========================================================
                -- Create a database with explicit file placement
                -- =========================================================
                USE master
                GO

                IF DB_ID(N'<Database_Name, sysname, MyDatabase>') IS NOT NULL
                    RAISERROR (N'Database already exists.', 16, 1)
                GO

                CREATE DATABASE <Database_Name, sysname, MyDatabase>
                ON PRIMARY
                (
                    NAME     = N'<Database_Name, sysname, MyDatabase>_data',
                    FILENAME = N'<Data_File_Path, nvarchar(260), /var/opt/mssql/data/MyDatabase.mdf>',
                    SIZE     = <Data_File_Size, , 256MB>,
                    FILEGROWTH = <Data_File_Growth, , 64MB>
                )
                LOG ON
                (
                    NAME     = N'<Database_Name, sysname, MyDatabase>_log',
                    FILENAME = N'<Log_File_Path, nvarchar(260), /var/opt/mssql/data/MyDatabase.ldf>',
                    SIZE     = <Log_File_Size, , 64MB>,
                    FILEGROWTH = <Log_File_Growth, , 64MB>
                )
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    SET RECOVERY <Recovery_Model, , SIMPLE>
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    COLLATE <Collation, sysname, SQL_Latin1_General_CP1_CI_AS>
                GO
                """),

            SQLTemplate(id: "database.alter", category: databaseCategory, name: "Alter Database Options", body: """
                -- =========================================================
                -- Common database level options
                -- =========================================================
                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    SET RECOVERY <Recovery_Model, , FULL> WITH NO_WAIT
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    SET COMPATIBILITY_LEVEL = <Compatibility_Level, int, 160>
                GO

                -- Read committed snapshot needs exclusive access; ROLLBACK IMMEDIATE
                -- disconnects everyone else instead of waiting for them.
                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    SET READ_COMMITTED_SNAPSHOT <Snapshot_Isolation, , ON> WITH ROLLBACK IMMEDIATE
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    SET AUTO_CREATE_STATISTICS ON, AUTO_UPDATE_STATISTICS ON
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase>
                    MODIFY FILE
                    (
                        NAME = N'<Logical_File_Name, sysname, MyDatabase_data>',
                        SIZE = <New_File_Size, , 512MB>
                    )
                GO
                """),

            SQLTemplate(id: "database.drop", category: databaseCategory, name: "Drop Database", body: """
                -- =========================================================
                -- Drop a database, evicting open sessions first
                -- =========================================================
                USE master
                GO

                IF DB_ID(N'<Database_Name, sysname, MyDatabase>') IS NOT NULL
                BEGIN
                    ALTER DATABASE <Database_Name, sysname, MyDatabase>
                        SET SINGLE_USER WITH ROLLBACK IMMEDIATE

                    DROP DATABASE <Database_Name, sysname, MyDatabase>
                END
                GO
                """),

            SQLTemplate(id: "database.backup", category: databaseCategory, name: "Back Up Database", body: """
                -- =========================================================
                -- Full backup, then a log backup for point in time recovery
                -- =========================================================
                BACKUP DATABASE <Database_Name, sysname, MyDatabase>
                TO DISK = N'<Backup_File, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
                WITH FORMAT,
                     INIT,
                     NAME = N'<Backup_Set_Name, nvarchar(128), MyDatabase full backup>',
                     COMPRESSION,
                     CHECKSUM,
                     STATS = <Progress_Percent, int, 10>
                GO

                -- Only valid under the FULL or BULK_LOGGED recovery model.
                BACKUP LOG <Database_Name, sysname, MyDatabase>
                TO DISK = N'<Log_Backup_File, nvarchar(260), /var/opt/mssql/backup/MyDatabase_log.trn>'
                WITH CHECKSUM,
                     STATS = <Progress_Percent, int, 10>
                GO

                RESTORE VERIFYONLY
                FROM DISK = N'<Backup_File, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
                WITH CHECKSUM
                GO
                """),

            SQLTemplate(id: "database.restore", category: databaseCategory, name: "Restore Database", body: """
                -- =========================================================
                -- Restore a full backup, relocating the files
                -- =========================================================
                USE master
                GO

                -- Logical file names for the MOVE clauses below.
                RESTORE FILELISTONLY
                FROM DISK = N'<Backup_File, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
                GO

                IF DB_ID(N'<Database_Name, sysname, MyDatabase>') IS NOT NULL
                    ALTER DATABASE <Database_Name, sysname, MyDatabase>
                        SET SINGLE_USER WITH ROLLBACK IMMEDIATE
                GO

                RESTORE DATABASE <Database_Name, sysname, MyDatabase>
                FROM DISK = N'<Backup_File, nvarchar(260), /var/opt/mssql/backup/MyDatabase.bak>'
                WITH FILE = <Backup_Set_Number, int, 1>,
                     MOVE N'<Data_Logical_Name, sysname, MyDatabase_data>'
                       TO N'<Data_File_Path, nvarchar(260), /var/opt/mssql/data/MyDatabase.mdf>',
                     MOVE N'<Log_Logical_Name, sysname, MyDatabase_log>'
                       TO N'<Log_File_Path, nvarchar(260), /var/opt/mssql/data/MyDatabase.ldf>',
                     REPLACE,
                     RECOVERY,
                     STATS = <Progress_Percent, int, 10>
                GO

                ALTER DATABASE <Database_Name, sysname, MyDatabase> SET MULTI_USER
                GO
                """)
        ]
    }
}

// MARK: - Table

extension SQLTemplates {

    private static let tableCategory = "Table"

    private static var tableTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "table.create", category: tableCategory, name: "Create Table", body: """
                -- =========================================================
                -- Create table
                -- =========================================================
                IF OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>', N'U') IS NOT NULL
                    RAISERROR (N'Table already exists.', 16, 1)
                GO

                CREATE TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                (
                    <Column_1_Name, sysname, Id>          <Column_1_Type, , int> IDENTITY(1, 1) NOT NULL,
                    <Column_2_Name, sysname, Name>        <Column_2_Type, , nvarchar(128)> NOT NULL,
                    <Column_3_Name, sysname, Amount>      <Column_3_Type, , decimal(19, 4)> NULL,
                    <Column_4_Name, sysname, CreatedAt>   datetime2(3) NOT NULL
                        CONSTRAINT <Default_Name, sysname, DF_MyTable_CreatedAt> DEFAULT (SYSUTCDATETIME()),
                    CONSTRAINT <Primary_Key_Name, sysname, PK_MyTable>
                        PRIMARY KEY CLUSTERED (<Column_1_Name, sysname, Id> ASC)
                )
                GO

                CREATE UNIQUE NONCLUSTERED INDEX <Unique_Index_Name, sysname, UX_MyTable_Name>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                       (<Column_2_Name, sysname, Name> ASC)
                GO
                """),

            SQLTemplate(id: "table.add.column", category: tableCategory, name: "Add Column", body: """
                -- =========================================================
                -- Add a column
                -- =========================================================
                -- Adding a NOT NULL column to an existing table requires a default so the
                -- existing rows have something to hold.
                IF COL_LENGTH(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>',
                              N'<Column_Name, sysname, NewColumn>') IS NULL
                BEGIN
                    ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                        ADD <Column_Name, sysname, NewColumn> <Column_Type, , nvarchar(64)> NOT NULL
                            CONSTRAINT <Default_Name, sysname, DF_MyTable_NewColumn>
                                DEFAULT (<Default_Expression, , N''>) WITH VALUES
                END
                GO

                -- Widening a column is a metadata only change; narrowing it rewrites the table.
                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    ALTER COLUMN <Column_Name, sysname, NewColumn> <New_Column_Type, , nvarchar(128)> NOT NULL
                GO
                """),

            SQLTemplate(id: "table.drop.column", category: tableCategory, name: "Drop Column", body: """
                -- =========================================================
                -- Drop a column and everything bound to it
                -- =========================================================
                DECLARE @Constraint sysname

                SELECT @Constraint = dc.name
                FROM sys.default_constraints AS dc
                INNER JOIN sys.columns AS c
                        ON c.object_id = dc.parent_object_id
                       AND c.column_id = dc.parent_column_id
                WHERE dc.parent_object_id =
                          OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>')
                  AND c.name = N'<Column_Name, sysname, ObsoleteColumn>'

                IF @Constraint IS NOT NULL
                    EXEC (N'ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                            DROP CONSTRAINT ' + QUOTENAME(@Constraint))
                GO

                IF COL_LENGTH(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>',
                              N'<Column_Name, sysname, ObsoleteColumn>') IS NOT NULL
                    ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                        DROP COLUMN <Column_Name, sysname, ObsoleteColumn>
                GO
                """),

            SQLTemplate(id: "table.add.constraint", category: tableCategory,
                        name: "Add Constraint", body: """
                -- =========================================================
                -- Primary key, foreign key, check and unique constraints
                -- =========================================================
                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    ADD CONSTRAINT <Primary_Key_Name, sysname, PK_MyTable>
                        PRIMARY KEY CLUSTERED (<Key_Column, sysname, Id> ASC)
                GO

                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WITH CHECK ADD CONSTRAINT <Foreign_Key_Name, sysname, FK_MyTable_Parent>
                        FOREIGN KEY (<Foreign_Key_Column, sysname, ParentId>)
                        REFERENCES <Referenced_Schema, sysname, dbo>.<Referenced_Table, sysname, ParentTable>
                                   (<Referenced_Column, sysname, Id>)
                        ON DELETE <On_Delete_Action, , NO ACTION>
                        ON UPDATE <On_Update_Action, , NO ACTION>
                GO

                -- WITH CHECK CHECK re-validates the existing rows so the optimiser can trust
                -- the constraint; without it the key stays untrusted.
                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    CHECK CONSTRAINT <Foreign_Key_Name, sysname, FK_MyTable_Parent>
                GO

                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WITH CHECK ADD CONSTRAINT <Check_Name, sysname, CK_MyTable_Amount>
                        CHECK (<Check_Expression, , [Amount] BETWEEN 0 AND 1000000>)
                GO

                ALTER TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    ADD CONSTRAINT <Unique_Name, sysname, UQ_MyTable_Name>
                        UNIQUE NONCLUSTERED (<Unique_Column, sysname, Name> ASC)
                GO
                """),

            SQLTemplate(id: "table.drop", category: tableCategory, name: "Drop Table", body: """
                -- =========================================================
                -- Drop table
                -- =========================================================
                -- Referencing foreign keys must go first or the DROP fails.
                SELECT  N'ALTER TABLE ' + QUOTENAME(SCHEMA_NAME(t.schema_id)) + N'.' +
                        QUOTENAME(t.name) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) AS DropScript
                FROM sys.foreign_keys AS fk
                INNER JOIN sys.tables AS t ON t.object_id = fk.parent_object_id
                WHERE fk.referenced_object_id =
                          OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>')
                GO

                IF OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>', N'U') IS NOT NULL
                    DROP TABLE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                GO
                """)
        ]
    }
}

// MARK: - Index

extension SQLTemplates {

    private static let indexCategory = "Index"

    private static var indexTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "index.clustered", category: indexCategory,
                        name: "Create Clustered Index", body: """
                -- =========================================================
                -- Clustered index: the physical order of the table
                -- =========================================================
                CREATE CLUSTERED INDEX <Index_Name, sysname, CIX_MyTable_Id>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    (
                        <Key_Column_1, sysname, Id> ASC
                    )
                    WITH (PAD_INDEX = OFF,
                          FILLFACTOR = <Fill_Factor, int, 90>,
                          SORT_IN_TEMPDB = ON,
                          DROP_EXISTING = <Drop_Existing, , OFF>,
                          ONLINE = <Online, , OFF>,
                          DATA_COMPRESSION = <Data_Compression, , NONE>)
                    ON [<Filegroup, sysname, PRIMARY>]
                GO
                """),

            SQLTemplate(id: "index.nonclustered", category: indexCategory,
                        name: "Create Nonclustered Index with Included Columns", body: """
                -- =========================================================
                -- Covering index: keys drive the seek, INCLUDE avoids the lookup
                -- =========================================================
                CREATE NONCLUSTERED INDEX <Index_Name, sysname, IX_MyTable_Name_CreatedAt>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    (
                        <Key_Column_1, sysname, Name> ASC,
                        <Key_Column_2, sysname, CreatedAt> DESC
                    )
                    INCLUDE
                    (
                        <Included_Column_1, sysname, Amount>,
                        <Included_Column_2, sysname, Status>
                    )
                    WITH (FILLFACTOR = <Fill_Factor, int, 90>,
                          SORT_IN_TEMPDB = ON,
                          DROP_EXISTING = <Drop_Existing, , OFF>,
                          ONLINE = <Online, , OFF>)
                    ON [<Filegroup, sysname, PRIMARY>]
                GO
                """),

            SQLTemplate(id: "index.filtered", category: indexCategory,
                        name: "Create Filtered Index", body: """
                -- =========================================================
                -- Filtered index: small index over the rows that are actually queried
                -- =========================================================
                -- The session needs ANSI_NULLS and QUOTED_IDENTIFIER ON, otherwise the
                -- index cannot be created or later modified.
                SET ANSI_NULLS ON
                SET QUOTED_IDENTIFIER ON
                GO

                CREATE NONCLUSTERED INDEX <Index_Name, sysname, IX_MyTable_Open>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    (
                        <Key_Column, sysname, CreatedAt> DESC
                    )
                    INCLUDE (<Included_Column, sysname, Amount>)
                    WHERE <Filter_Predicate, , [Status] = N'Open'>
                    WITH (FILLFACTOR = 100, SORT_IN_TEMPDB = ON)
                GO
                """),

            SQLTemplate(id: "index.rebuild", category: indexCategory,
                        name: "Rebuild or Reorganize Index", body: """
                -- =========================================================
                -- Fragmentation maintenance for one index
                -- =========================================================
                SELECT  i.name AS IndexName,
                        ips.index_type_desc,
                        ips.avg_fragmentation_in_percent,
                        ips.page_count
                FROM sys.dm_db_index_physical_stats(
                         DB_ID(),
                         OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>'),
                         NULL, NULL, N'LIMITED') AS ips
                INNER JOIN sys.indexes AS i
                        ON i.object_id = ips.object_id
                       AND i.index_id = ips.index_id
                WHERE ips.page_count >= <Minimum_Pages, int, 1000>
                ORDER BY ips.avg_fragmentation_in_percent DESC
                GO

                -- Reorganize under roughly 30% fragmentation, rebuild above it.
                ALTER INDEX <Index_Name, sysname, IX_MyTable_Name_CreatedAt>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    REORGANIZE WITH (LOB_COMPACTION = ON)
                GO

                ALTER INDEX <Index_Name, sysname, IX_MyTable_Name_CreatedAt>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    REBUILD WITH (FILLFACTOR = <Fill_Factor, int, 90>,
                                  SORT_IN_TEMPDB = ON,
                                  ONLINE = <Online, , OFF>,
                                  MAXDOP = <Max_Dop, int, 0>)
                GO
                """),

            SQLTemplate(id: "index.drop", category: indexCategory, name: "Drop Index", body: """
                -- =========================================================
                -- Drop index
                -- =========================================================
                IF EXISTS (SELECT 1
                           FROM sys.indexes
                           WHERE name = N'<Index_Name, sysname, IX_MyTable_Name_CreatedAt>'
                             AND object_id =
                                 OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>'))
                    DROP INDEX <Index_Name, sysname, IX_MyTable_Name_CreatedAt>
                        ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                        WITH (ONLINE = <Online, , OFF>)
                GO
                """)
        ]
    }
}

// MARK: - Stored Procedure

extension SQLTemplates {

    private static let procedureCategory = "Stored Procedure"

    private static var procedureTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "procedure.create", category: procedureCategory,
                        name: "Create Procedure", body: """
                -- =========================================================
                -- Create procedure
                -- =========================================================
                SET ANSI_NULLS ON
                GO
                SET QUOTED_IDENTIFIER ON
                GO

                CREATE PROCEDURE <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyProcedure>
                    @<Param_1_Name, sysname, Id> <Param_1_Type, , int>,
                    @<Param_2_Name, sysname, Name> <Param_2_Type, , nvarchar(128)> = NULL
                AS
                BEGIN
                    -- Suppress the DONE_IN_PROC rowcount messages; clients read them as
                    -- extra empty result sets.
                    SET NOCOUNT ON

                    SELECT  <Column_List, , *>
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WHERE <Key_Column, sysname, Id> = @<Param_1_Name, sysname, Id>
                      AND (@<Param_2_Name, sysname, Name> IS NULL
                           OR <Filter_Column, sysname, Name> = @<Param_2_Name, sysname, Name>)

                    RETURN 0
                END
                GO
                """),

            SQLTemplate(id: "procedure.alter", category: procedureCategory,
                        name: "Alter Procedure", body: """
                -- =========================================================
                -- Alter procedure, keeping permissions and the object id
                -- =========================================================
                SET ANSI_NULLS ON
                GO
                SET QUOTED_IDENTIFIER ON
                GO

                ALTER PROCEDURE <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyProcedure>
                    @<Param_1_Name, sysname, Id> <Param_1_Type, , int>
                AS
                BEGIN
                    SET NOCOUNT ON

                    SELECT  <Column_List, , *>
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WHERE <Key_Column, sysname, Id> = @<Param_1_Name, sysname, Id>

                    RETURN 0
                END
                GO
                """),

            SQLTemplate(id: "procedure.output", category: procedureCategory,
                        name: "Procedure with Output Parameter", body: """
                -- =========================================================
                -- Output parameter and return code
                -- =========================================================
                CREATE OR ALTER PROCEDURE <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyInsert>
                    @<Input_Param, sysname, Name> <Input_Type, , nvarchar(128)>,
                    @<Output_Param, sysname, NewId> <Output_Type, , int> OUTPUT
                AS
                BEGIN
                    SET NOCOUNT ON

                    INSERT INTO <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                            (<Insert_Column, sysname, Name>)
                    VALUES  (@<Input_Param, sysname, Name>)

                    -- SCOPE_IDENTITY stays inside this batch; @@IDENTITY would pick up a
                    -- value generated by a trigger.
                    SET @<Output_Param, sysname, NewId> = SCOPE_IDENTITY()

                    RETURN 0
                END
                GO

                DECLARE @NewId <Output_Type, , int>
                DECLARE @ReturnCode int

                EXEC @ReturnCode = <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyInsert>
                        @<Input_Param, sysname, Name> = N'sample',
                        @<Output_Param, sysname, NewId> = @NewId OUTPUT

                SELECT @ReturnCode AS ReturnCode, @NewId AS NewId
                GO
                """),

            SQLTemplate(id: "procedure.trycatch", category: procedureCategory,
                        name: "Procedure with TRY / CATCH", body: """
                -- =========================================================
                -- Transactional procedure with error handling
                -- =========================================================
                CREATE OR ALTER PROCEDURE <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyTransfer>
                    @<Param_1_Name, sysname, SourceId> int,
                    @<Param_2_Name, sysname, TargetId> int,
                    @<Param_3_Name, sysname, Amount> decimal(19, 4)
                AS
                BEGIN
                    SET NOCOUNT ON
                    SET XACT_ABORT ON

                    BEGIN TRY
                        BEGIN TRANSACTION

                        UPDATE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                        SET <Value_Column, sysname, Balance> =
                                <Value_Column, sysname, Balance> - @<Param_3_Name, sysname, Amount>
                        WHERE <Key_Column, sysname, Id> = @<Param_1_Name, sysname, SourceId>

                        UPDATE <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                        SET <Value_Column, sysname, Balance> =
                                <Value_Column, sysname, Balance> + @<Param_3_Name, sysname, Amount>
                        WHERE <Key_Column, sysname, Id> = @<Param_2_Name, sysname, TargetId>

                        COMMIT TRANSACTION
                    END TRY
                    BEGIN CATCH
                        -- XACT_STATE reports a doomed transaction that can only be rolled back.
                        IF XACT_STATE() <> 0
                            ROLLBACK TRANSACTION

                        DECLARE @Message nvarchar(4000) = ERROR_MESSAGE()
                        DECLARE @Severity int = ERROR_SEVERITY()
                        DECLARE @State int = ERROR_STATE()

                        RAISERROR (@Message, @Severity, @State)
                        RETURN 1
                    END CATCH

                    RETURN 0
                END
                GO
                """),

            SQLTemplate(id: "procedure.drop", category: procedureCategory,
                        name: "Drop Procedure", body: """
                -- =========================================================
                -- Drop procedure
                -- =========================================================
                IF OBJECT_ID(N'<Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyProcedure>',
                             N'P') IS NOT NULL
                    DROP PROCEDURE <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyProcedure>
                GO

                -- Modules that still call it, so nothing is left dangling.
                SELECT  OBJECT_SCHEMA_NAME(referencing_id) AS ReferencingSchema,
                        OBJECT_NAME(referencing_id) AS ReferencingObject
                FROM sys.sql_expression_dependencies
                WHERE referenced_entity_name = N'<Procedure_Name, sysname, MyProcedure>'
                GO
                """)
        ]
    }
}

// MARK: - Function

extension SQLTemplates {

    private static let functionCategory = "Function"

    private static var functionTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "function.scalar", category: functionCategory,
                        name: "Scalar Function", body: """
                -- =========================================================
                -- Scalar function
                -- =========================================================
                -- SCHEMABINDING lets SQL Server mark the function as deterministic and
                -- non data accessing, which keeps it out of the row by row penalty box.
                CREATE OR ALTER FUNCTION <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyScalarFunction>
                (
                    @<Param_1_Name, sysname, Amount> <Param_1_Type, , decimal(19, 4)>,
                    @<Param_2_Name, sysname, Rate> <Param_2_Type, , decimal(9, 4)>
                )
                RETURNS <Return_Type, , decimal(19, 4)>
                WITH SCHEMABINDING
                AS
                BEGIN
                    DECLARE @Result <Return_Type, , decimal(19, 4)>

                    SET @Result = @<Param_1_Name, sysname, Amount> *
                                  (1 + ISNULL(@<Param_2_Name, sysname, Rate>, 0))

                    RETURN @Result
                END
                GO

                SELECT <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyScalarFunction>(100, 0.2) AS Value
                GO
                """),

            SQLTemplate(id: "function.inline", category: functionCategory,
                        name: "Inline Table Valued Function", body: """
                -- =========================================================
                -- Inline table valued function
                -- =========================================================
                -- A single RETURN SELECT is expanded into the calling query, so it costs
                -- nothing extra; prefer this shape over the multi statement form.
                CREATE OR ALTER FUNCTION <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyInlineFunction>
                (
                    @<Param_Name, sysname, ParentId> <Param_Type, , int>
                )
                RETURNS TABLE
                AS
                RETURN
                (
                    SELECT  <Column_List, , *>
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WHERE <Filter_Column, sysname, ParentId> = @<Param_Name, sysname, ParentId>
                )
                GO

                SELECT f.*
                FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                CROSS APPLY <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyInlineFunction>
                            (t.<Key_Column, sysname, Id>) AS f
                GO
                """),

            SQLTemplate(id: "function.multistatement", category: functionCategory,
                        name: "Multi Statement Table Valued Function", body: """
                -- =========================================================
                -- Multi statement table valued function
                -- =========================================================
                CREATE OR ALTER FUNCTION <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyTableFunction>
                (
                    @<Param_Name, sysname, RootId> <Param_Type, , int>
                )
                RETURNS @Result TABLE
                (
                    <Result_Column_1, sysname, Id> int NOT NULL PRIMARY KEY,
                    <Result_Column_2, sysname, Name> nvarchar(128) NULL,
                    <Result_Column_3, sysname, Depth> int NOT NULL
                )
                AS
                BEGIN
                    INSERT INTO @Result (<Result_Column_1, sysname, Id>,
                                         <Result_Column_2, sysname, Name>,
                                         <Result_Column_3, sysname, Depth>)
                    SELECT  <Key_Column, sysname, Id>,
                            <Name_Column, sysname, Name>,
                            0
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WHERE <Key_Column, sysname, Id> = @<Param_Name, sysname, RootId>

                    RETURN
                END
                GO

                SELECT * FROM <Schema_Name, sysname, dbo>.<Function_Name, sysname, MyTableFunction>(1)
                GO
                """)
        ]
    }
}

// MARK: - Trigger

extension SQLTemplates {

    private static let triggerCategory = "Trigger"

    private static var triggerTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "trigger.after", category: triggerCategory,
                        name: "AFTER INSERT, UPDATE Trigger", body: """
                -- =========================================================
                -- DML trigger, set based
                -- =========================================================
                CREATE OR ALTER TRIGGER <Schema_Name, sysname, dbo>.<Trigger_Name, sysname, TR_MyTable_Audit>
                    ON <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    AFTER INSERT, UPDATE
                AS
                BEGIN
                    SET NOCOUNT ON

                    -- inserted and deleted hold every affected row, so never assume one.
                    IF NOT EXISTS (SELECT 1 FROM inserted)
                        RETURN

                    INSERT INTO <Audit_Schema, sysname, dbo>.<Audit_Table, sysname, MyTableAudit>
                            (<Key_Column, sysname, Id>, ChangedAt, ChangedBy, Action)
                    SELECT  i.<Key_Column, sysname, Id>,
                            SYSUTCDATETIME(),
                            SUSER_SNAME(),
                            CASE WHEN EXISTS (SELECT 1 FROM deleted) THEN N'UPDATE' ELSE N'INSERT' END
                    FROM inserted AS i

                    IF UPDATE(<Watched_Column, sysname, Status>)
                        PRINT N'<Watched_Column, sysname, Status> was assigned'
                END
                GO
                """),

            SQLTemplate(id: "trigger.insteadof", category: triggerCategory,
                        name: "INSTEAD OF Trigger", body: """
                -- =========================================================
                -- INSTEAD OF trigger, typically to make a view updatable
                -- =========================================================
                CREATE OR ALTER TRIGGER <Schema_Name, sysname, dbo>.<Trigger_Name, sysname, TR_MyView_Insert>
                    ON <Schema_Name, sysname, dbo>.<View_Name, sysname, MyView>
                    INSTEAD OF INSERT
                AS
                BEGIN
                    SET NOCOUNT ON

                    INSERT INTO <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                            (<Column_1, sysname, Name>, <Column_2, sysname, Amount>)
                    SELECT  i.<Column_1, sysname, Name>,
                            i.<Column_2, sysname, Amount>
                    FROM inserted AS i
                    WHERE NOT EXISTS (SELECT 1
                                      FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                                      WHERE t.<Column_1, sysname, Name> = i.<Column_1, sysname, Name>)
                END
                GO
                """),

            SQLTemplate(id: "trigger.ddl", category: triggerCategory, name: "DDL Trigger", body: """
                -- =========================================================
                -- Database scoped DDL trigger
                -- =========================================================
                CREATE OR ALTER TRIGGER <Trigger_Name, sysname, TR_DDL_Audit>
                    ON <Trigger_Scope, , DATABASE>
                    FOR <Event_Group, , DDL_TABLE_VIEW_EVENTS>
                AS
                BEGIN
                    SET NOCOUNT ON

                    DECLARE @EventData xml = EVENTDATA()

                    INSERT INTO <Audit_Schema, sysname, dbo>.<Audit_Table, sysname, DDLAudit>
                            (EventType, ObjectName, LoginName, EventTime, Command)
                    SELECT  @EventData.value(N'(/EVENT_INSTANCE/EventType)[1]', N'nvarchar(128)'),
                            @EventData.value(N'(/EVENT_INSTANCE/ObjectName)[1]', N'nvarchar(256)'),
                            @EventData.value(N'(/EVENT_INSTANCE/LoginName)[1]', N'nvarchar(128)'),
                            SYSUTCDATETIME(),
                            @EventData.value(N'(/EVENT_INSTANCE/TSQLCommand/CommandText)[1]',
                                             N'nvarchar(max)')
                END
                GO

                DISABLE TRIGGER <Trigger_Name, sysname, TR_DDL_Audit> ON <Trigger_Scope, , DATABASE>
                GO
                """)
        ]
    }
}

// MARK: - View

extension SQLTemplates {

    private static let viewCategory = "View"

    private static var viewTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "view.create", category: viewCategory, name: "Create View", body: """
                -- =========================================================
                -- Create view
                -- =========================================================
                SET ANSI_NULLS ON
                GO
                SET QUOTED_IDENTIFIER ON
                GO

                CREATE VIEW <Schema_Name, sysname, dbo>.<View_Name, sysname, MyView>
                AS
                    SELECT  t.<Column_1, sysname, Id>,
                            t.<Column_2, sysname, Name>,
                            p.<Column_3, sysname, ParentName>
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                    LEFT JOIN <Schema_Name, sysname, dbo>.<Join_Table, sysname, ParentTable> AS p
                           ON p.<Join_Column, sysname, Id> = t.<Foreign_Key_Column, sysname, ParentId>
                    WHERE <Filter_Predicate, , t.[IsActive] = 1>
                GO
                """),

            SQLTemplate(id: "view.alter", category: viewCategory, name: "Alter View", body: """
                -- =========================================================
                -- Alter view
                -- =========================================================
                ALTER VIEW <Schema_Name, sysname, dbo>.<View_Name, sysname, MyView>
                WITH <View_Attribute, , SCHEMABINDING>
                AS
                    SELECT  t.<Column_1, sysname, Id>,
                            t.<Column_2, sysname, Name>
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                    WHERE <Filter_Predicate, , t.[IsActive] = 1>
                GO

                -- Refresh the cached column metadata after the shape of a view changes.
                EXEC sp_refreshview N'<Schema_Name, sysname, dbo>.<View_Name, sysname, MyView>'
                GO
                """),

            SQLTemplate(id: "view.indexed", category: viewCategory, name: "Indexed View", body: """
                -- =========================================================
                -- Indexed (materialised) view
                -- =========================================================
                -- Required session settings; an indexed view cannot be created without them.
                SET ANSI_NULLS ON
                SET ANSI_PADDING ON
                SET ANSI_WARNINGS ON
                SET ARITHABORT ON
                SET CONCAT_NULL_YIELDS_NULL ON
                SET NUMERIC_ROUNDABORT OFF
                SET QUOTED_IDENTIFIER ON
                GO

                CREATE OR ALTER VIEW <Schema_Name, sysname, dbo>.<View_Name, sysname, MyIndexedView>
                WITH SCHEMABINDING
                AS
                    SELECT  t.<Group_Column, sysname, CustomerId>,
                            SUM(t.<Value_Column, sysname, Amount>) AS TotalAmount,
                            -- COUNT_BIG is mandatory for a grouped indexed view.
                            COUNT_BIG(*) AS RowCountBig
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                    GROUP BY t.<Group_Column, sysname, CustomerId>
                GO

                CREATE UNIQUE CLUSTERED INDEX <Index_Name, sysname, CIX_MyIndexedView>
                    ON <Schema_Name, sysname, dbo>.<View_Name, sysname, MyIndexedView>
                       (<Group_Column, sysname, CustomerId>)
                GO
                """)
        ]
    }
}

// MARK: - Security

extension SQLTemplates {

    private static let securityCategory = "Security"

    private static var securityTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "security.login", category: securityCategory, name: "Create Login", body: """
                -- =========================================================
                -- Server principal
                -- =========================================================
                USE master
                GO

                IF NOT EXISTS (SELECT 1 FROM sys.server_principals
                               WHERE name = N'<Login_Name, sysname, MyLogin>')
                    CREATE LOGIN <Login_Name, sysname, MyLogin>
                        WITH PASSWORD = N'<Password, sysname, StrongPassword1!>',
                             DEFAULT_DATABASE = <Default_Database, sysname, master>,
                             CHECK_EXPIRATION = ON,
                             CHECK_POLICY = ON
                GO

                -- Windows or Entra principals use FROM instead of a password.
                -- CREATE LOGIN [<Domain_Login, sysname, DOMAIN\\User>] FROM WINDOWS
                -- GO

                ALTER LOGIN <Login_Name, sysname, MyLogin> <Login_State, , ENABLE>
                GO
                """),

            SQLTemplate(id: "security.user", category: securityCategory, name: "Create User", body: """
                -- =========================================================
                -- Database principal
                -- =========================================================
                USE <Database_Name, sysname, MyDatabase>
                GO

                IF NOT EXISTS (SELECT 1 FROM sys.database_principals
                               WHERE name = N'<User_Name, sysname, MyUser>')
                    CREATE USER <User_Name, sysname, MyUser>
                        FOR LOGIN <Login_Name, sysname, MyLogin>
                        WITH DEFAULT_SCHEMA = <Default_Schema, sysname, dbo>
                GO

                -- Contained database user, no server login involved:
                -- CREATE USER <User_Name, sysname, MyUser>
                --     WITH PASSWORD = N'<Password, sysname, StrongPassword1!>'
                -- GO

                -- Orphaned users after a restore show a NULL login here.
                SELECT  dp.name AS UserName, dp.type_desc, sp.name AS LoginName
                FROM sys.database_principals AS dp
                LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
                WHERE dp.type IN ('S', 'U', 'G')
                  AND dp.principal_id > 4
                GO
                """),

            SQLTemplate(id: "security.rolemember", category: securityCategory,
                        name: "Add Role Member", body: """
                -- =========================================================
                -- Role membership
                -- =========================================================
                USE <Database_Name, sysname, MyDatabase>
                GO

                IF NOT EXISTS (SELECT 1 FROM sys.database_principals
                               WHERE name = N'<Role_Name, sysname, MyRole>' AND type = 'R')
                    CREATE ROLE <Role_Name, sysname, MyRole> AUTHORIZATION <Role_Owner, sysname, dbo>
                GO

                ALTER ROLE <Role_Name, sysname, MyRole> ADD MEMBER <User_Name, sysname, MyUser>
                GO

                -- Server level role:
                -- ALTER SERVER ROLE <Server_Role, sysname, dbcreator> ADD MEMBER <Login_Name, sysname, MyLogin>
                -- GO

                SELECT  r.name AS RoleName, m.name AS MemberName
                FROM sys.database_role_members AS drm
                INNER JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
                INNER JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
                ORDER BY r.name, m.name
                GO
                """),

            SQLTemplate(id: "security.grant", category: securityCategory,
                        name: "Grant Permission", body: """
                -- =========================================================
                -- Grant permissions
                -- =========================================================
                USE <Database_Name, sysname, MyDatabase>
                GO

                GRANT <Object_Permission, , SELECT, INSERT, UPDATE, DELETE>
                    ON <Schema_Name, sysname, dbo>.<Object_Name, sysname, MyTable>
                    TO <Principal_Name, sysname, MyRole>
                GO

                GRANT EXECUTE
                    ON <Schema_Name, sysname, dbo>.<Procedure_Name, sysname, MyProcedure>
                    TO <Principal_Name, sysname, MyRole>
                GO

                -- Schema level grants cover objects created later, which is usually what
                -- an application role actually needs.
                GRANT <Schema_Permission, , SELECT, EXECUTE>
                    ON SCHEMA::<Schema_Name, sysname, dbo>
                    TO <Principal_Name, sysname, MyRole>
                GO

                SELECT  pe.class_desc, pe.permission_name, pe.state_desc,
                        OBJECT_SCHEMA_NAME(pe.major_id) AS SchemaName,
                        OBJECT_NAME(pe.major_id) AS ObjectName,
                        pr.name AS Grantee
                FROM sys.database_permissions AS pe
                INNER JOIN sys.database_principals AS pr ON pr.principal_id = pe.grantee_principal_id
                WHERE pr.name = N'<Principal_Name, sysname, MyRole>'
                GO
                """),

            SQLTemplate(id: "security.revoke", category: securityCategory,
                        name: "Revoke or Deny Permission", body: """
                -- =========================================================
                -- Revoke and deny
                -- =========================================================
                USE <Database_Name, sysname, MyDatabase>
                GO

                -- REVOKE removes a previous GRANT or DENY.
                REVOKE <Object_Permission, , SELECT, INSERT, UPDATE, DELETE>
                    ON <Schema_Name, sysname, dbo>.<Object_Name, sysname, MyTable>
                    FROM <Principal_Name, sysname, MyRole>
                    CASCADE
                GO

                -- DENY outranks any GRANT the principal picks up through a role.
                DENY <Object_Permission, , SELECT, INSERT, UPDATE, DELETE>
                    ON <Schema_Name, sysname, dbo>.<Object_Name, sysname, MyTable>
                    TO <Principal_Name, sysname, MyRole>
                GO

                ALTER ROLE <Role_Name, sysname, MyRole> DROP MEMBER <User_Name, sysname, MyUser>
                GO
                """)
        ]
    }
}

// MARK: - Statistics and maintenance

extension SQLTemplates {

    private static let maintenanceCategory = "Statistics and Maintenance"

    private static var maintenanceTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "maintenance.statistics", category: maintenanceCategory,
                        name: "Update Statistics", body: """
                -- =========================================================
                -- Statistics
                -- =========================================================
                SELECT  OBJECT_SCHEMA_NAME(s.object_id) AS SchemaName,
                        OBJECT_NAME(s.object_id) AS TableName,
                        s.name AS StatisticsName,
                        sp.last_updated,
                        sp.rows,
                        sp.rows_sampled,
                        sp.modification_counter
                FROM sys.stats AS s
                CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
                WHERE s.object_id > 100
                  AND sp.modification_counter >= <Modification_Threshold, int, 1000>
                ORDER BY sp.modification_counter DESC
                GO

                UPDATE STATISTICS <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                    WITH <Sample_Clause, , FULLSCAN>
                GO

                -- Every statistic in the database; MAXDOP is 2016 SP1 and later.
                EXEC sp_updatestats
                GO
                """),

            SQLTemplate(id: "maintenance.rebuildall", category: maintenanceCategory,
                        name: "Rebuild All Indexes", body: """
                -- =========================================================
                -- Fragmentation sweep over the whole database
                -- =========================================================
                SET NOCOUNT ON

                DECLARE @Threshold float = <Fragmentation_Threshold, float, 30>
                DECLARE @MinPages int = <Minimum_Pages, int, 1000>
                DECLARE @Online nvarchar(3) = N'<Online, , OFF>'
                DECLARE @Sql nvarchar(max)

                DECLARE IndexCursor CURSOR LOCAL FAST_FORWARD FOR
                    SELECT  N'ALTER INDEX ' + QUOTENAME(i.name) + N' ON ' +
                            QUOTENAME(OBJECT_SCHEMA_NAME(i.object_id)) + N'.' +
                            QUOTENAME(OBJECT_NAME(i.object_id)) +
                            CASE WHEN ips.avg_fragmentation_in_percent >= @Threshold
                                 THEN N' REBUILD WITH (SORT_IN_TEMPDB = ON, ONLINE = ' + @Online + N')'
                                 ELSE N' REORGANIZE'
                            END
                    FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, N'LIMITED') AS ips
                    INNER JOIN sys.indexes AS i
                            ON i.object_id = ips.object_id
                           AND i.index_id = ips.index_id
                    WHERE i.index_id > 0
                      AND i.is_disabled = 0
                      AND i.name IS NOT NULL
                      AND ips.page_count >= @MinPages
                      AND ips.avg_fragmentation_in_percent >= <Reorganize_Threshold, float, 5>

                OPEN IndexCursor
                FETCH NEXT FROM IndexCursor INTO @Sql

                WHILE @@FETCH_STATUS = 0
                BEGIN
                    PRINT @Sql
                    EXEC sp_executesql @Sql
                    FETCH NEXT FROM IndexCursor INTO @Sql
                END

                CLOSE IndexCursor
                DEALLOCATE IndexCursor
                GO
                """),

            SQLTemplate(id: "maintenance.checkdb", category: maintenanceCategory,
                        name: "Check Database Integrity", body: """
                -- =========================================================
                -- Consistency checks
                -- =========================================================
                DBCC CHECKDB (N'<Database_Name, sysname, MyDatabase>')
                    WITH NO_INFOMSGS, ALL_ERRORMSGS, <Check_Option, , DATA_PURITY>
                GO

                -- Cheaper daily variant: allocation and catalogue only.
                DBCC CHECKALLOC (N'<Database_Name, sysname, MyDatabase>') WITH NO_INFOMSGS
                GO
                DBCC CHECKCATALOG (N'<Database_Name, sysname, MyDatabase>') WITH NO_INFOMSGS
                GO

                -- Last known good check; a 1900 date means CHECKDB never completed cleanly.
                DBCC DBINFO (N'<Database_Name, sysname, MyDatabase>') WITH TABLERESULTS, NO_INFOMSGS
                GO

                SELECT  DB_NAME(database_id) AS DatabaseName,
                        file_id, page_id, event_type, error_count, last_update_date
                FROM msdb.dbo.suspect_pages
                GO
                """)
        ]
    }
}

// MARK: - Query

extension SQLTemplates {

    private static let queryCategory = "Query"

    private static var queryTemplates: [SQLTemplate] {
        [
            SQLTemplate(id: "query.paging", category: queryCategory,
                        name: "Select with Paging (OFFSET / FETCH)", body: """
                -- =========================================================
                -- Server side paging
                -- =========================================================
                DECLARE @PageNumber int = <Page_Number, int, 1>
                DECLARE @PageSize int = <Page_Size, int, 50>

                SELECT  <Column_List, , *>
                FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                WHERE <Filter_Predicate, , 1 = 1>
                -- ORDER BY must be deterministic or rows can repeat across pages.
                ORDER BY <Order_By_Column, sysname, Id> ASC
                OFFSET (@PageNumber - 1) * @PageSize ROWS
                FETCH NEXT @PageSize ROWS ONLY
                OPTION (OPTIMIZE FOR (@PageNumber = 1))

                SELECT COUNT_BIG(*) AS TotalRows
                FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable>
                WHERE <Filter_Predicate, , 1 = 1>
                GO
                """),

            SQLTemplate(id: "query.merge", category: queryCategory,
                        name: "Upsert with MERGE", body: """
                -- =========================================================
                -- MERGE from a staging table into the target
                -- =========================================================
                SET XACT_ABORT ON

                MERGE <Schema_Name, sysname, dbo>.<Target_Table, sysname, MyTable> WITH (HOLDLOCK) AS tgt
                USING <Schema_Name, sysname, dbo>.<Source_Table, sysname, MyTableStaging> AS src
                    ON tgt.<Key_Column, sysname, Id> = src.<Key_Column, sysname, Id>
                WHEN MATCHED AND EXISTS
                    (
                        -- EXCEPT compares NULLs the way a human expects, unlike <> chains.
                        SELECT src.<Column_1, sysname, Name>, src.<Column_2, sysname, Amount>
                        EXCEPT
                        SELECT tgt.<Column_1, sysname, Name>, tgt.<Column_2, sysname, Amount>
                    )
                    THEN UPDATE SET
                        <Column_1, sysname, Name> = src.<Column_1, sysname, Name>,
                        <Column_2, sysname, Amount> = src.<Column_2, sysname, Amount>
                WHEN NOT MATCHED BY TARGET
                    THEN INSERT (<Key_Column, sysname, Id>,
                                 <Column_1, sysname, Name>,
                                 <Column_2, sysname, Amount>)
                         VALUES (src.<Key_Column, sysname, Id>,
                                 src.<Column_1, sysname, Name>,
                                 src.<Column_2, sysname, Amount>)
                WHEN NOT MATCHED BY SOURCE
                    THEN DELETE
                OUTPUT $action AS Action,
                       inserted.<Key_Column, sysname, Id> AS InsertedId,
                       deleted.<Key_Column, sysname, Id> AS DeletedId;
                GO
                """),

            SQLTemplate(id: "query.pivot", category: queryCategory, name: "Pivot", body: """
                -- =========================================================
                -- PIVOT: turn row values into columns
                -- =========================================================
                SELECT  p.<Row_Column, sysname, CustomerId>,
                        ISNULL(p.[<Pivot_Value_1, , 2024>], 0) AS [<Pivot_Value_1, , 2024>],
                        ISNULL(p.[<Pivot_Value_2, , 2025>], 0) AS [<Pivot_Value_2, , 2025>],
                        ISNULL(p.[<Pivot_Value_3, , 2026>], 0) AS [<Pivot_Value_3, , 2026>]
                FROM
                (
                    SELECT  t.<Row_Column, sysname, CustomerId>,
                            <Pivot_Expression, , YEAR(t.[OrderDate])> AS PivotKey,
                            t.<Value_Column, sysname, Amount> AS PivotValue
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                ) AS src
                PIVOT
                (
                    <Aggregate_Function, , SUM>(src.PivotValue)
                    FOR src.PivotKey IN ([<Pivot_Value_1, , 2024>],
                                         [<Pivot_Value_2, , 2025>],
                                         [<Pivot_Value_3, , 2026>])
                ) AS p
                ORDER BY p.<Row_Column, sysname, CustomerId>
                GO

                -- UNPIVOT reverses the shape.
                SELECT u.<Row_Column, sysname, CustomerId>, u.PivotKey, u.PivotValue
                FROM
                (
                    SELECT  <Row_Column, sysname, CustomerId>,
                            [<Pivot_Value_1, , 2024>],
                            [<Pivot_Value_2, , 2025>]
                    FROM <Schema_Name, sysname, dbo>.<Pivoted_Table, sysname, MyPivotedTable>
                ) AS s
                UNPIVOT
                (
                    PivotValue FOR PivotKey IN ([<Pivot_Value_1, , 2024>], [<Pivot_Value_2, , 2025>])
                ) AS u
                GO
                """),

            SQLTemplate(id: "query.cte", category: queryCategory,
                        name: "Common Table Expression", body: """
                -- =========================================================
                -- CTE, including the deduplicating delete idiom
                -- =========================================================
                WITH <CTE_Name, sysname, Ranked> AS
                (
                    SELECT  t.<Key_Column, sysname, Id>,
                            t.<Group_Column, sysname, CustomerId>,
                            t.<Value_Column, sysname, Amount>,
                            ROW_NUMBER() OVER (PARTITION BY t.<Group_Column, sysname, CustomerId>
                                               ORDER BY t.<Order_Column, sysname, CreatedAt> DESC)
                                AS RowNumber
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                    WHERE <Filter_Predicate, , 1 = 1>
                )
                SELECT  <CTE_Name, sysname, Ranked>.<Key_Column, sysname, Id>,
                        <CTE_Name, sysname, Ranked>.<Group_Column, sysname, CustomerId>,
                        <CTE_Name, sysname, Ranked>.<Value_Column, sysname, Amount>
                FROM <CTE_Name, sysname, Ranked>
                WHERE <CTE_Name, sysname, Ranked>.RowNumber = 1
                ORDER BY <CTE_Name, sysname, Ranked>.<Group_Column, sysname, CustomerId>
                GO

                -- A CTE is updatable, which makes "keep the newest row per group" a one liner.
                -- WITH Ranked AS (...) DELETE FROM Ranked WHERE RowNumber > 1
                """),

            SQLTemplate(id: "query.recursivecte", category: queryCategory,
                        name: "Recursive CTE", body: """
                -- =========================================================
                -- Walk a parent / child hierarchy
                -- =========================================================
                WITH <CTE_Name, sysname, Hierarchy> AS
                (
                    SELECT  t.<Key_Column, sysname, Id>,
                            t.<Parent_Column, sysname, ParentId>,
                            t.<Name_Column, sysname, Name>,
                            0 AS Depth,
                            CAST(t.<Name_Column, sysname, Name> AS nvarchar(4000)) AS Path
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                    WHERE t.<Parent_Column, sysname, ParentId> IS NULL

                    UNION ALL

                    SELECT  c.<Key_Column, sysname, Id>,
                            c.<Parent_Column, sysname, ParentId>,
                            c.<Name_Column, sysname, Name>,
                            p.Depth + 1,
                            CAST(p.Path + N' / ' + c.<Name_Column, sysname, Name> AS nvarchar(4000))
                    FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS c
                    INNER JOIN <CTE_Name, sysname, Hierarchy> AS p
                            ON p.<Key_Column, sysname, Id> = c.<Parent_Column, sysname, ParentId>
                    WHERE p.Depth < <Maximum_Depth, int, 32>
                )
                SELECT  <CTE_Name, sysname, Hierarchy>.<Key_Column, sysname, Id>,
                        REPLICATE(N'    ', Depth) + <Name_Column, sysname, Name> AS Indented,
                        Depth,
                        Path
                FROM <CTE_Name, sysname, Hierarchy>
                ORDER BY Path
                -- The default recursion limit is 100; 0 means unlimited.
                OPTION (MAXRECURSION <Maximum_Depth, int, 32>)
                GO
                """),

            SQLTemplate(id: "query.window", category: queryCategory,
                        name: "Window Functions", body: """
                -- =========================================================
                -- Ranking, running totals and offsets in one pass
                -- =========================================================
                SELECT  t.<Partition_Column, sysname, CustomerId>,
                        t.<Order_Column, sysname, OrderDate>,
                        t.<Value_Column, sysname, Amount>,

                        ROW_NUMBER() OVER (PARTITION BY t.<Partition_Column, sysname, CustomerId>
                                           ORDER BY t.<Order_Column, sysname, OrderDate> DESC) AS RowNumber,
                        RANK() OVER (PARTITION BY t.<Partition_Column, sysname, CustomerId>
                                     ORDER BY t.<Value_Column, sysname, Amount> DESC) AS AmountRank,
                        NTILE(<Bucket_Count, int, 4>) OVER (ORDER BY t.<Value_Column, sysname, Amount>)
                            AS Quartile,

                        -- ROWS beats the default RANGE frame: no ties peeking, and no
                        -- on-disk spool for the running total.
                        SUM(t.<Value_Column, sysname, Amount>) OVER (
                            PARTITION BY t.<Partition_Column, sysname, CustomerId>
                            ORDER BY t.<Order_Column, sysname, OrderDate>
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RunningTotal,
                        AVG(t.<Value_Column, sysname, Amount>) OVER (
                            PARTITION BY t.<Partition_Column, sysname, CustomerId>
                            ORDER BY t.<Order_Column, sysname, OrderDate>
                            ROWS BETWEEN <Moving_Window, int, 2> PRECEDING AND CURRENT ROW) AS MovingAverage,

                        LAG(t.<Value_Column, sysname, Amount>, 1, 0) OVER (
                            PARTITION BY t.<Partition_Column, sysname, CustomerId>
                            ORDER BY t.<Order_Column, sysname, OrderDate>) AS PreviousAmount,
                        LEAD(t.<Value_Column, sysname, Amount>, 1, 0) OVER (
                            PARTITION BY t.<Partition_Column, sysname, CustomerId>
                            ORDER BY t.<Order_Column, sysname, OrderDate>) AS NextAmount
                FROM <Schema_Name, sysname, dbo>.<Table_Name, sysname, MyTable> AS t
                WHERE <Filter_Predicate, , 1 = 1>
                ORDER BY t.<Partition_Column, sysname, CustomerId>,
                         t.<Order_Column, sysname, OrderDate>
                GO
                """)
        ]
    }
}
