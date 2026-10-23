import Foundation
import TDSKit
import SQLServerKit

/// `--name value`, `--name=value` and bare `--flag` arguments. Repeated names accumulate.
struct Arguments {
    private(set) var values: [String: [String]] = [:]
    private(set) var positional: [String] = []

    init(_ arguments: [String]) {
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
                    value = arguments[index + 1]
                    index += 1
                }
                values[name.lowercased(), default: []].append(value ?? "true")
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
