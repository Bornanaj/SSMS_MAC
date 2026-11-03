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
        var project: CompareProject?

        if let path = args.string("project") {
            let loaded = try readProject(path)
            guard let schema = loaded.schema else { throw CLIError.usage("\(path) is not a schema compare project.") }
            options = schema.options
            filter = schema.filter
            mappings = schema.mappings
            project = loaded
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
        // Values that cannot be right are refused before anything is read or connected to.
        let abortThreshold = try Self.warningThreshold(args.string("abort-on-warnings"))
        let report: (path: String, format: CompareReportFormat)? = try args.string("report").map { path in
            (path, try reportFormat(path: path, explicit: args.string("report-type")))
        }

        let sourceEndpoint = EndpointArguments(prefix: "source", args: args, defaults: project?.source)
        let source = try await loadSide(sourceEndpoint, quiet: quiet)

        if let path = args.string("make-snapshot") {
            try SchemaSnapshotFile.write(source, to: URL(fileURLWithPath: path))
            log("Snapshot of \(source.origin) written to \(path) (\(source.objects.count) objects).", quiet: quiet)
        }
        if let path = args.string("make-scripts") {
            let count = try ScriptsFolder.write(source, to: URL(fileURLWithPath: path), removeStale: args.flag("remove-stale"))
            log("Scripts folder written to \(path) (\(count) files).", quiet: quiet)
        }
        let targetEndpoint = EndpointArguments(prefix: "target", args: args, defaults: project?.target)
        guard targetEndpoint.isSpecified else {
            if args.has("make-snapshot") || args.has("make-scripts") { return .success }
            throw CLIError.usage("A target is required: --target-server/--target-database, --target-snapshot or --target-scripts.")
        }
        let target = try await loadSide(targetEndpoint, quiet: quiet)

        let comparison = SchemaComparer(options: options, filter: filter, mappings: mappings)
            .compare(source: source, target: target)
        // With the script on stdout the summary moves to stderr, so the output stays a script.
        let scriptToStdout = args.has("script") && scriptGoesToStandardOutput(args.string("script"))
        printSummary(comparison, quiet: quiet, toStandardError: scriptToStdout)

        if let report {
            let data = try SchemaCompareReport(comparison: comparison).render(report.format)
            try data.write(to: URL(fileURLWithPath: report.path))
            log("Report written to \(report.path).", quiet: quiet)
        }

        let scripting = args.has("script") || args.flag("deploy")
        if scripting, source.objects.isEmpty, comparison.count(.onlyInTarget) > 0, !args.flag("allow-empty-source") {
            throw CLIError.usage("The source (\(source.origin)) has no objects, so the deployment would drop every "
                                 + "object in the target. Pass --allow-empty-source if that is what you want.")
        }
        // A saved project deploys the selection it was saved with.
        let selectedIDs = Self.selectedIDs(comparison, deselected: project?.schema?.deselected ?? [])
        let plan = SchemaDeploymentPlanner(comparison: comparison, targetDatabaseName: targetEndpoint.database)
            .plan(selectedIDs: selectedIDs)
        if scripting {
            for warning in plan.warnings {
                log("[\(warning.severity.title)] \(warning.object): \(warning.message)", quiet: quiet)
            }
            if let abortThreshold, let worst = plan.highestSeverity, worst <= abortThreshold {
                log("Stopping: the deployment has \(worst.title.lowercased())-severity warnings.", quiet: false)
                return .differencesFound
            }
        }
        if let path = args.string("script") {
            if scriptToStdout {
                print(plan.script)
            } else {
                try plan.script.write(toFile: path, atomically: true, encoding: .utf8)
                log("Deployment script written to \(path).", quiet: quiet)
            }
        }
        if args.flag("deploy") {
            if let folder = targetEndpoint.scripts {
                let changes = try ScriptsFolder.apply(comparison, selectedIDs: selectedIDs, to: URL(fileURLWithPath: folder))
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
            if args.flag("verbose") {
                for message in outcome.messages {
                    if scriptToStdout { log(message, quiet: quiet) } else { print(message) }
                }
            }
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

    /// `--abort-on-warnings`, which used to be ignored when misspelled.
    static func warningThreshold(_ text: String?) throws -> DeploymentWarningSeverity? {
        guard let text else { return nil }
        guard let severity = DeploymentWarningSeverity(rawValue: text.lowercased()) else {
            throw CLIError.usage("--abort-on-warnings is high, medium or low, not '\(text)'.")
        }
        return severity
    }

    /// Every difference except the ones the project saved as unticked; nil keeps the
    /// comparison's own ticks when nothing was unticked.
    static func selectedIDs(_ comparison: SchemaComparison, deselected: Set<String>) -> Set<String>? {
        guard !deselected.isEmpty else { return nil }
        return Set(comparison.differences.filter { $0.status != .identical && !deselected.contains($0.id) }.map(\.id))
    }

    private func printSummary(_ comparison: SchemaComparison, quiet: Bool, toStandardError: Bool) {
        func emit(_ line: String) {
            if toStandardError { log(line, quiet: quiet) } else { print(line) }
        }
        let showAll = args.flag("verbose")
        for difference in comparison.differences where difference.status != .identical || showAll {
            emit("\(difference.status.symbol) \(difference.type.title): \(difference.displayName)")
            if difference.status == .different {
                for line in difference.details { emit("      \(line)") }
            }
            if args.flag("show") {
                emit("----- source\n\(difference.sourceScript)----- target\n\(difference.targetScript)")
            }
        }
        if !quiet {
            let counts = DifferenceStatus.allCases.map { "\($0.shortTitle): \(comparison.count($0))" }
            log(counts.joined(separator: ", "), quiet: quiet)
        }
    }

    func loadSide(_ endpoint: EndpointArguments, quiet: Bool) async throws -> SchemaSnapshot {
        if let path = endpoint.snapshot {
            try requirePath(path, option: "--\(endpoint.prefix)-snapshot")
            log("Loading \(endpoint.prefix) snapshot \(path)…", quiet: quiet)
            return try SchemaSnapshotFile.read(from: URL(fileURLWithPath: path))
        }
        if let path = endpoint.scripts {
            // A path that does not exist used to be read as a single, empty script, so the
            // "source" had no objects and the deployment dropped everything in the target.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                throw CLIError.usage("--\(endpoint.prefix)-scripts: \(path) does not exist.")
            }
            log("Reading \(endpoint.prefix) scripts \(path)…", quiet: quiet)
            let collation = args.string("\(endpoint.prefix)-collation")
            let snapshot = isDirectory.boolValue
                ? try ScriptsFolder.read(from: URL(fileURLWithPath: path), defaultCollation: collation)
                : try ScriptsFolder.readScript(at: URL(fileURLWithPath: path), defaultCollation: collation ?? "")
            if args.flag("verbose") { for warning in snapshot.warnings { log("warning: \(warning)", quiet: quiet) } }
            if snapshot.objects.isEmpty { log("warning: no objects were read from \(path).", quiet: quiet) }
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
