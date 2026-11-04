import Foundation
import TDSKit
import SQLServerKit

/// `--name value`, `--name=value` and bare `--flag` arguments. Repeated names accumulate.
///
/// Names in `booleanFlags` never take the next word as their value — `--quiet deploy.sql`
/// leaves `deploy.sql` where it is — unless that word is an explicit `true`, `false`, `yes`,
/// `no`, `1` or `0`. Every name seen is kept so a command can refuse the ones it does not know.
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
                add(name, value ?? "true")
            } else if argument.hasPrefix("/") && argument.contains(":") {
                // Redgate-style /name:value switches are accepted too.
                let body = argument.dropFirst()
                let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
                add(parts[0], parts.count > 1 ? parts[1] : "true")
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    private mutating func add(_ name: String, _ value: String) {
        let key = name.lowercased()
        names.append(key)
        values[key, default: []].append(value)
    }

    func string(_ name: String) -> String? { values[name.lowercased()]?.last }
    func all(_ name: String) -> [String] { values[name.lowercased()] ?? [] }
    func flag(_ name: String) -> Bool {
        guard let value = string(name)?.lowercased() else { return false }
        return value != "false" && value != "0" && value != "no"
    }
    func has(_ name: String) -> Bool { values[name.lowercased()] != nil }

    /// A misspelled option used to be ignored, which silently disabled whatever it was meant
    /// to do; now it is a usage error, as is a stray word when the command takes none.
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
///
/// With a saved project, a side the command line does not name comes from the project; a
/// side it names of the same kind takes the project's values for whatever is left out, and
/// a side it names of another kind (a scripts folder in place of a database, say) replaces
/// the project's side entirely.
struct EndpointArguments {
    let prefix: String
    let args: Arguments
    /// The side as the project describes it, when one was given.
    var defaults: CompareEndpoint? = nil

    private var number: String { prefix == "source" ? "1" : "2" }

    private func given(_ name: String, alias: String) -> String? {
        args.string("\(prefix)-\(name)") ?? args.string(alias)
    }

    /// What kind of side the command line asks for, in the order `loadSide` prefers them.
    private var explicitKind: CompareEndpoint.Kind? {
        if given("snapshot", alias: "snapshot\(number)") != nil { return .snapshot }
        if given("scripts", alias: "scripts\(number)") != nil { return .scriptsFolder }
        if given("server", alias: "s\(number)") != nil || given("database", alias: "db\(number)") != nil {
            return .database
        }
        return nil
    }

    /// The project's side, unless the command line replaces it with another kind.
    private var saved: CompareEndpoint? {
        guard let defaults else { return nil }
        if let explicitKind, explicitKind != defaults.kind { return nil }
        return defaults
    }

    private func savedValue(_ kind: CompareEndpoint.Kind, _ keyPath: KeyPath<CompareEndpoint, String>) -> String? {
        guard let saved, saved.kind == kind else { return nil }
        let value = saved[keyPath: keyPath]
        return value.isEmpty ? nil : value
    }

    var server: String? {
        given("server", alias: "s\(number)") ?? (saved?.kind == .database ? saved?.connection?.server : nil)
    }
    var database: String? { given("database", alias: "db\(number)") ?? savedValue(.database, \.database) }
    var snapshot: String? { given("snapshot", alias: "snapshot\(number)") ?? savedValue(.snapshot, \.path) }
    var scripts: String? { given("scripts", alias: "scripts\(number)") ?? savedValue(.scriptsFolder, \.path) }

    /// Something names this side, on the command line or in the project.
    var isSpecified: Bool { server != nil || database != nil || snapshot != nil || scripts != nil }

    func profile() throws -> (ConnectionProfile, String?) {
        guard let server else { throw CLIError.usage("--\(prefix)-server is required") }
        let environment = ProcessInfo.processInfo.environment
        // The project's saved connection carries the login, authentication and encryption
        // choices; the command line overrides them one by one. Its password is not in the
        // project file, so it comes from the flags or the environment as always.
        var profile = (saved?.kind == .database ? saved?.connection : nil) ?? ConnectionProfile()
        profile.server = server
        profile.database = database ?? "master"
        if let user = given("user", alias: "u\(number)") {
            profile.username = user
        } else if profile.username.isEmpty {
            profile.username = environment["SSMS_\(prefix.uppercased())_USER"] ?? environment["SQL_USER"] ?? "sa"
        }
        if let auth = args.string("\(prefix)-auth") {
            switch auth.lowercased() {
            case "windows", "ntlm":
                profile.authentication = .windows
                profile.domain = args.string("\(prefix)-domain") ?? profile.domain
            case "token", "entra-token":
                profile.authentication = .entraIDAccessToken
            case "entra", "entra-password":
                profile.authentication = .entraIDPassword
            default:
                profile.authentication = .sqlLogin
            }
        } else if let domain = args.string("\(prefix)-domain") {
            profile.domain = domain
        }
        if let encrypt = args.string("\(prefix)-encrypt") {
            switch encrypt.lowercased() {
            case "off", "disabled", "false": profile.encryption = .disabled
            case "strict": profile.encryption = .strict
            default: profile.encryption = .required
            }
        }
        if args.has("\(prefix)-verify-certificate") {
            profile.trustServerCertificate = !args.flag("\(prefix)-verify-certificate")
        } else if saved?.connection == nil {
            profile.trustServerCertificate = true
        }
        profile.applicationName = "SSMS for Mac Compare"
        let password = given("password", alias: "p\(number)")
            ?? environment["SSMS_\(prefix.uppercased())_PASSWORD"]
            ?? environment["SQL_PASSWORD"]
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

/// Where `--script` sends the deployment script: stdout with `-` or no value.
func scriptGoesToStandardOutput(_ value: String?) -> Bool {
    value == "true" || value == "-"
}

/// The report format for `--report`, from `--report-type` or the file's extension.
func reportFormat(path: String, explicit: String?) throws -> CompareReportFormat {
    let name = explicit ?? inferFormat(path)
    guard let format = CompareReportFormat(rawValue: name.lowercased()) else {
        throw CLIError.usage("--report-type is html, xml, excel, csv or json, not '\(name)'.")
    }
    return format
}

/// A project given with `--project`, which must exist and be readable.
func readProject(_ path: String) throws -> CompareProject {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.usage("--project: \(path) does not exist.")
    }
    return try CompareProject.read(from: URL(fileURLWithPath: path))
}

/// A path given for a snapshot or scripts side, which must exist before anything is read:
/// a mistyped path used to read as an empty schema and script the removal of every object.
func requirePath(_ path: String, option: String) throws {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CLIError.usage("\(option): \(path) does not exist.")
    }
}
