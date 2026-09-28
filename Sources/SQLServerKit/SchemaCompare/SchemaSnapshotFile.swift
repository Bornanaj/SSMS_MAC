import Foundation

/// Reads and writes schema snapshots: a whole database schema frozen in one file, which can
/// be compared later without a connection — a release baseline, a copy of production.
public enum SchemaSnapshotFile {
    public static let fileExtension = "ssnap"

    public static func encode(_ snapshot: SchemaSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public static func decode(_ data: Data) throws -> SchemaSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snapshot = try decoder.decode(SchemaSnapshot.self, from: data)
            guard snapshot.formatVersion <= SchemaSnapshot.currentFormatVersion else {
                throw SQLServerError.unsupportedOperation(
                    "The snapshot was written by a newer version (format \(snapshot.formatVersion)).")
            }
            return snapshot
        } catch let error as SQLServerError {
            throw error
        } catch {
            throw SQLServerError.unsupportedOperation(
                "This file is not an SSMS for Mac schema snapshot: \(error.localizedDescription)")
        }
    }

    public static func write(_ snapshot: SchemaSnapshot, to url: URL) throws {
        try encode(snapshot).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SchemaSnapshot {
        var snapshot = try decode(Data(contentsOf: url))
        if snapshot.origin.isEmpty { snapshot.origin = url.lastPathComponent }
        return snapshot
    }
}
