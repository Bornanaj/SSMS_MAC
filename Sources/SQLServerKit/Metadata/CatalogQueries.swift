import Foundation

/// Every T-SQL string the Object Explorer sends.
///
/// The queries are collected here so they can be reviewed as a set against the
/// supported matrix: SQL Server 2016 through 2022 plus Azure SQL Database.
///
/// Two rules shape the SQL:
///
/// * Catalog views that do not exist everywhere (`sys.credentials`, `sys.servers`,
///   `sys.endpoints`, `msdb.dbo.sysjobs`) are wrapped in `whenExists`. A batch is
///   name-resolved as a whole, so an `IF` guard alone would still fail to compile;
///   pushing the body through `sp_executesql` defers resolution until the branch
///   actually runs.
/// * String aggregation uses `FOR XML PATH` rather than `STRING_AGG`, which only
///   arrived in SQL Server 2017.
public enum CatalogQueries {

    // MARK: - Shared fragments

    /// Which slice of `sys.databases` a databases query should return.
    public enum DatabaseScope: Sendable {
        case system
        case user
        case all
    }

    /// The four names SSMS files under "System Databases".
    public static let systemDatabasePredicate = "d.name IN (N'master', N'model', N'msdb', N'tempdb')"

    /// `TOP (n) ` with a sane clamp, so a bad options value cannot produce invalid SQL.
    public static func top(_ maxChildren: Int) -> String {
        "TOP (\(min(max(maxChildren, 1), 1_000_000))) "
    }

    /// `AND <column> LIKE N'%text%' ESCAPE N'\'` for the Object Explorer filter box.
    ///
    /// LIKE metacharacters in the user's text are escaped so that typing `%` filters
    /// for a literal percent sign instead of matching everything.
    public static func nameFilter(_ column: String, _ filter: String?) -> String {
        guard let pattern = likePattern(filter) else { return "" }
        return " AND \(column) LIKE \(pattern) ESCAPE N'\\'"
    }

    /// The bare `N'%text%'` literal, for queries that need the filter in a different position.
    public static func likePattern(_ filter: String?) -> String? {
        guard let filter else { return nil }
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var escaped = ""
        for character in trimmed {
            if character == "\\" || character == "%" || character == "_" || character == "[" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return SQLIdentifier.literal("%" + escaped + "%")
    }

    /// Run `sql` only when `object` resolves on this server, without breaking batch compilation.
    ///
    /// When the view is missing the batch simply produces no result set, which the
    /// metadata service reads as "this platform has no such concept".
    public static func whenExists(_ object: String, _ sql: String) -> String {
        let inner = sql.replacingOccurrences(of: "'", with: "''")
        return """
        IF OBJECT_ID(N'\(object)') IS NOT NULL
            EXEC sys.sp_executesql N'\(inner)';
        """
    }

    /// Comma separated key column list for an index, oldest-supported-syntax flavour.
    private static func indexColumnList(included: Bool) -> String {
        """
        ISNULL(STUFF((SELECT N', ' + xc.name
                              + CASE WHEN xic.is_descending_key = 1 THEN N' DESC' ELSE N'' END
                      FROM sys.index_columns AS xic
                      JOIN sys.columns AS xc
                        ON xc.object_id = xic.object_id AND xc.column_id = xic.column_id
                      WHERE xic.object_id = i.object_id
                        AND xic.index_id = i.index_id
                        AND xic.is_included_column = \(included ? 1 : 0)
                      ORDER BY \(included ? "xic.index_column_id" : "xic.key_ordinal")
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
        """
    }

    /// `sys.types` resolution shared by columns, parameters and user-defined types.
    private static let typeJoins = """
    LEFT JOIN sys.types AS ut ON ut.user_type_id = %ALIAS%.user_type_id
    LEFT JOIN sys.types AS bt ON bt.user_type_id = ut.system_type_id AND bt.is_user_defined = 0
    LEFT JOIN sys.schemas AS ts ON ts.schema_id = ut.schema_id
    """

    private static func typeJoins(for alias: String) -> String {
        typeJoins.replacingOccurrences(of: "%ALIAS%", with: alias)
    }

    // MARK: - Databases

    public static func databases(scope: DatabaseScope, options: ObjectExplorerOptions) -> String {
        let scopePredicate: String
        switch scope {
        case .system: scopePredicate = systemDatabasePredicate
        case .user: scopePredicate = "NOT \(systemDatabasePredicate)"
        case .all: scopePredicate = "1 = 1"
        }
        return """
        SELECT \(top(options.maxChildren))
            d.database_id                                            AS DatabaseId,
            d.name                                                   AS DatabaseName,
            d.state_desc                                             AS StateDesc,
            d.recovery_model_desc                                    AS RecoveryModel,
            CAST(d.compatibility_level AS int)                       AS CompatibilityLevel,
            ISNULL(d.collation_name, N'')                            AS CollationName,
            CAST(d.is_read_only AS int)                              AS IsReadOnly,
            d.user_access_desc                                       AS UserAccess,
            CONVERT(nvarchar(30), d.create_date, 120)                AS CreateDate,
            ISNULL(SUSER_SNAME(d.owner_sid), N'')                    AS OwnerName,
            CASE WHEN \(systemDatabasePredicate) THEN 1 ELSE 0 END   AS IsSystem
        FROM sys.databases AS d
        WHERE \(scopePredicate)\(nameFilter("d.name", options.nameFilter))
        ORDER BY d.name;
        """
    }

    /// Lightweight variant for the database picker in the toolbar.
    public static func databaseNames(includeSystem: Bool) -> String {
        let predicate = includeSystem ? "1 = 1" : "NOT \(systemDatabasePredicate)"
        return """
        SELECT d.name AS DatabaseName
        FROM sys.databases AS d
        WHERE \(predicate) AND d.state_desc = N'ONLINE'
        ORDER BY d.name;
        """
    }

    // MARK: - Tables and views

    public static func tables(systemObjects: Bool, options: ObjectExplorerOptions) -> String {
        let predicate = systemObjects
            ? "(t.is_ms_shipped = 1 OR s.name = N'sys')"
            : "(t.is_ms_shipped = 0 AND s.name <> N'sys')"
        return """
        SELECT \(top(options.maxChildren))
            t.object_id                                     AS ObjectId,
            s.name                                          AS SchemaName,
            t.name                                          AS TableName,
            CONVERT(nvarchar(30), t.create_date, 120)       AS CreateDate,
            CONVERT(nvarchar(30), t.modify_date, 120)       AS ModifyDate,
            CAST(t.is_ms_shipped AS int)                    AS IsMSShipped,
            CAST(t.is_external AS int)                      AS IsExternal,
            CAST(t.is_filetable AS int)                     AS IsFileTable,
            CAST(t.is_memory_optimized AS int)              AS IsMemoryOptimized,
            CAST(t.temporal_type AS int)                    AS TemporalType,
            ISNULL(CAST(ep.value AS nvarchar(4000)), N'')   AS ObjectDescription
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        LEFT JOIN sys.extended_properties AS ep
               ON ep.class = 1 AND ep.major_id = t.object_id AND ep.minor_id = 0
              AND ep.name = N'MS_Description'
        WHERE \(predicate)\(nameFilter("t.name", options.nameFilter))
        ORDER BY s.name, t.name;
        """
    }

    public static func views(systemObjects: Bool, options: ObjectExplorerOptions) -> String {
        let predicate = systemObjects
            ? "(v.is_ms_shipped = 1 OR s.name IN (N'sys', N'INFORMATION_SCHEMA'))"
            : "(v.is_ms_shipped = 0 AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA'))"
        return """
        SELECT \(top(options.maxChildren))
            v.object_id                                     AS ObjectId,
            s.name                                          AS SchemaName,
            v.name                                          AS ViewName,
            CONVERT(nvarchar(30), v.create_date, 120)       AS CreateDate,
            CONVERT(nvarchar(30), v.modify_date, 120)       AS ModifyDate,
            CAST(v.is_ms_shipped AS int)                    AS IsMSShipped,
            CAST(v.with_check_option AS int)                AS WithCheckOption,
            ISNULL(CAST(ep.value AS nvarchar(4000)), N'')   AS ObjectDescription
        FROM sys.all_views AS v
        JOIN sys.schemas AS s ON s.schema_id = v.schema_id
        LEFT JOIN sys.extended_properties AS ep
               ON ep.class = 1 AND ep.major_id = v.object_id AND ep.minor_id = 0
              AND ep.name = N'MS_Description'
        WHERE \(predicate)\(nameFilter("v.name", options.nameFilter))
        ORDER BY s.name, v.name;
        """
    }

    // MARK: - Columns

    public static func columns(objectID: Int) -> String {
        columnsBody(objectExpression: "\(objectID)")
    }

    public static func columns(schema: String, table: String) -> String {
        let quoted = SQLIdentifier.quote(schema: schema, name: table)
        return columnsBody(objectExpression: "OBJECT_ID(\(SQLIdentifier.literal(quoted)))")
    }

    private static func columnsBody(objectExpression: String) -> String {
        """
        SELECT
            c.column_id                                     AS ColumnId,
            c.name                                          AS ColumnName,
            CAST(c.is_nullable AS int)                      AS IsNullable,
            CAST(c.is_identity AS int)                      AS IsIdentity,
            CAST(c.is_computed AS int)                      AS IsComputed,
            CAST(c.is_rowguidcol AS int)                    AS IsRowGuidCol,
            CAST(c.is_sparse AS int)                        AS IsSparse,
            CAST(c.is_filestream AS int)                    AS IsFileStream,
            CAST(c.generated_always_type AS int)            AS GeneratedAlwaysType,
            ISNULL(c.collation_name, N'')                   AS CollationName,
            CAST(c.max_length AS int)                       AS MaxLength,
            CAST(c.precision AS int)                        AS TypePrecision,
            CAST(c.scale AS int)                            AS TypeScale,
            ISNULL(ut.name, N'')                            AS TypeName,
            ISNULL(bt.name, ISNULL(ut.name, N''))           AS BaseTypeName,
            ISNULL(ts.name, N'')                            AS TypeSchema,
            CAST(ISNULL(ut.is_user_defined, 0) AS int)      AS IsUserDefinedType,
            ISNULL(dc.definition, N'')                      AS DefaultDefinition,
            ISNULL(cc.definition, N'')                      AS ComputedDefinition,
            ISNULL(CONVERT(nvarchar(64), ic.seed_value), N'')      AS IdentitySeed,
            ISNULL(CONVERT(nvarchar(64), ic.increment_value), N'') AS IdentityIncrement,
            CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END       AS IsPrimaryKey,
            ISNULL(CAST(ep.value AS nvarchar(4000)), N'')          AS ColumnDescription
        FROM sys.all_columns AS c
        \(typeJoins(for: "c"))
        LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
        LEFT JOIN sys.computed_columns AS cc
               ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns AS ic
               ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        LEFT JOIN (
            SELECT xic.object_id, xic.column_id
            FROM sys.index_columns AS xic
            JOIN sys.indexes AS xi
              ON xi.object_id = xic.object_id AND xi.index_id = xic.index_id
            WHERE xi.is_primary_key = 1
        ) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        LEFT JOIN sys.extended_properties AS ep
               ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id
              AND ep.name = N'MS_Description'
        WHERE c.object_id = \(objectExpression)
        ORDER BY c.column_id;
        """
    }

    // MARK: - Keys, constraints, indexes

    /// Primary/unique key constraints and foreign keys in one round trip.
    public static func keys(objectID: Int) -> String {
        """
        SELECT
            CASE WHEN kc.type = 'PK' THEN 0 ELSE 1 END      AS SortRank,
            kc.name                                         AS KeyName,
            kc.object_id                                    AS KeyObjectId,
            CASE WHEN kc.type = 'PK' THEN N'PK' ELSE N'UQ' END AS KeyType,
            CAST(0 AS int)                                  AS IsDisabled,
            CAST(0 AS int)                                  AS IsNotTrusted,
            N''                                             AS DeleteAction,
            N''                                             AS UpdateAction,
            N''                                             AS ReferencedSchema,
            N''                                             AS ReferencedTable,
            ISNULL(i.type_desc, N'')                        AS TypeDesc,
            ISNULL(STUFF((SELECT N', ' + kcc.name
                          FROM sys.index_columns AS kic
                          JOIN sys.columns AS kcc
                            ON kcc.object_id = kic.object_id AND kcc.column_id = kic.column_id
                          WHERE kic.object_id = kc.parent_object_id
                            AND kic.index_id = kc.unique_index_id
                            AND kic.is_included_column = 0
                          ORDER BY kic.key_ordinal
                          FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
                                                            AS KeyColumns
        FROM sys.key_constraints AS kc
        LEFT JOIN sys.indexes AS i
               ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
        WHERE kc.parent_object_id = \(objectID)
        UNION ALL
        SELECT
            2,
            fk.name,
            fk.object_id,
            N'FK',
            CAST(fk.is_disabled AS int),
            CAST(fk.is_not_trusted AS int),
            fk.delete_referential_action_desc,
            fk.update_referential_action_desc,
            rs.name,
            ro.name,
            N'',
            ISNULL(STUFF((SELECT N', ' + fc.name
                          FROM sys.foreign_key_columns AS fkc
                          JOIN sys.columns AS fc
                            ON fc.object_id = fkc.parent_object_id
                           AND fc.column_id = fkc.parent_column_id
                          WHERE fkc.constraint_object_id = fk.object_id
                          ORDER BY fkc.constraint_column_id
                          FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS ro ON ro.object_id = fk.referenced_object_id
        JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id
        WHERE fk.parent_object_id = \(objectID)
        ORDER BY SortRank, KeyName;
        """
    }

    /// Check and default constraints in one round trip.
    public static func constraints(objectID: Int) -> String {
        """
        SELECT
            CAST(0 AS int)                      AS SortRank,
            cc.name                             AS ConstraintName,
            cc.object_id                        AS ConstraintObjectId,
            N'CHECK'                            AS ConstraintType,
            ISNULL(cc.definition, N'')          AS Definition,
            CAST(cc.is_disabled AS int)         AS IsDisabled,
            CAST(cc.is_not_trusted AS int)      AS IsNotTrusted,
            N''                                 AS ColumnName
        FROM sys.check_constraints AS cc
        WHERE cc.parent_object_id = \(objectID)
        UNION ALL
        SELECT
            CAST(1 AS int),
            dc.name,
            dc.object_id,
            N'DEFAULT',
            ISNULL(dc.definition, N''),
            CAST(0 AS int),
            CAST(0 AS int),
            ISNULL(c.name, N'')
        FROM sys.default_constraints AS dc
        LEFT JOIN sys.columns AS c
               ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
        WHERE dc.parent_object_id = \(objectID)
        ORDER BY SortRank, ConstraintName;
        """
    }

    public static func indexes(objectID: Int) -> String {
        """
        SELECT
            i.index_id                          AS IndexId,
            ISNULL(i.name, N'')                 AS IndexName,
            i.type_desc                         AS TypeDesc,
            CAST(i.type AS int)                 AS IndexType,
            CAST(i.is_unique AS int)            AS IsUnique,
            CAST(i.is_primary_key AS int)       AS IsPrimaryKey,
            CAST(i.is_unique_constraint AS int) AS IsUniqueConstraint,
            CAST(i.is_disabled AS int)          AS IsDisabled,
            CAST(i.is_padded AS int)            AS IsPadded,
            CAST(i.fill_factor AS int)          AS FillFactor,
            CAST(i.has_filter AS int)           AS HasFilter,
            ISNULL(i.filter_definition, N'')    AS FilterDefinition,
            ISNULL(ds.name, N'')                AS DataSpaceName,
            \(indexColumnList(included: false)) AS KeyColumns,
            \(indexColumnList(included: true))  AS IncludedColumns
        FROM sys.indexes AS i
        LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        WHERE i.object_id = \(objectID) AND i.index_id > 0 AND i.name IS NOT NULL
        ORDER BY i.is_primary_key DESC, i.name;
        """
    }

    public static func statistics(objectID: Int) -> String {
        """
        SELECT
            st.stats_id                         AS StatsId,
            st.name                             AS StatsName,
            CAST(st.auto_created AS int)        AS AutoCreated,
            CAST(st.user_created AS int)        AS UserCreated,
            CAST(st.no_recompute AS int)        AS NoRecompute,
            CAST(st.has_filter AS int)          AS HasFilter,
            ISNULL(st.filter_definition, N'')   AS FilterDefinition,
            ISNULL(STUFF((SELECT N', ' + sc2.name
                          FROM sys.stats_columns AS sc
                          JOIN sys.columns AS sc2
                            ON sc2.object_id = sc.object_id AND sc2.column_id = sc.column_id
                          WHERE sc.object_id = st.object_id AND sc.stats_id = st.stats_id
                          ORDER BY sc.stats_column_id
                          FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
                                                AS StatsColumns
        FROM sys.stats AS st
        WHERE st.object_id = \(objectID)
        ORDER BY st.name;
        """
    }

    // MARK: - Triggers

    public static func objectTriggers(objectID: Int) -> String {
        triggersBody(scope: "tr.parent_class = 1 AND tr.parent_id = \(objectID)", options: nil)
    }

    public static func databaseTriggers(options: ObjectExplorerOptions) -> String {
        triggersBody(scope: "tr.parent_class = 0", options: options)
    }

    private static func triggersBody(scope: String, options: ObjectExplorerOptions?) -> String {
        let limit = options.map { top($0.maxChildren) } ?? ""
        let filter = options.map { nameFilter("tr.name", $0.nameFilter) } ?? ""
        return """
        SELECT \(limit)
            tr.object_id                            AS ObjectId,
            tr.name                                 AS TriggerName,
            CAST(tr.is_disabled AS int)             AS IsDisabled,
            CAST(tr.is_instead_of_trigger AS int)   AS IsInsteadOf,
            tr.type_desc                            AS TypeDesc,
            CAST(tr.is_ms_shipped AS int)           AS IsMSShipped,
            ISNULL(STUFF((SELECT N', ' + te.type_desc
                          FROM sys.trigger_events AS te
                          WHERE te.object_id = tr.object_id
                          FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
                                                    AS EventList
        FROM sys.triggers AS tr
        WHERE \(scope)\(filter)
        ORDER BY tr.name;
        """
    }

    // MARK: - Programmability

    public static func procedures(systemObjects: Bool, options: ObjectExplorerOptions) -> String {
        modulesBody(types: "'P', 'PC', 'X'", systemObjects: systemObjects, options: options)
    }

    /// SQL Server object type codes for each Functions sub-folder.
    public enum FunctionGroup: String, Sendable, Hashable {
        case tableValued
        case scalarValued
        case aggregate
        case system

        var typeList: String {
            switch self {
            case .tableValued: return "'IF', 'TF', 'FT'"
            case .scalarValued: return "'FN', 'FS'"
            case .aggregate: return "'AF'"
            case .system: return "'IF', 'TF', 'FT', 'FN', 'FS', 'AF'"
            }
        }
    }

    public static func functions(group: FunctionGroup, options: ObjectExplorerOptions) -> String {
        modulesBody(types: group.typeList, systemObjects: group == .system, options: options)
    }

    /// Shared shape for procedures and functions. `sys.all_objects` is used so the
    /// System folders can reach the resource-database modules.
    private static func modulesBody(types: String,
                                    systemObjects: Bool,
                                    options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            o.object_id                                 AS ObjectId,
            s.name                                      AS SchemaName,
            o.name                                      AS ObjectName,
            RTRIM(o.type)                               AS ObjectType,
            o.type_desc                                 AS TypeDesc,
            CONVERT(nvarchar(30), o.create_date, 120)   AS CreateDate,
            CONVERT(nvarchar(30), o.modify_date, 120)   AS ModifyDate,
            CAST(o.is_ms_shipped AS int)                AS IsMSShipped
        FROM sys.all_objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.type IN (\(types))
          AND o.is_ms_shipped = \(systemObjects ? 1 : 0)\(nameFilter("o.name", options.nameFilter))
        ORDER BY s.name, o.name;
        """
    }

    public static func parameters(objectID: Int) -> String {
        """
        SELECT
            p.parameter_id                                  AS ParameterId,
            p.name                                          AS ParameterName,
            CAST(p.is_output AS int)                        AS IsOutput,
            CAST(p.is_readonly AS int)                      AS IsReadOnly,
            CAST(p.has_default_value AS int)                AS HasDefaultValue,
            ISNULL(CONVERT(nvarchar(256), p.default_value), N'') AS DefaultValue,
            CAST(p.max_length AS int)                       AS MaxLength,
            CAST(p.precision AS int)                        AS TypePrecision,
            CAST(p.scale AS int)                            AS TypeScale,
            ISNULL(ut.name, N'')                            AS TypeName,
            ISNULL(bt.name, ISNULL(ut.name, N''))           AS BaseTypeName,
            ISNULL(ts.name, N'')                            AS TypeSchema,
            CAST(ISNULL(ut.is_user_defined, 0) AS int)      AS IsUserDefinedType
        FROM sys.all_parameters AS p
        \(typeJoins(for: "p"))
        WHERE p.object_id = \(objectID) AND p.parameter_id > 0
        ORDER BY p.parameter_id;
        """
    }

    public static func synonyms(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            sy.object_id                        AS ObjectId,
            s.name                              AS SchemaName,
            sy.name                             AS SynonymName,
            ISNULL(sy.base_object_name, N'')    AS BaseObjectName
        FROM sys.synonyms AS sy
        JOIN sys.schemas AS s ON s.schema_id = sy.schema_id
        WHERE 1 = 1\(nameFilter("sy.name", options.nameFilter))
        ORDER BY s.name, sy.name;
        """
    }

    public static func sequences(options: ObjectExplorerOptions) -> String {
        whenExists("sys.sequences", """
        SELECT \(top(options.maxChildren))
            sq.object_id                                        AS ObjectId,
            s.name                                              AS SchemaName,
            sq.name                                             AS SequenceName,
            ISNULL(t.name, N'')                                 AS TypeName,
            ISNULL(CONVERT(nvarchar(64), sq.start_value), N'')  AS StartValue,
            ISNULL(CONVERT(nvarchar(64), sq.increment), N'')    AS IncrementValue,
            ISNULL(CONVERT(nvarchar(64), sq.current_value), N'') AS CurrentValue,
            ISNULL(CONVERT(nvarchar(64), sq.minimum_value), N'') AS MinimumValue,
            ISNULL(CONVERT(nvarchar(64), sq.maximum_value), N'') AS MaximumValue,
            CAST(sq.is_cycling AS int)                          AS IsCycling,
            CAST(ISNULL(sq.cache_size, 0) AS int)               AS CacheSize
        FROM sys.sequences AS sq
        JOIN sys.schemas AS s ON s.schema_id = sq.schema_id
        LEFT JOIN sys.types AS t ON t.user_type_id = sq.user_type_id
        WHERE 1 = 1\(nameFilter("sq.name", options.nameFilter))
        ORDER BY s.name, sq.name;
        """)
    }

    public static func assemblies(options: ObjectExplorerOptions) -> String {
        whenExists("sys.assemblies", """
        SELECT \(top(options.maxChildren))
            a.assembly_id                       AS AssemblyId,
            a.name                              AS AssemblyName,
            a.permission_set_desc               AS PermissionSet,
            ISNULL(a.clr_name, N'')             AS ClrName,
            CAST(a.is_user_defined AS int)      AS IsUserDefined
        FROM sys.assemblies AS a
        WHERE a.is_user_defined = 1\(nameFilter("a.name", options.nameFilter))
        ORDER BY a.name;
        """)
    }

    public static func xmlSchemaCollections(systemObjects: Bool,
                                           options: ObjectExplorerOptions) -> String {
        let predicate = systemObjects ? "1 = 1" : "s.name <> N'sys'"
        return """
        SELECT \(top(options.maxChildren))
            x.xml_collection_id                         AS CollectionId,
            s.name                                      AS SchemaName,
            x.name                                      AS CollectionName,
            CONVERT(nvarchar(30), x.create_date, 120)   AS CreateDate
        FROM sys.xml_schema_collections AS x
        JOIN sys.schemas AS s ON s.schema_id = x.schema_id
        WHERE \(predicate)\(nameFilter("x.name", options.nameFilter))
        ORDER BY s.name, x.name;
        """
    }

    // MARK: - Types

    public static func systemDataTypes(options: ObjectExplorerOptions) -> String {
        scalarTypesBody(predicate: "t.is_user_defined = 0", options: options)
    }

    public static func userDefinedDataTypes(options: ObjectExplorerOptions) -> String {
        scalarTypesBody(predicate: "t.is_user_defined = 1 AND t.is_table_type = 0", options: options)
    }

    private static func scalarTypesBody(predicate: String,
                                        options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            t.user_type_id                          AS TypeId,
            ISNULL(s.name, N'sys')                  AS SchemaName,
            t.name                                  AS TypeName,
            ISNULL(bt.name, t.name)                 AS BaseTypeName,
            CAST(t.max_length AS int)               AS MaxLength,
            CAST(t.precision AS int)                AS TypePrecision,
            CAST(t.scale AS int)                    AS TypeScale,
            CAST(t.is_nullable AS int)              AS IsNullable,
            CAST(t.is_user_defined AS int)          AS IsUserDefinedType,
            ISNULL(t.collation_name, N'')           AS CollationName,
            ISNULL(dc.definition, N'')              AS DefaultDefinition
        FROM sys.types AS t
        LEFT JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        LEFT JOIN sys.types AS bt
               ON bt.user_type_id = t.system_type_id AND bt.is_user_defined = 0
        LEFT JOIN sys.default_constraints AS dc ON dc.object_id = t.default_object_id
        WHERE \(predicate)\(nameFilter("t.name", options.nameFilter))
        ORDER BY t.name;
        """
    }

    public static func userDefinedTableTypes(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            tt.type_table_object_id                 AS ObjectId,
            tt.user_type_id                         AS TypeId,
            s.name                                  AS SchemaName,
            tt.name                                 AS TypeName,
            CAST(tt.is_memory_optimized AS int)     AS IsMemoryOptimized
        FROM sys.table_types AS tt
        JOIN sys.schemas AS s ON s.schema_id = tt.schema_id
        WHERE 1 = 1\(nameFilter("tt.name", options.nameFilter))
        ORDER BY s.name, tt.name;
        """
    }

    // MARK: - Storage

    public static func filegroups(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            fg.data_space_id                    AS DataSpaceId,
            fg.name                             AS FilegroupName,
            fg.type_desc                        AS TypeDesc,
            CAST(fg.is_default AS int)          AS IsDefault,
            CAST(fg.is_read_only AS int)        AS IsReadOnly
        FROM sys.filegroups AS fg
        WHERE 1 = 1\(nameFilter("fg.name", options.nameFilter))
        ORDER BY fg.name;
        """
    }

    public static func databaseFiles(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            f.file_id                                   AS FileId,
            f.name                                      AS LogicalName,
            ISNULL(f.physical_name, N'')                AS PhysicalName,
            f.type_desc                                 AS TypeDesc,
            f.state_desc                                AS StateDesc,
            CAST(CAST(f.size AS bigint) * 8 AS bigint)  AS SizeKB,
            CAST(f.max_size AS int)                     AS MaxSize,
            CAST(f.growth AS int)                       AS Growth,
            CAST(f.is_percent_growth AS int)            AS IsPercentGrowth,
            ISNULL(fg.name, N'')                        AS FilegroupName
        FROM sys.database_files AS f
        LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = f.data_space_id
        WHERE 1 = 1\(nameFilter("f.name", options.nameFilter))
        ORDER BY f.type_desc, f.name;
        """
    }

    public static func partitionSchemes(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            ps.data_space_id            AS DataSpaceId,
            ps.name                     AS SchemeName,
            ISNULL(pf.name, N'')        AS FunctionName
        FROM sys.partition_schemes AS ps
        LEFT JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
        WHERE 1 = 1\(nameFilter("ps.name", options.nameFilter))
        ORDER BY ps.name;
        """
    }

    public static func partitionFunctions(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            pf.function_id                              AS FunctionId,
            pf.name                                     AS FunctionName,
            CAST(pf.fanout AS int)                      AS Fanout,
            CAST(pf.boundary_value_on_right AS int)     AS RangeRight
        FROM sys.partition_functions AS pf
        WHERE 1 = 1\(nameFilter("pf.name", options.nameFilter))
        ORDER BY pf.name;
        """
    }

    // MARK: - Database security

    public static func databaseUsers(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            dp.principal_id                                 AS PrincipalId,
            dp.name                                         AS PrincipalName,
            RTRIM(dp.type)                                  AS PrincipalType,
            dp.type_desc                                    AS TypeDesc,
            ISNULL(dp.default_schema_name, N'')             AS DefaultSchema,
            ISNULL(dp.authentication_type_desc, N'')        AS AuthenticationType,
            CONVERT(nvarchar(30), dp.create_date, 120)      AS CreateDate,
            CASE WHEN dp.name IN (N'sys', N'INFORMATION_SCHEMA') THEN 1 ELSE 0 END AS IsSystem
        FROM sys.database_principals AS dp
        WHERE dp.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X')
        \(nameFilter("dp.name", options.nameFilter))
        ORDER BY dp.name;
        """
    }

    public static func databaseRoles(applicationRoles: Bool,
                                     options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            dp.principal_id                                 AS PrincipalId,
            dp.name                                         AS PrincipalName,
            dp.type_desc                                    AS TypeDesc,
            CAST(dp.is_fixed_role AS int)                   AS IsFixedRole,
            ISNULL(USER_NAME(dp.owning_principal_id), N'')  AS OwnerName,
            ISNULL(dp.default_schema_name, N'')             AS DefaultSchema,
            CONVERT(nvarchar(30), dp.create_date, 120)      AS CreateDate
        FROM sys.database_principals AS dp
        WHERE dp.type = '\(applicationRoles ? "A" : "R")'
        \(nameFilter("dp.name", options.nameFilter))
        ORDER BY dp.name;
        """
    }

    public static func schemas(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            sc.schema_id                                AS SchemaId,
            sc.name                                     AS SchemaName,
            ISNULL(USER_NAME(sc.principal_id), N'')     AS OwnerName,
            CASE WHEN sc.name IN (N'sys', N'INFORMATION_SCHEMA') OR sc.schema_id >= 16384
                 THEN 1 ELSE 0 END                      AS IsSystem
        FROM sys.schemas AS sc
        WHERE 1 = 1\(nameFilter("sc.name", options.nameFilter))
        ORDER BY sc.name;
        """
    }

    // MARK: - Server security and server objects

    public static func logins(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            sp.principal_id                                 AS PrincipalId,
            sp.name                                         AS PrincipalName,
            RTRIM(sp.type)                                  AS PrincipalType,
            sp.type_desc                                    AS TypeDesc,
            CAST(ISNULL(sp.is_disabled, 0) AS int)          AS IsDisabled,
            ISNULL(sp.default_database_name, N'')           AS DefaultDatabase,
            ISNULL(sp.default_language_name, N'')           AS DefaultLanguage,
            CONVERT(nvarchar(30), sp.create_date, 120)      AS CreateDate,
            CASE WHEN sp.name LIKE N'##%'
                   OR sp.name LIKE N'NT AUTHORITY\\%'
                   OR sp.name LIKE N'NT SERVICE\\%' THEN 1 ELSE 0 END AS IsSystem
        FROM sys.server_principals AS sp
        WHERE sp.type IN ('S', 'U', 'G', 'C', 'K', 'E', 'X')
        \(nameFilter("sp.name", options.nameFilter))
        ORDER BY sp.name;
        """
    }

    public static func serverRoles(options: ObjectExplorerOptions) -> String {
        """
        SELECT \(top(options.maxChildren))
            sp.principal_id                                     AS PrincipalId,
            sp.name                                             AS PrincipalName,
            sp.type_desc                                        AS TypeDesc,
            CAST(sp.is_fixed_role AS int)                       AS IsFixedRole,
            ISNULL(SUSER_NAME(sp.owning_principal_id), N'')     AS OwnerName,
            CONVERT(nvarchar(30), sp.create_date, 120)          AS CreateDate
        FROM sys.server_principals AS sp
        WHERE sp.type = 'R'\(nameFilter("sp.name", options.nameFilter))
        ORDER BY sp.name;
        """
    }

    public static func credentials(options: ObjectExplorerOptions) -> String {
        whenExists("sys.credentials", """
        SELECT \(top(options.maxChildren))
            c.credential_id                             AS CredentialId,
            c.name                                      AS CredentialName,
            ISNULL(c.credential_identity, N'')          AS CredentialIdentity,
            CONVERT(nvarchar(30), c.create_date, 120)   AS CreateDate
        FROM sys.credentials AS c
        WHERE 1 = 1\(nameFilter("c.name", options.nameFilter))
        ORDER BY c.name;
        """)
    }

    public static func linkedServers(options: ObjectExplorerOptions) -> String {
        whenExists("sys.servers", """
        SELECT \(top(options.maxChildren))
            s.server_id                     AS ServerId,
            s.name                          AS ServerName,
            ISNULL(s.product, N'')          AS Product,
            ISNULL(s.provider, N'')         AS Provider,
            ISNULL(s.data_source, N'')      AS DataSource,
            ISNULL(s.catalog, N'')          AS CatalogName,
            CAST(s.is_data_access_enabled AS int) AS IsDataAccessEnabled
        FROM sys.servers AS s
        WHERE s.is_linked = 1\(nameFilter("s.name", options.nameFilter))
        ORDER BY s.name;
        """)
    }

    public static func endpoints(options: ObjectExplorerOptions) -> String {
        whenExists("sys.endpoints", """
        SELECT \(top(options.maxChildren))
            e.endpoint_id           AS EndpointId,
            e.name                  AS EndpointName,
            e.type_desc             AS TypeDesc,
            e.state_desc            AS StateDesc,
            e.protocol_desc         AS ProtocolDesc
        FROM sys.endpoints AS e
        WHERE 1 = 1\(nameFilter("e.name", options.nameFilter))
        ORDER BY e.name;
        """)
    }

    public static func agentJobs(options: ObjectExplorerOptions) -> String {
        whenExists("msdb.dbo.sysjobs", """
        SELECT \(top(options.maxChildren))
            CAST(j.job_id AS nvarchar(64))              AS JobId,
            j.name                                      AS JobName,
            CAST(j.enabled AS int)                      AS IsEnabled,
            ISNULL(j.description, N'')                  AS JobDescription,
            ISNULL(SUSER_SNAME(j.owner_sid), N'')       AS OwnerName,
            ISNULL(c.name, N'')                         AS CategoryName,
            CONVERT(nvarchar(30), j.date_created, 120)  AS CreateDate
        FROM msdb.dbo.sysjobs AS j
        LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
        WHERE 1 = 1\(nameFilter("j.name", options.nameFilter))
        ORDER BY j.name;
        """)
    }

    // MARK: - Search

    /// Object and column name search inside one database, in a single round trip.
    public static func search(text: String, limit: Int) -> String {
        // An empty pattern would match everything; callers guard, but keep the SQL safe.
        let pattern = likePattern(text) ?? SQLIdentifier.literal("%")
        return """
        SELECT \(top(limit))
            m.SortRank, m.ObjectId, m.SchemaName, m.ObjectName, m.ParentName,
            m.ObjectType, m.MatchKind
        FROM (
            SELECT
                CAST(0 AS int)      AS SortRank,
                o.object_id         AS ObjectId,
                s.name              AS SchemaName,
                o.name              AS ObjectName,
                CAST(N'' AS nvarchar(128)) AS ParentName,
                CAST(RTRIM(o.type) AS nvarchar(4)) AS ObjectType,
                CAST(N'object' AS nvarchar(8))     AS MatchKind
            FROM sys.objects AS o
            JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE o.is_ms_shipped = 0
              AND o.type IN ('U', 'V', 'P', 'PC', 'FN', 'IF', 'TF', 'FS', 'FT', 'AF', 'SN', 'SO', 'TR')
              AND o.name LIKE \(pattern) ESCAPE N'\\'
            UNION ALL
            SELECT
                CAST(1 AS int),
                c.object_id,
                s2.name,
                c.name,
                CAST(o2.name AS nvarchar(128)),
                CAST(RTRIM(o2.type) AS nvarchar(4)),
                CAST(N'column' AS nvarchar(8))
            FROM sys.columns AS c
            JOIN sys.objects AS o2 ON o2.object_id = c.object_id
            JOIN sys.schemas AS s2 ON s2.schema_id = o2.schema_id
            WHERE o2.is_ms_shipped = 0
              AND o2.type IN ('U', 'V')
              AND c.name LIKE \(pattern) ESCAPE N'\\'
        ) AS m
        ORDER BY m.SortRank, m.SchemaName, m.ObjectName;
        """
    }
}
