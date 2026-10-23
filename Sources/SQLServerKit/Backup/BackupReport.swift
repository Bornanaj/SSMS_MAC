import Foundation

/// Backup history reports: everything, only problems, or only failures, over a date range, with
/// the databases that are behind on backups.
public struct BackupReport: Sendable {
    public enum Scope: String, CaseIterable, Sendable, Identifiable {
        case all
        case problems
        case failures

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: return "All backup and restore activity"
            case .problems: return "Activity with warnings or failures"
            case .failures: return "Failed activity"
            }
        }
    }

    public var serverName: String
    public var activities: [BackupActivity]
    public var databases: [DatabaseBackupStatus]
    public var thresholds: BackupThresholds
    public var from: Date
    public var to: Date
    public var scope: Scope
    public var now: Date

    public init(serverName: String, activities: [BackupActivity], databases: [DatabaseBackupStatus],
                thresholds: BackupThresholds, from: Date, to: Date, scope: Scope, now: Date) {
        self.serverName = serverName
        self.activities = activities
        self.databases = databases
        self.thresholds = thresholds
        self.from = from
        self.to = to
        self.scope = scope
        self.now = now
    }

    public var rows: [BackupActivity] {
        activities.filter { activity in
            guard let date = activity.date, date >= from, date <= to else { return false }
            switch scope {
            case .all: return true
            case .problems: return !activity.succeeded || activity.hasWarnings || activity.isDamaged
            case .failures: return !activity.succeeded
            }
        }
    }

    public var atRisk: [(DatabaseBackupStatus, BackupRisk)] {
        databases.compactMap { status in
            let risk = status.risk(now: now, thresholds: thresholds)
            return risk == .overdue || risk == .never || risk == .warning ? (status, risk) : nil
        }
    }

    public func render(_ format: CompareReportFormat) -> Data {
        switch format {
        case .csv: return Data(csv().utf8)
        case .json: return json()
        default: return Data(html().utf8)
        }
    }

    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        return String(format: "%d min %02d s", Int(seconds) / 60, Int(seconds) % 60)
    }

    public func csv() -> String {
        var lines: [String] = ["Date,Operation,Database,Type,Outcome,Duration (s),Size,Compressed size,Compressed by,Encrypted,Files,User,Message"]
        for item in rows {
            let fields: [String] = [
                item.date.map(ServerTime.display) ?? "", item.kindTitle, item.database.isEmpty ? item.jobName : item.database,
                item.typeTitle, item.succeeded ? "Succeeded" : "Failed",
                item.duration.map { String(Int($0)) } ?? "", String(item.backupSize), String(item.compressedSize),
                item.compressedBy.map { String(format: "%.1f%%", $0 * 100) } ?? "", item.isEncrypted ? "Yes" : "",
                item.files.joined(separator: "; "), item.userName, item.message
            ]
            lines.append(fields.map(ReportHTML.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func json() -> Data {
        let items: [[String: Any]] = rows.map { item in
            let date: String = item.date.map(ServerTime.display) ?? ""
            return [
                "date": date, "operation": item.kindTitle,
                "database": item.database, "job": item.jobName, "type": item.typeTitle,
                "succeeded": item.succeeded, "durationSeconds": item.duration ?? 0,
                "backupSize": item.backupSize, "compressedSize": item.compressedSize,
                "encrypted": item.isEncrypted, "files": item.files, "user": item.userName, "message": item.message
            ]
        }
        let risk: [[String: Any]] = atRisk.map { status, level in
            ["database": status.name, "risk": level.title,
             "lastFull": status.lastFull.map(ServerTime.display) ?? "",
             "lastLog": status.lastLog.map(ServerTime.display) ?? ""]
        }
        let document: [String: Any] = ["server": serverName, "from": ServerTime.display(from), "to": ServerTime.display(to),
                                       "scope": scope.rawValue, "activity": items, "databasesAtRisk": risk]
        return (try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    public func html() -> String {
        let items = rows
        let backups: Int = items.filter { $0.kind == .backup }.count
        let restores: Int = items.filter { $0.kind == .restore }.count
        let failures: Int = items.filter { !$0.succeeded }.count
        let total: Int64 = items.filter { $0.kind == .backup }.reduce(0) { $0 + $1.compressedSize }
        var out = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\">"
        out += "<title>Backup report: \(ReportHTML.escape(serverName))</title><style>\(ReportHTML.style)"
        out += ".ok{color:#2f855a}.bad{color:#c53030}.warn{color:#b7791f}</style></head><body><main>"
        out += "<h1>Backup report: \(ReportHTML.escape(serverName))</h1>"
        out += "<div class=\"muted\">\(ReportHTML.escape(scope.title)) from \(ServerTime.display(from)) to "
            + "\(ServerTime.display(to)) · generated \(ReportHTML.timestamp(Date()))</div>"
        out += "<div class=\"cards\">"
        out += "<div class=\"card\"><b>\(backups)</b>backups</div><div class=\"card\"><b>\(restores)</b>restores</div>"
        out += "<div class=\"card\"><b class=\"\(failures > 0 ? "bad" : "ok")\">\(failures)</b>failures</div>"
        out += "<div class=\"card\"><b>\(Self.size(total))</b>written</div>"
        out += "<div class=\"card\"><b class=\"\(atRisk.isEmpty ? "ok" : "bad")\">\(atRisk.count)</b>databases behind</div></div>"
        if !atRisk.isEmpty {
            out += "<h2>Databases behind on backups</h2><table><tr><th>Database</th><th>Status</th><th>Recovery model</th>"
                + "<th>Last full</th><th>Last differential</th><th>Last log</th></tr>"
            for (status, risk) in atRisk {
                out += "<tr><td>\(ReportHTML.escape(status.name))</td>"
                    + "<td class=\"\(risk == .warning ? "warn" : "bad")\">\(risk.title)</td>"
                    + "<td>\(ReportHTML.escape(status.recoveryModel))</td>"
                    + "<td>\(status.lastFull.map(ServerTime.display) ?? "Never")</td>"
                    + "<td>\(status.lastDifferential.map(ServerTime.display) ?? "")</td>"
                    + "<td>\(status.lastLog.map(ServerTime.display) ?? "")</td></tr>"
            }
            out += "</table>"
        }
        out += "<h2>Activity (\(items.count))</h2><input id=\"filter\" placeholder=\"Filter by database or job\">"
        out += "<table><tr><th>Date</th><th>Operation</th><th>Database</th><th>Type</th><th>Outcome</th><th>Duration</th>"
            + "<th>Size</th><th>Compressed by</th><th>Files</th><th>Details</th></tr>"
        for item in items {
            let name = item.database.isEmpty ? item.jobName : item.database
            let outcome = item.succeeded ? "<span class=\"ok\">Succeeded</span>" : "<span class=\"bad\">Failed</span>"
            out += "<tr data-name=\"\(ReportHTML.escape(name.lowercased()))\"><td>\(item.date.map(ServerTime.display) ?? "")</td>"
                + "<td>\(item.kindTitle)</td><td>\(ReportHTML.escape(name))</td><td>\(ReportHTML.escape(item.typeTitle))"
                + "\(item.isEncrypted ? " 🔒" : "")</td><td>\(outcome)</td><td>\(Self.duration(item.duration))</td>"
                + "<td>\(Self.size(item.compressedSize))</td>"
                + "<td>\(item.compressedBy.map { String(format: "%.0f%%", $0 * 100) } ?? "")</td>"
                + "<td>\(ReportHTML.escape(item.files.joined(separator: "\n")).replacingOccurrences(of: "\n", with: "<br>"))</td>"
                + "<td class=\"muted\">\(ReportHTML.escape(String(item.message.prefix(400))))</td></tr>"
        }
        out += "</table>\(ReportHTML.filterScript)</main></body></html>"
        return out
    }
}
