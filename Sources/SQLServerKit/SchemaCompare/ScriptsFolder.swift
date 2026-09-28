import Foundation

/// A database schema as a folder of creation scripts, one file per object, laid out the way
/// source-controlled SQL Server projects usually are (`Tables/dbo.Customers.sql`,
/// `Stored Procedures/…`, `Security/Users/…`).
///
/// Writing a snapshot produces such a folder; reading one parses every `.sql` file in it,
/// whatever the layout, so folders written by other tools can be compared too.
public enum ScriptsFolder {

    public static let infoFileName = "DatabaseInfo.json"

    /// Settings that cannot be inferred from the scripts.
    public struct Info: Codable, Sendable {
        public var databaseName: String
        public var defaultCollation: String
        public var compatibilityLevel: Int
        public var generatedBy: String

        public init(databaseName: String, defaultCollation: String, compatibilityLevel: Int,
                    generatedBy: String = "SSMS for Mac") {
            self.databaseName = databaseName
            self.defaultCollation = defaultCollation
            self.compatibilityLevel = compatibilityLevel
            self.generatedBy = generatedBy
        }
    }

    // MARK: - Paths

    public static func relativePath(for key: SchemaObjectKey) -> String {
        let base = key.schema.isEmpty ? key.name : "\(key.schema).\(key.name)"
        return key.type.folderName + "/" + safeFileName(base) + ".sql"
    }

    /// Characters no file system accepts are percent-encoded, so every name maps to exactly
    /// one file and back.
    static func safeFileName(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "*", "?", "\"", "<", ">", "|", "%":
                out += String(format: "%%%02X", scalar.value)
            default:
                if scalar.value < 32 {
                    out += String(format: "%%%02X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Writing

    public static func script(for object: SchemaObject) -> String {
        let writer = SchemaScriptWriter(options: SchemaScriptWriter.Options(includeStorage: true))
        return writer.script(for: object)
    }

    /// Writes every object of `snapshot` into `directory`. With `removeStale`, `.sql` files
    /// that no longer correspond to an object are deleted.
    @discardableResult
    public static func write(_ snapshot: SchemaSnapshot, to directory: URL, removeStale: Bool = false) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: Set<String> = []
        for object in snapshot.objects {
            let relative = relativePath(for: object.key)
            let url = directory.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script(for: object).write(to: url, atomically: true, encoding: .utf8)
            written.insert(url.standardizedFileURL.path)
        }
        let info = Info(databaseName: snapshot.databaseName, defaultCollation: snapshot.defaultCollation,
                        compatibilityLevel: snapshot.compatibilityLevel)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: directory.appendingPathComponent(infoFileName), options: .atomic)
        if removeStale {
            for url in sqlFiles(in: directory) where !written.contains(url.standardizedFileURL.path) {
                try? fileManager.removeItem(at: url)
            }
        }
        return written.count
    }

    /// Deployment to a scripts folder: the selected differences are written as file creates,
    /// updates and deletions instead of T-SQL.
    public static func apply(_ comparison: SchemaComparison, selectedIDs: Set<String>? = nil,
                             to directory: URL) throws -> [String] {
        var changes: [String] = []
        let fileManager = FileManager.default
        for difference in comparison.differences where difference.status != .identical {
            if let selectedIDs, !selectedIDs.contains(difference.id) { continue }
            if selectedIDs == nil, !difference.isSelected { continue }
            if let target = difference.target, difference.status != .onlyInSource {
                let url = directory.appendingPathComponent(relativePath(for: target.key))
                if difference.status == .onlyInTarget || difference.source?.key != target.key {
                    try? fileManager.removeItem(at: url)
                    changes.append("Deleted \(relativePath(for: target.key))")
                }
            }
            if let source = difference.source {
                let relative = relativePath(for: source.key)
                let url = directory.appendingPathComponent(relative)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try script(for: source).write(to: url, atomically: true, encoding: .utf8)
                changes.append((difference.status == .onlyInSource ? "Created " : "Updated ") + relative)
            }
        }
        return changes
    }

    // MARK: - Reading

    public static func read(from directory: URL, defaultCollation: String? = nil) throws -> SchemaSnapshot {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SQLServerError.objectNotFound(directory.path)
        }
        var info: Info?
        let infoURL = directory.appendingPathComponent(infoFileName)
        if let data = try? Data(contentsOf: infoURL) {
            info = try? JSONDecoder().decode(Info.self, from: data)
        }
        var parser = SchemaScriptParser(defaultCollation: defaultCollation ?? info?.defaultCollation ?? "")
        let files = sqlFiles(in: directory).sorted { $0.path < $1.path }
        for url in files {
            let text = readText(url)
            let relative = url.path.replacingOccurrences(of: directory.path + "/", with: "")
            parser.parse(script: text, file: relative)
        }
        let name = info?.databaseName ?? directory.lastPathComponent
        return parser.snapshot(origin: directory.path, databaseName: name,
                               compatibilityLevel: info?.compatibilityLevel ?? 0)
    }

    /// Parses one script file (a deployment script, a "Generate Scripts" output, …).
    public static func readScript(at url: URL, defaultCollation: String = "") throws -> SchemaSnapshot {
        var parser = SchemaScriptParser(defaultCollation: defaultCollation)
        parser.parse(script: readText(url), file: url.lastPathComponent)
        return parser.snapshot(origin: url.path, databaseName: url.deletingPathExtension().lastPathComponent)
    }

    static func sqlFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "sql" {
            files.append(url)
        }
        return files
    }

    /// Scripts come in UTF-8 and UTF-16 with or without a byte order mark.
    static func readText(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "" }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        return String(data: data, encoding: .windowsCP1252) ?? ""
    }
}
