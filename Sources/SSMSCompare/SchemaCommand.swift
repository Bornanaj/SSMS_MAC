import Foundation
import TDSKit
import SQLServerKit

/// `ssms-compare schema`: compare two schemas, then optionally write a deployment script,
/// deploy it, write a report, or save a snapshot / scripts folder.
struct SchemaCommand {
    let args: Arguments

    func run() async throws -> ExitCode {
        let quiet = args.flag("quiet")
        var options = SchemaCompareOptions()
        var filter = SchemaFilter()
        var mappings = SchemaMappings()

        if let path = args.string("project") {
            let project = try CompareProject.read(from: URL(fileURLWithPath: path))
            guard let schema = project.schema else { throw CLIError.usage("\(path) is not a schema compare project.") }
            options = schema.options
            filter = schema.filter
            mappings = schema.mappings
        }
        if let list = args.string("options") {
            let unknown = options.apply(list: list)
            if !unknown.isEmpty { throw CLIError.usage("Unknown option(s): \(unknown.joined(separator: ", "))") }
        }
        for type in try objectTypes(args.all("exclude-type")) { filter.excludedTypes.insert(type) }
        let included = try objectTypes(args.all("include-type"))
        if !included.isEmpty {
            filter.excludedTypes = Set(SchemaObjectType.allCases).subtracting(included)
        }
        for pattern in args.all("exclude-object") {
            filter.rules.append(SchemaFilterRule(action: .exclude, field: .qualifiedName, op: .matchesRegex, value: pattern))
        }
        for pattern in args.all("include-object") {
            filter.rules.append(SchemaFilterRule(action: .include, field: .qualifiedName, op: .matchesRegex, value: pattern))
        }
        for pair in args.all("map-schema") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2 else { throw CLIError.usage("--map-schema expects source=target") }
            mappings.schemaMappings.append(SchemaNameMapping(source: parts[0], target: parts[1]))
        }

        let sourceEndpoint = EndpointArguments(prefix: "source", args: args)
        let source = try await loadSide(sourceEndpoint, quiet: quiet)

        if let path = args.string("make-snapshot") {
            try SchemaSnapshotFile.write(source, to: URL(fileURLWithPath: path))
            log("Snapshot of \(source.origin) written to \(path) (\(source.objects.count) objects).", quiet: quiet)
        }
        if let path = args.string("make-scripts") {
            let count = try ScriptsFolder.write(source, to: URL(fileURLWithPath: path), removeStale: args.flag("remove-stale"))
            log("Scripts folder written to \(path) (\(count) files).", quiet: quiet)
        }
        let targetEndpoint = EndpointArguments(prefix: "target", args: args)
        guard targetEndpoint.server != nil || targetEndpoint.snapshot != nil || targetEndpoint.scripts != nil else {
            if args.has("make-snapshot") || args.has("make-scripts") { return .success }
            throw CLIError.usage("A target is required: --target-server/--target-database, --target-snapshot or --target-scripts.")
        }
        let target = try await loadSide(targetEndpoint, quiet: quiet)

        let comparison = SchemaComparer(options: options, filter: filter, mappings: mappings)
            .compare(source: source, target: target)
        printSummary(comparison, quiet: quiet)

        if let path = args.string("report") {
            let format = CompareReportFormat(rawValue: (args.string("report-type") ?? inferFormat(path)).lowercased()) ?? .html
            let data = try SchemaCompareReport(comparison: comparison).render(format)
            try data.write(to: URL(fileURLWithPath: path))
            log("Report written to \(path).", quiet: quiet)
        }

        let plan = SchemaDeploymentPlanner(comparison: comparison, targetDatabaseName: targetEndpoint.database).plan()
        if args.has("script") || args.flag("deploy") {
            for warning in plan.warnings {
                log("[\(warning.severity.title)] \(warning.object): \(warning.message)", quiet: quiet)
            }
            if let limit = args.string("abort-on-warnings"),
               let threshold = DeploymentWarningSeverity(rawValue: limit.lowercased()),
               let worst = plan.highestSeverity, worst <= threshold {
                log("Stopping: the deployment has \(worst.title.lowercased())-severity warnings.", quiet: false)
                return .differencesFound
            }
        }
        if let path = args.string("script") {
            if path == "true" || path == "-" {
                print(plan.script)
            } else {
                try plan.script.write(toFile: path, atomically: true, encoding: .utf8)
                log("Deployment script written to \(path).", quiet: quiet)
            }
        }
        if args.flag("deploy") {
            if let folder = targetEndpoint.scripts {
                let changes = try ScriptsFolder.apply(comparison, to: URL(fileURLWithPath: folder))
                for change in changes { log(change, quiet: quiet) }
                return .success
            }
            guard targetEndpoint.server != nil, let database = targetEndpoint.database else {
                throw CLIError.usage("Deployment needs a live target database or a target scripts folder.")
            }
            let session = try await targetEndpoint.connect()
            defer { Task { await session.close() } }
            let outcome = try await ScriptRunner(session: session, database: database).run(plan.script) { done, total, _ in
                if !quiet, total > 0, done % 25 == 0 {
                    FileHandle.standardError.write(Data("  \(done)/\(total) batches\n".utf8))
                }
            }
            if args.flag("verbose") { for message in outcome.messages { print(message) } }
            guard outcome.succeeded else {
                log("Deployment failed: \(outcome.error ?? "unknown error")", quiet: false)
                if let batch = outcome.failedBatch { log("Failing batch:\n\(batch)", quiet: false) }
                return .deploymentFailed
            }
            log("Deployment succeeded: \(outcome.batchesRun) batches in \(String(format: "%.1f", outcome.duration)) s.",
                quiet: quiet)
            return .success
        }
        if args.flag("assert-identical") {
            return comparison.hasDifferences ? .differencesFound : .success
        }
        return comparison.hasDifferences ? .differencesFound : .identical
    }

    private func printSummary(_ comparison: SchemaComparison, quiet: Bool) {
        let showAll = args.flag("verbose")
        for difference in comparison.differences where difference.status != .identical || showAll {
            print("\(difference.status.symbol) \(difference.type.title): \(difference.displayName)")
            if difference.status == .different {
                for line in difference.details { print("      \(line)") }
            }
            if args.flag("show") {
                print("----- source\n\(difference.sourceScript)----- target\n\(difference.targetScript)")
            }
        }
        if !quiet {
            let counts = DifferenceStatus.allCases.map { "\($0.shortTitle): \(comparison.count($0))" }
            log(counts.joined(separator: ", "), quiet: quiet)
        }
    }

    func loadSide(_ endpoint: EndpointArguments, quiet: Bool) async throws -> SchemaSnapshot {
        if let path = endpoint.snapshot {
            log("Loading \(endpoint.prefix) snapshot \(path)…", quiet: quiet)
            return try SchemaSnapshotFile.read(from: URL(fileURLWithPath: path))
        }
        if let path = endpoint.scripts {
            log("Reading \(endpoint.prefix) scripts \(path)…", quiet: quiet)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let collation = args.string("\(endpoint.prefix)-collation")
            let snapshot = isDirectory.boolValue
                ? try ScriptsFolder.read(from: URL(fileURLWithPath: path), defaultCollation: collation)
                : try ScriptsFolder.readScript(at: URL(fileURLWithPath: path), defaultCollation: collation ?? "")
            if args.flag("verbose") { for warning in snapshot.warnings { log("warning: \(warning)", quiet: quiet) } }
            return snapshot
        }
        guard let database = endpoint.database else {
            throw CLIError.usage("--\(endpoint.prefix)-database is required")
        }
        let session = try await endpoint.connect()
        defer { Task { await session.close() } }
        log("Reading \(endpoint.prefix) \(database)…", quiet: quiet)
        let snapshot = try await LiveSchemaReader(session: session).read(database: database)
        for warning in snapshot.warnings { log("warning: \(warning)", quiet: quiet) }
        return snapshot
    }

    private func objectTypes(_ values: [String]) throws -> Set<SchemaObjectType> {
        var result: Set<SchemaObjectType> = []
        for value in values {
            for item in value.split(separator: ",") {
                let name = item.trimmingCharacters(in: .whitespaces).lowercased()
                guard let type = SchemaObjectType.allCases.first(where: {
                    $0.rawValue.lowercased() == name || $0.title.lowercased() == name
                        || $0.pluralTitle.lowercased() == name
                }) else {
                    throw CLIError.usage("Unknown object type '\(item)'. Known: "
                                         + SchemaObjectType.allCases.map(\.rawValue).joined(separator: ", "))
                }
                result.insert(type)
            }
        }
        return result
    }
}

func inferFormat(_ path: String) -> String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "xml": return "xml"
    case "xlsx": return "excel"
    case "csv": return "csv"
    case "json": return "json"
    default: return "html"
    }
}
