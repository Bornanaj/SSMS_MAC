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
            } else if argument.hasPrefix("/") && argument.contains(":") {
                // Redgate-style /name:value switches are accepted too.
                let body = argument.dropFirst()
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                values[parts[0].lowercased(), default: []].append(parts.count > 1 ? parts[1] : "true")
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

/// Exit codes, chosen to line up with the ones other SQL comparison tools document so build
/// scripts can treat them the same way.
enum ExitCode: Int32 {
    case success = 0
    case generalError = 1
    case usage = 64
    case identical = 63
    case differencesFound = 79
    case deploymentFailed = 126
}

// MARK: - Connections

/// Builds a connection for one side from `--source-server`, `--source-database`, ….
struct EndpointArguments {
    let prefix: String
    let args: Arguments

    var server: String? { args.string("\(prefix)-server") ?? args.string(prefix == "source" ? "s1" : "s2") }
    var database: String? { args.string("\(prefix)-database") ?? args.string(prefix == "source" ? "db1" : "db2") }
    var snapshot: String? { args.string("\(prefix)-snapshot") ?? args.string(prefix == "source" ? "snapshot1" : "snapshot2") }
    var scripts: String? { args.string("\(prefix)-scripts") ?? args.string(prefix == "source" ? "scripts1" : "scripts2") }

    func profile() throws -> (ConnectionProfile, String?) {
        guard let server else { throw CLIError.usage("--\(prefix)-server is required") }
        var profile = ConnectionProfile()
        profile.server = server
        profile.database = database ?? "master"
        let user = args.string("\(prefix)-user") ?? args.string(prefix == "source" ? "u1" : "u2")
            ?? ProcessInfo.processInfo.environment["SSMS_\(prefix.uppercased())_USER"]
            ?? ProcessInfo.processInfo.environment["SQL_USER"] ?? "sa"
        profile.username = user
        switch (args.string("\(prefix)-auth") ?? "sql").lowercased() {
        case "windows", "ntlm":
            profile.authentication = .windows
            profile.domain = args.string("\(prefix)-domain") ?? ""
        case "token", "entra-token":
            profile.authentication = .entraIDAccessToken
        case "entra", "entra-password":
            profile.authentication = .entraIDPassword
        default:
            profile.authentication = .sqlLogin
        }
        switch (args.string("\(prefix)-encrypt") ?? "required").lowercased() {
        case "off", "disabled", "false": profile.encryption = .disabled
        case "strict": profile.encryption = .strict
        default: profile.encryption = .required
        }
        profile.trustServerCertificate = !args.flag("\(prefix)-verify-certificate")
        profile.applicationName = "SSMS for Mac Compare"
        let password = args.string("\(prefix)-password") ?? args.string(prefix == "source" ? "p1" : "p2")
            ?? ProcessInfo.processInfo.environment["SSMS_\(prefix.uppercased())_PASSWORD"]
            ?? ProcessInfo.processInfo.environment["SQL_PASSWORD"]
        return (profile, password)
    }

    func connect() async throws -> SQLServerSession {
        let (profile, password) = try profile()
        let token = args.string("\(prefix)-token")
        return try await SQLServerSession.connect(profile: profile, password: password, accessToken: token)
    }
}

func log(_ text: String, quiet: Bool) {
    guard !quiet else { return }
    FileHandle.standardError.write(Data((text + "\n").utf8))
}
