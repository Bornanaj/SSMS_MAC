import Foundation
import TDSKit

// MARK: - Models

public struct AgentJob: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var category: String
    public var owner: String
    public var jobDescription: String
    public var createdAt: String
    public var lastRunOutcome: String
    public var lastRunAt: String
    public var lastRunDuration: String
    public var nextRunAt: String
    public var currentStatus: String
    public var scheduleSummary: String

    public var isRunning: Bool { currentStatus == "Executing" }

    public var outcomeSymbol: String {
        switch lastRunOutcome {
        case "Succeeded": return "checkmark.circle.fill"
        case "Failed": return "xmark.circle.fill"
        case "Cancelled": return "minus.circle.fill"
        case "Retry": return "arrow.clockwise.circle.fill"
        default: return "questionmark.circle"
        }
    }
}

public struct AgentJobStep: Sendable, Hashable, Identifiable {
    public var id: Int { stepID }
    public var stepID: Int
    public var name: String
    public var subsystem: String
    public var command: String
    public var databaseName: String
    public var onSuccessAction: String
    public var onFailAction: String
    public var retryAttempts: Int
    public var lastRunOutcome: String
    public var lastRunAt: String
}

public struct AgentJobSchedule: Sendable, Hashable, Identifiable {
    public var id: Int { scheduleID }
    public var scheduleID: Int
    public var name: String
    public var isEnabled: Bool
    public var summary: String
    public var nextRunAt: String
}

public struct AgentJobHistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int { instanceID }
    public var instanceID: Int
    public var stepID: Int
    public var stepName: String
    public var runAt: String
    public var duration: String
    public var outcome: String
    public var message: String
    public var retriesAttempted: Int
}

// MARK: - Service

public struct AgentService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// SQL Server Agent lives in msdb, which Azure SQL Database does not have.
    private func requireAgent() async throws {
        let info = await session.serverInfo
        if info.isAzureSQLDatabase {
            throw SQLServerError.unsupportedOperation(
                "SQL Server Agent is not available on Azure SQL Database. "
                    + "Use Elastic Jobs or Azure Automation instead.")
        }
    }

    public func isAgentRunning() async -> Bool {
        let sql = """
        SELECT COUNT(*) AS running
        FROM sys.dm_server_services
        WHERE servicename LIKE N'SQL Server Agent%' AND status_desc = N'Running'
        """
        guard let result = try? await session.metadataQuery(sql, database: "master"),
              let row = result.resultSets.first?.dictionaries().first else { return false }
        return row.int("running") > 0
    }

    // MARK: Jobs

    public func jobs() async throws -> [AgentJob] {
        try await requireAgent()
        // msdb stores run_date/run_time as integers, so they are rebuilt into a real
        // datetime rather than shown as 20260825 / 143012.
        let sql = """
        SELECT CONVERT(nvarchar(36), j.job_id) AS job_id,
               j.name,
               CAST(j.enabled AS int) AS enabled,
               ISNULL(c.name, N'') AS category,
               ISNULL(SUSER_SNAME(j.owner_sid), N'') AS owner_name,
               ISNULL(j.description, N'') AS job_description,
               CONVERT(nvarchar(30), j.date_created, 120) AS date_created,
               ISNULL(CASE h.run_status
                        WHEN 0 THEN N'Failed'
                        WHEN 1 THEN N'Succeeded'
                        WHEN 2 THEN N'Retry'
                        WHEN 3 THEN N'Cancelled'
                        WHEN 4 THEN N'In progress'
                      END, N'Never run') AS last_outcome,
               ISNULL(CONVERT(nvarchar(30),
                   msdb.dbo.agent_datetime(h.run_date, h.run_time), 120), N'') AS last_run,
               ISNULL(RIGHT(N'000000' + CAST(h.run_duration AS nvarchar(10)), 6), N'') AS last_duration,
               ISNULL(CONVERT(nvarchar(30),
                   msdb.dbo.agent_datetime(NULLIF(ja.next_scheduled_run_date, 0),
                                           ja.next_scheduled_run_date), 120), N'') AS next_run,
               ISNULL(CASE WHEN ja.start_execution_date IS NOT NULL
                            AND ja.stop_execution_date IS NULL
                           THEN N'Executing' ELSE N'Idle' END, N'Idle') AS current_status,
               ISNULL(STUFF((SELECT N', ' + s.name
                             FROM msdb.dbo.sysjobschedules AS js
                             JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
                             WHERE js.job_id = j.job_id
                             ORDER BY s.name
                             FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''),
                       N'Not scheduled') AS schedules
        FROM msdb.dbo.sysjobs AS j
        LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
        OUTER APPLY (
            SELECT TOP (1) h2.run_status, h2.run_date, h2.run_time, h2.run_duration
            FROM msdb.dbo.sysjobhistory AS h2
            WHERE h2.job_id = j.job_id AND h2.step_id = 0
            ORDER BY h2.run_date DESC, h2.run_time DESC
        ) AS h
        OUTER APPLY (
            SELECT TOP (1) a.start_execution_date, a.stop_execution_date,
                   a.next_scheduled_run_date
            FROM msdb.dbo.sysjobactivity AS a
            WHERE a.job_id = j.job_id
            ORDER BY a.session_id DESC
        ) AS ja
        ORDER BY j.name
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            AgentJob(
                id: row.string("job_id"),
                name: row.string("name"),
                isEnabled: row.int("enabled") == 1,
                category: row.string("category"),
                owner: row.string("owner_name"),
                jobDescription: row.string("job_description"),
                createdAt: row.string("date_created"),
                lastRunOutcome: row.string("last_outcome"),
                lastRunAt: row.string("last_run"),
                lastRunDuration: AgentService.formatDuration(row.string("last_duration")),
                nextRunAt: row.string("next_run"),
                currentStatus: row.string("current_status"),
                scheduleSummary: row.string("schedules"))
        }
    }

    public func steps(jobID: String) async throws -> [AgentJobStep] {
        try await requireAgent()
        let sql = """
        SELECT s.step_id, s.step_name, s.subsystem, ISNULL(s.command, N'') AS command,
               ISNULL(s.database_name, N'') AS database_name,
               CASE s.on_success_action
                   WHEN 1 THEN N'Quit with success'
                   WHEN 2 THEN N'Quit with failure'
                   WHEN 3 THEN N'Go to next step'
                   WHEN 4 THEN N'Go to step ' + CAST(s.on_success_step_id AS nvarchar(10))
                   ELSE N'' END AS on_success,
               CASE s.on_fail_action
                   WHEN 1 THEN N'Quit with success'
                   WHEN 2 THEN N'Quit with failure'
                   WHEN 3 THEN N'Go to next step'
                   WHEN 4 THEN N'Go to step ' + CAST(s.on_fail_step_id AS nvarchar(10))
                   ELSE N'' END AS on_fail,
               s.retry_attempts,
               ISNULL(CASE s.last_run_outcome
                        WHEN 0 THEN N'Failed' WHEN 1 THEN N'Succeeded'
                        WHEN 2 THEN N'Retry' WHEN 3 THEN N'Cancelled'
                      END, N'Never run') AS last_outcome,
               ISNULL(CONVERT(nvarchar(30),
                   msdb.dbo.agent_datetime(NULLIF(s.last_run_date, 0), s.last_run_time), 120),
                   N'') AS last_run
        FROM msdb.dbo.sysjobsteps AS s
        WHERE s.job_id = @job
        ORDER BY s.step_id
        """
        let bound = sql.replacingOccurrences(of: "@job", with: "CONVERT(uniqueidentifier, "
                                             + SQLIdentifier.literal(jobID) + ")")
        let result = try await session.metadataQuery(bound, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            AgentJobStep(
                stepID: row.int("step_id"),
                name: row.string("step_name"),
                subsystem: row.string("subsystem"),
                command: row.string("command"),
                databaseName: row.string("database_name"),
                onSuccessAction: row.string("on_success"),
                onFailAction: row.string("on_fail"),
                retryAttempts: row.int("retry_attempts"),
                lastRunOutcome: row.string("last_outcome"),
                lastRunAt: row.string("last_run"))
        }
    }

    public func schedules(jobID: String) async throws -> [AgentJobSchedule] {
        try await requireAgent()
        let sql = """
        SELECT s.schedule_id, s.name, CAST(s.enabled AS int) AS enabled,
               s.freq_type, s.freq_interval, s.freq_subday_type, s.freq_subday_interval,
               s.active_start_time,
               ISNULL(CONVERT(nvarchar(30),
                   msdb.dbo.agent_datetime(NULLIF(js.next_run_date, 0), js.next_run_time), 120),
                   N'') AS next_run
        FROM msdb.dbo.sysjobschedules AS js
        JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id
        WHERE js.job_id = @job
        ORDER BY s.name
        """
        let bound = sql.replacingOccurrences(of: "@job", with: "CONVERT(uniqueidentifier, "
                                             + SQLIdentifier.literal(jobID) + ")")
        let result = try await session.metadataQuery(bound, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            AgentJobSchedule(
                scheduleID: row.int("schedule_id"),
                name: row.string("name"),
                isEnabled: row.int("enabled") == 1,
                summary: AgentService.describeSchedule(
                    frequencyType: row.int("freq_type"),
                    interval: row.int("freq_interval"),
                    subdayType: row.int("freq_subday_type"),
                    subdayInterval: row.int("freq_subday_interval"),
                    startTime: row.int("active_start_time")),
                nextRunAt: row.string("next_run"))
        }
    }

    public func history(jobID: String, limit: Int = 200) async throws -> [AgentJobHistoryEntry] {
        try await requireAgent()
        let sql = """
        SELECT TOP (\(max(1, limit)))
               h.instance_id, h.step_id, ISNULL(h.step_name, N'(job outcome)') AS step_name,
               ISNULL(CONVERT(nvarchar(30),
                   msdb.dbo.agent_datetime(h.run_date, h.run_time), 120), N'') AS run_at,
               RIGHT(N'000000' + CAST(h.run_duration AS nvarchar(10)), 6) AS duration,
               CASE h.run_status
                   WHEN 0 THEN N'Failed' WHEN 1 THEN N'Succeeded'
                   WHEN 2 THEN N'Retry' WHEN 3 THEN N'Cancelled'
                   WHEN 4 THEN N'In progress' ELSE N'Unknown' END AS outcome,
               ISNULL(h.message, N'') AS message,
               h.retries_attempted
        FROM msdb.dbo.sysjobhistory AS h
        WHERE h.job_id = @job
        ORDER BY h.instance_id DESC
        """
        let bound = sql.replacingOccurrences(of: "@job", with: "CONVERT(uniqueidentifier, "
                                             + SQLIdentifier.literal(jobID) + ")")
        let result = try await session.metadataQuery(bound, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            AgentJobHistoryEntry(
                instanceID: row.int("instance_id"),
                stepID: row.int("step_id"),
                stepName: row.string("step_name"),
                runAt: row.string("run_at"),
                duration: AgentService.formatDuration(row.string("duration")),
                outcome: row.string("outcome"),
                message: row.string("message"),
                retriesAttempted: row.int("retries_attempted"))
        }
    }

    // MARK: Actions

    public func startJob(name: String, stepName: String? = nil) async throws {
        try await requireAgent()
        var call = "EXEC msdb.dbo.sp_start_job @job_name = \(SQLIdentifier.literal(name))"
        if let stepName, !stepName.isEmpty {
            call += ", @step_name = \(SQLIdentifier.literal(stepName))"
        }
        try await run(call + ";")
    }

    public func stopJob(name: String) async throws {
        try await requireAgent()
        try await run("EXEC msdb.dbo.sp_stop_job @job_name = \(SQLIdentifier.literal(name));")
    }

    public func setJobEnabled(name: String, enabled: Bool) async throws {
        try await requireAgent()
        try await run("EXEC msdb.dbo.sp_update_job @job_name = \(SQLIdentifier.literal(name)), "
                      + "@enabled = \(enabled ? 1 : 0);")
    }

    public func deleteJobScript(name: String) -> String {
        "EXEC msdb.dbo.sp_delete_job @job_name = \(SQLIdentifier.literal(name));"
    }

    /// The CREATE-equivalent SSMS produces under "Script Job as".
    public func scriptJob(_ job: AgentJob, steps: [AgentJobStep],
                          schedules: [AgentJobSchedule]) -> String {
        var lines: [String] = []
        lines.append("USE [msdb];")
        lines.append("GO")
        lines.append("BEGIN TRANSACTION;")
        lines.append("DECLARE @ReturnCode int = 0;")
        lines.append("DECLARE @jobId binary(16);")
        lines.append("EXEC @ReturnCode = msdb.dbo.sp_add_job")
        lines.append("     @job_name = \(SQLIdentifier.literal(job.name)),")
        lines.append("     @enabled = \(job.isEnabled ? 1 : 0),")
        lines.append("     @description = \(SQLIdentifier.literal(job.jobDescription)),")
        lines.append("     @category_name = \(SQLIdentifier.literal(job.category)),")
        lines.append("     @job_id = @jobId OUTPUT;")

        for step in steps {
            lines.append("EXEC @ReturnCode = msdb.dbo.sp_add_jobstep")
            lines.append("     @job_id = @jobId,")
            lines.append("     @step_name = \(SQLIdentifier.literal(step.name)),")
            lines.append("     @step_id = \(step.stepID),")
            lines.append("     @subsystem = \(SQLIdentifier.literal(step.subsystem)),")
            lines.append("     @command = \(SQLIdentifier.literal(step.command)),")
            lines.append("     @database_name = \(SQLIdentifier.literal(step.databaseName)),")
            lines.append("     @retry_attempts = \(step.retryAttempts);")
        }

        for schedule in schedules {
            lines.append("EXEC @ReturnCode = msdb.dbo.sp_attach_schedule")
            lines.append("     @job_id = @jobId,")
            lines.append("     @schedule_name = \(SQLIdentifier.literal(schedule.name));")
        }

        lines.append("EXEC @ReturnCode = msdb.dbo.sp_add_jobserver "
                     + "@job_id = @jobId, @server_name = N'(local)';")
        lines.append("COMMIT TRANSACTION;")
        lines.append("GO")
        return lines.joined(separator: "\n")
    }

    private func run(_ script: String) async throws {
        let connection = try await session.openConnection(database: "msdb")
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(script)
    }

    public func execute(_ script: String) async throws {
        try await run(script)
    }

    // MARK: Formatting

    /// msdb stores durations as HHMMSS packed into an integer.
    static func formatDuration(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber }
        guard digits.count >= 6 else { return raw.isEmpty ? "" : raw }
        let padded = String(digits.suffix(6))
        let hours = Int(padded.prefix(2)) ?? 0
        let minutes = Int(padded.dropFirst(2).prefix(2)) ?? 0
        let seconds = Int(padded.suffix(2)) ?? 0
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Turn the sysschedules frequency columns into the sentence SSMS shows.
    static func describeSchedule(frequencyType: Int, interval: Int, subdayType: Int,
                                 subdayInterval: Int, startTime: Int) -> String {
        func time(_ packed: Int) -> String {
            let hours = packed / 10000
            let minutes = (packed / 100) % 100
            let seconds = packed % 100
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }

        let recurrence: String
        switch frequencyType {
        case 1: return "Once, at \(time(startTime))"
        case 4:
            recurrence = interval <= 1 ? "Every day" : "Every \(interval) days"
        case 8:
            let days = AgentService.weekdays(mask: interval)
            recurrence = days.isEmpty ? "Weekly" : "Weekly on \(days.joined(separator: ", "))"
        case 16:
            recurrence = "Monthly on day \(interval)"
        case 32:
            recurrence = "Monthly, relative"
        case 64: return "When SQL Server Agent starts"
        case 128: return "When the CPU becomes idle"
        default:
            recurrence = "Unscheduled"
        }

        switch subdayType {
        case 2:
            return "\(recurrence), every \(subdayInterval) second(s)"
        case 4:
            return "\(recurrence), every \(subdayInterval) minute(s)"
        case 8:
            return "\(recurrence), every \(subdayInterval) hour(s)"
        default:
            return "\(recurrence) at \(time(startTime))"
        }
    }

    static func weekdays(mask: Int) -> [String] {
        let names = [(1, "Sunday"), (2, "Monday"), (4, "Tuesday"), (8, "Wednesday"),
                     (16, "Thursday"), (32, "Friday"), (64, "Saturday")]
        return names.compactMap { mask & $0.0 != 0 ? $0.1 : nil }
    }
}
