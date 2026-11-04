import Foundation
import TDSKit
import SQLServerKit

/// `--name value`, `--name=value` and bare `--flag` arguments. Repeated names accumulate.
///
/// Names in `booleanFlags` never take the next word as their value — `--replace x.bak`
/// leaves `x.bak` as the file to restore — unless that word is an explicit `true`, `false`,
/// `yes`, `no`, `1` or `0`. Every name seen is kept so a command can refuse the ones it does
/// not know.
struct Arguments {
    private(set) var values: [String: [String]] = [:]
    private(set) var positional: [String] = []
    /// Every option name given, lowercased, in order.
    private(set) var names: [String] = []

    static func isBooleanLiteral(_ text: String) -> Bool {
        ["true", "false", "yes", "no", "1", "0"].contains(text.lowercased())
    }

    init(_ arguments: [String], booleanFlags: Set<String> = []) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var value: String?
                if let equals = name.firstIndex(of: "=") {
                    value = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                } else if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    let next = arguments[index + 1]
                    if !booleanFlags.contains(name.lowercased()) || Self.isBooleanLiteral(next) {
                        value = next
                        index += 1
                    }
                }
                let key = name.lowercased()
                names.append(key)
                values[key, default: []].append(value ?? "true")
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func string(_ name: String) -> String? { values[name.lowercased()]?.last }
    func all(_ name: String) -> [String] { values[name.lowercased()] ?? [] }
    func flag(_ name: String) -> Bool {
        guard let value = string(name)?.lowercased() else { return false }
        return value != "false" && value != "0" && value != "no"
    }
    func has(_ name: String) -> Bool { values[name.lowercased()] != nil }

    /// Comma-separated values, from one or several occurrences of the option.
    func list(_ name: String) -> [String] {
        all(name).flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func int(_ name: String) throws -> Int? {
        guard let text = string(name) else { return nil }
        guard let value = Int(text) else { throw CLIError.usage("--\(name) expects a number, not '\(text)'.") }
        return value
    }

    /// A misspelled option used to be ignored, which silently disabled whatever it was meant
    /// to do; now it is a usage error, as is a stray word when the command takes no files.
    func validate(known: Set<String>, allowsPositional: Bool, tool: String) throws {
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw CLIError.usage("Unknown option --\(unknown). Run '\(tool) help' for the options.")
        }
        if !allowsPositional, let stray = positional.first {
            throw CLIError.usage("Unexpected argument '\(stray)'. Options start with --; run '\(tool) help' for the list.")
        }
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        case .failed(let message): return message
        }
    }
}

/// Exit codes. SQL Backup's Windows ranges (warnings 1–499, errors 500 and up) do not survive
/// POSIX's 8-bit exit status, so the same three outcomes get small numbers.
enum ExitCode: Int32 {
    case success = 0
    case warning = 1
    case error = 2
    case usage = 64
}

/// Connection options: `--server`, `--user`, `--password` … or with a prefix
/// (`--secondary-server`) for the standby in log shipping.
struct ConnectionArguments {
    let prefix: String
    let args: Arguments

    /// The option names a connection with this prefix reads.
    static func optionNames(prefix: String) -> Set<String> {
        let names = ["server", "user", "password", "auth", "domain", "token", "encrypt", "verify-certificate"]
        return Set(names.map { prefix.isEmpty ? $0 : "\(prefix)-\($0)" })
    }

    private func name(_ base: String) -> String { prefix.isEmpty ? base : "\(prefix)-\(base)" }

    var server: String? { args.string(name("server")) }

    func connect() async throws -> SQLServerSession {
        guard let server else { throw CLIError.usage("--\(name("server")) is required") }
        var profile = ConnectionProfile()
        profile.server = server
        profile.database = "master"
        let environment = ProcessInfo.processInfo.environment
        let envPrefix = prefix.isEmpty ? "SSMS" : "SSMS_\(prefix.uppercased())"
        profile.username = args.string(name("user")) ?? environment["\(envPrefix)_USER"] ?? environment["SQL_USER"] ?? "sa"
        switch (args.string(name("auth")) ?? "sql").lowercased() {
        case "windows", "ntlm":
            profile.authentication = .windows
            profile.domain = args.string(name("domain")) ?? ""
        case "token", "entra-token":
            profile.authentication = .entraIDAccessToken
        case "entra", "entra-password":
            profile.authentication = .entraIDPassword
        default:
            profile.authentication = .sqlLogin
        }
        switch (args.string(name("encrypt")) ?? "required").lowercased() {
        case "off", "disabled", "false": profile.encryption = .disabled
        case "strict": profile.encryption = .strict
        default: profile.encryption = .required
        }
        profile.trustServerCertificate = !args.flag(name("verify-certificate"))
        profile.applicationName = "SSMS for Mac SQL Backup"
        let password = args.string(name("password")) ?? environment["\(envPrefix)_PASSWORD"] ?? environment["SQL_PASSWORD"]
        return try await SQLServerSession.connect(profile: profile, password: password,
                                                  accessToken: args.string(name("token")))
    }
}

func log(_ text: String, quiet: Bool) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func describe(_ error: Error) -> String {
    if case TDSError.server(let message) = error { return message.formatted }
    if let message = error as? TDSServerMessage { return message.formatted }
    return String(describing: error)
}
