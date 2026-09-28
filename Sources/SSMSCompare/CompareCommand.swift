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
