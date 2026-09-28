import Foundation
import TDSKit
import SQLServerKit

/// `ssms-compare data`: compare the rows of two databases, then optionally write a
/// synchronization script, deploy it or write a report.
struct DataCommand {
    let args: Arguments

    func run() async throws -> ExitCode {
        let quiet = args.flag("quiet")
        var options = DataCompareOptions()
        var settings = DataProjectSettings()
        if let path = args.string("project") {
            let project = try CompareProject.read(from: URL(fileURLWithPath: path))
            guard let data = project.data else { throw CLIError.usage("\(path) is not a data compare project.") }
            settings = data
            options = data.options
        }
        if let list = args.string("options") {
            let unknown = options.apply(list: list)
            if !unknown.isEmpty { throw CLIError.usage("Unknown option(s): \(unknown.joined(separator: ", "))") }
        }
        for pair in args.all("map-schema") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2 else { throw CLIError.usage("--map-schema expects source=target") }
            settings.schemaMappings.append(SchemaNameMapping(source: parts[0], target: parts[1]))
        }
        for pair in args.all("map-table") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2 else { throw CLIError.usage("--map-table expects schema.source=schema.target") }
            settings.tablePairs[parts[0]] = parts[1]
        }

        let sourceEndpoint = EndpointArguments(prefix: "source", args: args)
        let targetEndpoint = EndpointArguments(prefix: "target", args: args)
        guard let sourceDatabase = sourceEndpoint.database, let targetDatabase = targetEndpoint.database else {
            throw CLIError.usage("Data compare needs --source-server/--source-database and --target-server/--target-database.")
        }
        let sourceSession = try await sourceEndpoint.connect()
        let targetSession = try await targetEndpoint.connect()
        defer {
            Task {
                await sourceSession.close()
                await targetSession.close()
            }
        }

        log("Reading tables…", quiet: quiet)
        let sourceCatalog = try await DataCompareCatalog(session: sourceSession).read(database: sourceDatabase,
                                                                                      includeViews: options.includeViews)
        let targetCatalog = try await DataCompareCatalog(session: targetSession).read(database: targetDatabase,
                                                                                      includeViews: options.includeViews)
        var mapped = DataCompareMapper.map(source: sourceCatalog.tables, target: targetCatalog.tables,
                                           schemaMappings: settings.schemaMappings, tablePairs: settings.tablePairs,
                                           options: options)
        DataCompareMapper.apply(settings.tables, to: &mapped.mappings)
        try applyTableArguments(&mapped.mappings)

        for table in mapped.unmatchedSource where !quiet && args.flag("verbose") {
            log("only in source: \(table.qualifiedName)", quiet: quiet)
        }
        for mapping in mapped.mappings where mapping.isIncluded == false && !mapping.hasKey && !quiet {
            log("skipped \(mapping.displayName): no comparison key (use --key \(mapping.source.qualifiedName)=col,…)",
                quiet: quiet)
        }

        let comparer = DataComparer(sourceSession: sourceSession, sourceDatabase: sourceDatabase,
                                    targetSession: targetSession, targetDatabase: targetDatabase, options: options)
        let comparison = try await comparer.compare(mapped.mappings, targetForeignKeys: targetCatalog.foreignKeys) {
            index, total, name in
            if !quiet, index < total {
                FileHandle.standardError.write(Data("  [\(index + 1)/\(total)] \(name)\n".utf8))
            }
        }
        printSummary(comparison)

        if let path = args.string("report") {
            let format = CompareReportFormat(rawValue: (args.string("report-type") ?? inferFormat(path)).lowercased()) ?? .html
            try DataCompareReport(comparison: comparison).render(format).write(to: URL(fileURLWithPath: path))
            log("Report written to \(path).", quiet: quiet)
        }

        guard args.has("script") || args.flag("deploy") else {
            return comparison.hasDifferences ? .differencesFound : .identical
        }
        let plan = DataSyncScripter(comparison: comparison).plan()
        for warning in plan.warnings {
            log("[\(warning.severity.title)] \(warning.object): \(warning.message)", quiet: quiet)
        }
        log("Synchronization: \(plan.totalInserts) inserts, \(plan.totalUpdates) updates, \(plan.totalDeletes) deletes.",
            quiet: quiet)
        if let path = args.string("script") {
            if path == "true" || path == "-" {
                print(plan.script)
            } else {
                try plan.script.write(toFile: path, atomically: true, encoding: .utf8)
                log("Synchronization script written to \(path).", quiet: quiet)
            }
        }
        if args.flag("deploy") {
            guard !plan.isEmpty else {
                log("Nothing to deploy.", quiet: quiet)
                return .success
            }
            let outcome = try await ScriptRunner(session: targetSession, database: targetDatabase).run(plan.script)
            guard outcome.succeeded else {
                log("Deployment failed: \(outcome.error ?? "unknown error")", quiet: false)
                if let batch = outcome.failedBatch { log("Failing batch:\n\(String(batch.prefix(2000)))", quiet: false) }
                return .deploymentFailed
            }
            log("Deployment succeeded in \(String(format: "%.1f", outcome.duration)) s.", quiet: quiet)
            return .success
        }
        return comparison.hasDifferences ? .differencesFound : .identical
    }

    /// --include-table / --exclude-table / --key / --where / --target-where.
    private func applyTableArguments(_ mappings: inout [DataTableMapping]) throws {
        let includes = args.all("include-table").flatMap { $0.split(separator: ",").map { String($0).lowercased() } }
        let excludes = args.all("exclude-table").flatMap { $0.split(separator: ",").map { String($0).lowercased() } }
        for index in mappings.indices {
            let name = mappings[index].source.qualifiedName.lowercased()
            if !includes.isEmpty { mappings[index].isIncluded = includes.contains(name) && mappings[index].hasKey }
            if excludes.contains(name) { mappings[index].isIncluded = false }
        }
        for spec in args.all("key") {
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CLIError.usage("--key expects schema.table=col1,col2") }
            guard let index = mappings.firstIndex(where: {
                $0.source.qualifiedName.caseInsensitiveCompare(parts[0]) == .orderedSame
            }) else { throw CLIError.usage("--key: no mapped table \(parts[0])") }
            DataCompareMapper.setCustomKey(&mappings[index], columns: parts[1].split(separator: ",").map(String.init))
            mappings[index].isIncluded = mappings[index].hasKey
        }
        for (option, isSource) in [("where", true), ("target-where", false)] {
            for spec in args.all(option) {
                let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { throw CLIError.usage("--\(option) expects schema.table=condition") }
                guard let index = mappings.firstIndex(where: {
                    $0.source.qualifiedName.caseInsensitiveCompare(parts[0]) == .orderedSame
                }) else { throw CLIError.usage("--\(option): no mapped table \(parts[0])") }
                if isSource {
                    mappings[index].sourceWhere = parts[1]
                    if !args.has("target-where") { mappings[index].targetWhere = parts[1] }
                } else {
                    mappings[index].targetWhere = parts[1]
                }
            }
        }
    }

    private func printSummary(_ comparison: DataComparison) {
        let verbose = args.flag("verbose")
        for table in comparison.tables {
            if let error = table.error {
                print("! \(table.mapping.displayName): \(error)")
                continue
            }
            guard table.hasDifferences || verbose else { continue }
            print("\(table.hasDifferences ? "≠" : "=") \(table.mapping.displayName): \(table.different) different, "
                  + "\(table.onlyInSource) only in source, \(table.onlyInTarget) only in target, "
                  + "\(table.identical) identical\(table.comparedByChecksum ? " (checksum)" : "")")
            for note in table.notes { print("      note: \(note)") }
            if args.flag("show") {
                let keys = table.mapping.keyColumns.map(\.sourceColumn)
                let columns = table.mapping.comparedColumns.map(\.sourceColumn)
                for row in table.rows where row.status != .identical {
                    let key = zip(keys, row.key).map { "\($0)=\($1.displayString())" }.joined(separator: ", ")
                    var line = "      \(row.status.title) [\(key)]"
                    if row.status == .different, let source = row.source, let target = row.target {
                        let changes = row.differingColumns.map {
                            "\(columns[$0]): \(target[$0].displayString()) → \(source[$0].displayString())"
                        }
                        line += " " + changes.joined(separator: "; ")
                    }
                    print(line)
                }
            }
        }
        let totals = DataRowStatus.allCases.map { "\($0.title): \(comparison.total($0))" }
        log(totals.joined(separator: ", "), quiet: args.flag("quiet"))
    }
}
