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
            case "data":
                code = try await DataCommand(args: args).run()
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

    /// The help text, with the option names taken from the option lists themselves so they
    /// cannot drift from what `--options` accepts.
    static var usage: String {
        usageTemplate
            .replacingOccurrences(of: "{SCHEMA_OPTIONS}",
                                  with: wrapped(SchemaCompareOptions.descriptors.map(\.name)))
            .replacingOccurrences(of: "{DATA_OPTIONS}",
                                  with: wrapped(DataCompareOptions.descriptors.map(\.name)))
    }

    private static func wrapped(_ names: [String]) -> String {
        var lines: [String] = []
        let indent = "     "
        var line = indent
        for name in names {
            let word: String = " " + String(name.prefix(1)).uppercased() + String(name.dropFirst()) + ","
            if line.count + word.count > 100 {
                lines.append(line)
                line = indent
            }
            line += word
        }
        lines.append(String(line.dropLast()))
        return lines.joined(separator: "\n")
    }

    private static let usageTemplate = """
    ssms-compare — schema and data comparison for SQL Server

    USAGE
      ssms-compare schema <source> <target> [options]
      ssms-compare data   <source> <target> [options]
      ssms-compare help

    SOURCE AND TARGET
      --source-server <host[,port]|host\\instance>   (also /s1:)
      --source-database <name>                      (also /db1:)
      --source-user <login>  --source-password <pw> (also /u1: /p1:, or SSMS_SOURCE_USER /
                                                     SSMS_SOURCE_PASSWORD, SQL_USER / SQL_PASSWORD)
      --source-auth sql|windows|entra|token         --source-domain <domain> (windows)
      --source-token <access token>                 (token)
      --source-encrypt required|strict|off          --source-verify-certificate
      --source-snapshot <file.ssnap>                (schema only; also /snapshot1:)
      --source-scripts <folder or .sql file>        (schema only; also /scripts1:)
      --source-collation <name>                     default collation for a scripts folder
      The same options with --target-… (and /s2: /db2: /u2: /p2: /snapshot2: /scripts2:).

    COMMON OPTIONS
      --project <file.scmp|file.dcmp>   load sources, options, mappings and filters from a project
      --options <list>                  comma-separated option names; prefix with - to turn one off,
                                        "default" resets, e.g. --options "-IgnoreWhitespace,IgnoreComments"
      --map-schema <source=target>      compare a source schema with a differently named target schema
      --report <file>                   write a report; format from the extension or --report-type
      --report-type html|xml|excel|csv|json
      --script [file|-]                 write the deployment script (to stdout with - or no value)
      --deploy                          run the deployment script against the target
      --show                            list every difference, not only the summary
      --verbose                         also list identical objects, server messages and warnings
      --quiet                           no progress output on stderr

    SCHEMA OPTIONS
      --include-type <types>            compare only these object types (e.g. table,view,procedure)
      --exclude-type <types>            leave these object types out
      --include-object <regex>          compare only objects whose schema.name matches
      --exclude-object <regex>          leave out objects whose schema.name matches
      --abort-on-warnings high|medium|low
                                        stop before scripting/deploying if the deployment has warnings
                                        of that severity or worse
      --assert-identical                exit 0 when identical, 79 when different
      --make-snapshot <file.ssnap>      save the source as a snapshot (no target needed)
      --make-scripts <folder>           save the source as a scripts folder, one file per object
      --remove-stale                    with --make-scripts: delete files of objects that are gone
      Deploying to a --target-scripts folder rewrites the affected object files.

      Schema option names for --options (case-insensitive):
    {SCHEMA_OPTIONS}

    DATA OPTIONS
      --include-table <schema.table,…>  compare only these tables
      --exclude-table <schema.table,…>  leave these tables out
      --map-table <schema.a=schema.b>   pair tables whose names differ
      --key <schema.table=col1,col2>    compare a table by these columns instead of its primary key
      --where <schema.table=condition>  compare only matching rows (both sides unless --target-where)
      --target-where <schema.table=condition>

      Data option names for --options (case-insensitive):
    {DATA_OPTIONS}
          FloatDecimalPlaces=<n>, RowsPerBatch=<n>, MaximumRowsKept=<n>

    EXIT CODES
      0    success (deployment done, or identical with --assert-identical)
      63   the source and target are identical
      79   differences were found (or --abort-on-warnings stopped the deployment)
      64   invalid command line
      126  the deployment script failed (and was rolled back unless DoNotUseTransactions)
      1    any other error

    EXAMPLES
      ssms-compare schema --source-server dev --source-database Shop \\
                          --target-server prod --target-database Shop --report diff.html
      ssms-compare schema --source-scripts ./db --target-server prod --target-database Shop \\
                          --script deploy.sql --abort-on-warnings high
      ssms-compare schema --source-server dev --source-database Shop --make-snapshot shop.ssnap
      ssms-compare data --source-server dev --source-database Shop --target-server test \\
                        --target-database Shop --include-table dbo.Product,dbo.Category --deploy
    """
}

func describe(_ error: Error) -> String {
    if let message = error as? TDSServerMessage { return message.formatted }
    return String(describing: error)
}
