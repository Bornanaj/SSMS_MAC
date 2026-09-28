import Foundation
import TDSKit
import SQLServerKit

@main
struct CompareCommand {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        guard let command = raw.first, !command.hasPrefix("-") else {
            print(usage)
            exit(ExitCode.usage.rawValue)
        }
        let args = Arguments(Array(raw.dropFirst()))
        do {
            let code: ExitCode
            switch command.lowercased() {
            case "schema":
                code = try await SchemaCommand(args: args).run()
            case "help", "--help", "-h":
                print(usage)
                code = .success
            default:
                throw CLIError.usage("Unknown command '\(command)'.\n\n\(usage)")
            }
            exit(code.rawValue)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            if case .usage = error { exit(ExitCode.usage.rawValue) }
            exit(ExitCode.generalError.rawValue)
        } catch {
            FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
            exit(ExitCode.generalError.rawValue)
        }
    }

    static let usage = """
    ssms-compare — schema and data comparison for SQL Server

    USAGE
      ssms-compare schema [source] [target] [options]
      ssms-compare data   [source] [target] [options]

    Run `ssms-compare help` for the full option list.
    """
}

func describe(_ error: Error) -> String {
    if let message = error as? TDSServerMessage { return message.formatted }
    return String(describing: error)
}

struct SchemaCommand {
    let args: Arguments

    func run() async throws -> ExitCode {
        let quiet = args.flag("quiet")
        var options = SchemaCompareOptions()
        if let list = args.string("options") {
            let unknown = options.apply(list: list)
            if !unknown.isEmpty { throw CLIError.usage("Unknown option(s): \(unknown.joined(separator: ", "))") }
        }
        let source = try await loadSide(EndpointArguments(prefix: "source", args: args), quiet: quiet)
        let target = try await loadSide(EndpointArguments(prefix: "target", args: args), quiet: quiet)
        let comparison = SchemaComparer(options: options).compare(source: source, target: target)
        for difference in comparison.differences where difference.status != .identical || args.flag("verbose") {
            print("\(difference.status.symbol) \(difference.type.title): \(difference.displayName)")
            for line in difference.details where difference.status == .different {
                print("      \(line)")
            }
            if args.flag("show") {
                print("----- source\n\(difference.sourceScript)\n----- target\n\(difference.targetScript)")
            }
        }
        if args.has("script") || args.flag("deploy") {
            let plan = SchemaDeploymentPlanner(comparison: comparison).plan()
            for warning in plan.warnings {
                log("[\(warning.severity.title)] \(warning.object): \(warning.message)", quiet: quiet)
            }
            if let path = args.string("script"), path != "true" {
                try plan.script.write(toFile: path, atomically: true, encoding: .utf8)
                log("Deployment script written to \(path)", quiet: quiet)
            } else if args.has("script") {
                print(plan.script)
            }
            if args.flag("deploy") {
                let endpoint = EndpointArguments(prefix: "target", args: args)
                let session = try await endpoint.connect()
                let outcome = try await ScriptRunner(session: session, database: endpoint.database ?? "")
                    .run(plan.script)
                await session.close()
                for message in outcome.messages where !quiet { print(message) }
                if !outcome.succeeded {
                    log("Deployment failed: \(outcome.error ?? "unknown error")", quiet: false)
                    if let batch = outcome.failedBatch { log("Failing batch:\n\(batch)", quiet: false) }
                    return .deploymentFailed
                }
                log("Deployment succeeded (\(outcome.batchesRun) batches).", quiet: quiet)
                return .success
            }
        }
        return comparison.hasDifferences ? .differencesFound : .identical
    }

    func loadSide(_ endpoint: EndpointArguments, quiet: Bool) async throws -> SchemaSnapshot {
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
}
