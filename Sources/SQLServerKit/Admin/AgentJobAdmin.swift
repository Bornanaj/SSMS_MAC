import Foundation
import TDSKit

// MARK: - Models

public struct AgentJobSummary: Sendable, Hashable, Identifiable {
    public var id: String { jobID }

    public var jobID: String
    public var name: String
    public var isEnabled: Bool
    public var jobDescription: String
    public var owner: String
    public var category: String
    public var createDate: String
    /// "Succeeded", "Failed", "Cancelled", "Retry" or "" when the job has never run.
    public var lastRunOutcome: String
    public var lastRunDate: String
    public var lastRunDurationSeconds: Int
    public var nextRunDate: String
    /// "Idle" or "Executing".
    public var executionStatus: String

    public init(jobID: String = "",
                name: String = "",
                isEnabled: Bool = true,
                jobDescription: String = "",
                owner: String = "",
                category: String = "",
                createDate: String = "",
                lastRunOutcome: String = "",
                lastRunDate: String = "",
                lastRunDurationSeconds: Int = 0,
                nextRunDate: String = "",
                executionStatus: String = "Idle") {
        self.jobID = jobID
        self.name = name
        self.isEnabled = isEnabled
        self.jobDescription = jobDescription
        self.owner = owner
        self.category = category
        self.createDate = createDate
        self.lastRunOutcome = lastRunOutcome
        self.lastRunDate = lastRunDate
        self.lastRunDurationSeconds = lastRunDurationSeconds
        self.nextRunDate = nextRunDate
        self.executionStatus = executionStatus
    }

    public var isRunning: Bool { executionStatus != "Idle" }
    public var lastRunFailed: Bool { lastRunOutcome == "Failed" }
}

public struct AgentJobStep: Sendable, Hashable, Identifiable {
    public var id: Int { stepID }

    public var stepID: Int
    public var name: String
    /// TSQL, CmdExec, PowerShell, SSIS…
    public var subsystem: String
    public var command: String
    public var databaseName: String
    public var onSuccessAction: String
    public var onFailAction: String
    public var retryAttempts: Int
    public var retryIntervalMinutes: Int
    public var lastRunOutcome: String
    public var lastRunDate: String

    public init(stepID: Int = 0,
                name: String = "",
                subsystem: String = "",
                command: String = "",
                databaseName: String = "",
                onSuccessAction: String = "",
                onFailAction: String = "",
                retryAttempts: Int = 0,
                retryIntervalMinutes: Int = 0,
                lastRunOutcome: String = "",
                lastRunDate: String = "") {
        self.stepID = stepID
        self.name = name
        self.subsystem = subsystem
        self.command = command
        self.databaseName = databaseName
        self.onSuccessAction = onSuccessAction
        self.onFailAction = onFailAction
        self.retryAttempts = retryAttempts
        self.retryIntervalMinutes = retryIntervalMinutes
        self.lastRunOutcome = lastRunOutcome
        self.lastRunDate = lastRunDate
    }
}

public struct AgentJobSchedule: Sendable, Hashable, Identifiable {
    public var id: Int { scheduleID }

    public var scheduleID: Int
    public var name: String
    public var isEnabled: Bool
    /// The sentence SSMS puts in the Schedules grid.
    public var scheduleDescription: String
    public var nextRunDate: String

    public init(scheduleID: Int = 0,
                name: String = "",
                isEnabled: Bool = true,
                scheduleDescription: String = "",
                nextRunDate: String = "") {
        self.scheduleID = scheduleID
        self.name = name
        self.isEnabled = isEnabled
        self.scheduleDescription = scheduleDescription
        self.nextRunDate = nextRunDate
    }
}

public struct AgentJobHistoryEntry: Sendable, Hashable, Identifiable {
    public var id: Int { instanceID }

    public var instanceID: Int
    /// Zero is the job outcome row; anything higher is a step.
    public var stepID: Int
    public var stepName: String
    public var runDate: String
    public var durationSeconds: Int
    public var outcome: String
    public var message: String
    public var retriesAttempted: Int

    public init(instanceID: Int = 0,
                stepID: Int = 0,
                stepName: String = "",
                runDate: String = "",
                durationSeconds: Int = 0,
                outcome: String = "",
                message: String = "",
                retriesAttempted: Int = 0) {
        self.instanceID = instanceID
        self.stepID = stepID
        self.stepName = stepName
        self.runDate = runDate
        self.durationSeconds = durationSeconds
        self.outcome = outcome
        self.message = message
        self.retriesAttempted = retriesAttempted
    }

    public var isJobOutcome: Bool { stepID == 0 }
    public var failed: Bool { outcome == "Failed" }
}

// MARK: - Schedule formatting

/// Renders `msdb.dbo.sysschedules` rows as the sentence the SSMS Schedules grid shows.
///
/// The frequency columns are a small bitfield language, and getting it wrong is easy —
/// a weekly schedule stores its days as a mask, a "monthly relative" schedule stores
/// both an ordinal and a weekday, and everything runs through `subday_type`. This is
/// pure so it can be tested without an Agent.
public enum AgentScheduleFormatter {

    public static func describe(freqType: Int,
                                freqInterval: Int,
                                freqRelativeInterval: Int,
                                freqRecurrenceFactor: Int,
                                activeStartTime: Int,
                                activeEndTime: Int,
                                subdayType: Int,
                                subdayInterval: Int) -> String {
        let within = withinDay(subdayType: subdayType,
                               subdayInterval: subdayInterval,
                               startTime: activeStartTime,
                               endTime: activeEndTime)
        switch freqType {
        case 1:
            return "Occurs once at \(time(activeStartTime))."
        case 4:
            let every = freqInterval <= 1 ? "day" : "\(freqInterval) day(s)"
            return "Occurs every \(every) \(within)."
        case 8:
            let weeks = freqRecurrenceFactor <= 1 ? "week" : "\(freqRecurrenceFactor) week(s)"
            let days = weekdayList(mask: freqInterval)
            let onDays = days.isEmpty ? "" : " on \(days)"
            return "Occurs every \(weeks)\(onDays) \(within)."
        case 16:
            let months = freqRecurrenceFactor <= 1 ? "month" : "\(freqRecurrenceFactor) month(s)"
            return "Occurs every \(months) on day \(freqInterval) \(within)."
        case 32:
            let months = freqRecurrenceFactor <= 1 ? "month" : "\(freqRecurrenceFactor) month(s)"
            let ordinal = relativeOrdinal(freqRelativeInterval)
            let unit = relativeUnit(freqInterval)
            return "Occurs every \(months) on the \(ordinal) \(unit) \(within)."
        case 64:
            return "Starts whenever SQL Server Agent starts."
        case 128:
            return "Starts whenever the CPUs become idle."
        default:
            return "Unscheduled."
        }
    }

    private static func withinDay(subdayType: Int,
                                  subdayInterval: Int,
                                  startTime: Int,
                                  endTime: Int) -> String {
        switch subdayType {
        case 2, 4, 8:
            let unit: String
            switch subdayType {
            case 2: unit = "second(s)"
            case 4: unit = "minute(s)"
            default: unit = "hour(s)"
            }
            let start = time(startTime)
            let end = time(endTime)
            return "every \(max(1, subdayInterval)) \(unit) between \(start) and \(end)"
        default:
            return "at \(time(startTime))"
        }
    }

    /// `sysschedules` stores times as the integer `HHMMSS`, so 20000 is 02:00:00.
    public static func time(_ value: Int) -> String {
        let clamped = max(0, value)
        let hours = clamped / 10_000
        let minutes = (clamped / 100) % 100
        let seconds = clamped % 100
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    /// `sysschedules` stores dates as the integer `yyyymmdd`.
    public static func date(_ value: Int) -> String {
        guard value > 0 else { return "" }
        let year = value / 10_000
        let month = (value / 100) % 100
        let day = value % 100
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// A weekly schedule packs its days into a mask starting at Sunday = 1.
    static func weekdayList(mask: Int) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let selected = names.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        if selected.count == 7 { return "every day" }
        if selected.count == 5, mask & 0b0111110 == 0b0111110 { return "weekdays" }
        return selected.joined(separator: ", ")
    }

    static func relativeOrdinal(_ value: Int) -> String {
        switch value {
        case 1: return "first"
        case 2: return "second"
        case 4: return "third"
        case 8: return "fourth"
        case 16: return "last"
        default: return "first"
        }
    }

    static func relativeUnit(_ value: Int) -> String {
        switch value {
        case 1: return "Sunday"
        case 2: return "Monday"
        case 3: return "Tuesday"
        case 4: return "Wednesday"
        case 5: return "Thursday"
        case 6: return "Friday"
        case 7: return "Saturday"
        case 8: return "day"
        case 9: return "weekday"
        case 10: return "weekend day"
        default: return "day"
        }
    }

    /// Agent durations are the integer `HHMMSS`, not a count of seconds.
    public static func durationSeconds(fromAgentDuration value: Int) -> Int {
        let clamped = max(0, value)
        return (clamped / 10_000) * 3600 + ((clamped / 100) % 100) * 60 + clamped % 100
    }

    public static func durationText(seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}

// MARK: - Agent administration

/// SQL Server Agent: the job list, a job's steps, schedules and history, and the
/// start / stop / enable actions from the Jobs context menu.
public struct AgentJobAdmin: Sendable {

    private let session: SQLServerSession
    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.session = session
        self.runner = AdminRunner(session: session)
    }

    private func requireAgent() async throws {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else {
            throw SQLServerError.unsupportedOperation(
                "SQL Server Agent is not available on Azure SQL Database. Use elastic jobs "
                + "or Azure Automation instead.")
        }
    }

    /// A job id is a uniqueidentifier; it is validated as a UUID rather than escaped so a
    /// malformed value can never reach a statement.
    private static func jobIDLiteral(_ jobID: String) throws -> String {
        guard let uuid = UUID(uuidString: jobID) else {
            throw SQLServerError.unsupportedOperation("'\(jobID)' is not a job id.")
        }
        return "'\(uuid.uuidString)'"
    }

    // MARK: Jobs

    public func jobs() async throws -> [AgentJobSummary] {
        try await requireAgent()
        // agent_datetime traps on a zero date, so every call is guarded by the date test.
        let sql = """
        SELECT
            CONVERT(nvarchar(36), j.job_id)                          AS JobId,
            j.name                                                   AS JobName,
            CAST(j.enabled AS int)                                   AS IsEnabled,
            ISNULL(j.description, N'')                               AS JobDescription,
            ISNULL(SUSER_SNAME(j.owner_sid), N'')                    AS OwnerName,
            ISNULL(c.name, N'')                                      AS CategoryName,
            ISNULL(CONVERT(nvarchar(23), j.date_created, 121), N'')   AS CreateDate,
            ISNULL(CONVERT(nvarchar(23),
                CASE WHEN js.last_run_date > 0
                     THEN msdb.dbo.agent_datetime(js.last_run_date, js.last_run_time) END,
                121), N'')                                           AS LastRunDate,
            CAST(ISNULL(js.last_run_outcome, 5) AS int)              AS LastRunOutcome,
            CAST(ISNULL(js.last_run_duration, 0) AS int)             AS LastRunDuration,
            ISNULL(CONVERT(nvarchar(23),
                CASE WHEN ja.next_scheduled_run_date IS NOT NULL
                     THEN ja.next_scheduled_run_date END, 121), N'')  AS NextRunDate,
            CAST(CASE WHEN ja.run_requested_date IS NOT NULL
                       AND ja.stop_execution_date IS NULL
                      THEN 1 ELSE 0 END AS int)                      AS IsRunning
        FROM msdb.dbo.sysjobs AS j
        LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
        LEFT JOIN msdb.dbo.sysjobservers AS js ON js.job_id = j.job_id
        OUTER APPLY (
            SELECT TOP (1) a.run_requested_date, a.stop_execution_date, a.next_scheduled_run_date
            FROM msdb.dbo.sysjobactivity AS a
            WHERE a.job_id = j.job_id
            ORDER BY a.session_id DESC, a.job_history_id DESC
        ) AS ja
        ORDER BY j.name;
        """
        return try await runner.read(sql, database: "msdb").map { row in
            AgentJobSummary(
                jobID: row.string("JobId"),
                name: row.string("JobName"),
                isEnabled: row.bool("IsEnabled"),
                jobDescription: row.string("JobDescription"),
                owner: row.string("OwnerName"),
                category: row.string("CategoryName"),
                createDate: row.string("CreateDate"),
                lastRunOutcome: AgentJobAdmin.outcomeName(row.int("LastRunOutcome", default: 5)),
                lastRunDate: row.string("LastRunDate"),
                lastRunDurationSeconds: AgentScheduleFormatter.durationSeconds(
                    fromAgentDuration: row.int("LastRunDuration")),
                nextRunDate: row.string("NextRunDate"),
                executionStatus: row.bool("IsRunning") ? "Executing" : "Idle"
            )
        }
    }

    public func steps(jobID: String) async throws -> [AgentJobStep] {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        let sql = """
        SELECT
            CAST(s.step_id AS int)                                   AS StepId,
            s.step_name                                              AS StepName,
            ISNULL(s.subsystem, N'')                                 AS Subsystem,
            ISNULL(CONVERT(nvarchar(max), s.command), N'')            AS StepCommand,
            ISNULL(s.database_name, N'')                             AS DatabaseName,
            CAST(s.on_success_action AS int)                          AS OnSuccessAction,
            CAST(s.on_fail_action AS int)                             AS OnFailAction,
            CAST(s.retry_attempts AS int)                             AS RetryAttempts,
            CAST(s.retry_interval AS int)                             AS RetryInterval,
            CAST(ISNULL(s.last_run_outcome, 5) AS int)                AS LastRunOutcome,
            ISNULL(CONVERT(nvarchar(23),
                CASE WHEN s.last_run_date > 0
                     THEN msdb.dbo.agent_datetime(s.last_run_date, s.last_run_time) END,
                121), N'')                                            AS LastRunDate
        FROM msdb.dbo.sysjobsteps AS s
        WHERE s.job_id = \(literal)
        ORDER BY s.step_id;
        """
        return try await runner.read(sql, database: "msdb").map { row in
            AgentJobStep(
                stepID: row.int("StepId"),
                name: row.string("StepName"),
                subsystem: row.string("Subsystem"),
                command: row.string("StepCommand"),
                databaseName: row.string("DatabaseName"),
                onSuccessAction: AgentJobAdmin.stepActionName(row.int("OnSuccessAction")),
                onFailAction: AgentJobAdmin.stepActionName(row.int("OnFailAction")),
                retryAttempts: row.int("RetryAttempts"),
                retryIntervalMinutes: row.int("RetryInterval"),
                lastRunOutcome: AgentJobAdmin.outcomeName(row.int("LastRunOutcome", default: 5)),
                lastRunDate: row.string("LastRunDate")
            )
        }
    }

    public func schedules(jobID: String) async throws -> [AgentJobSchedule] {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        let sql = """
        SELECT
            CAST(sc.schedule_id AS int)                              AS ScheduleId,
            sc.name                                                  AS ScheduleName,
            CAST(sc.enabled AS int)                                  AS IsEnabled,
            CAST(sc.freq_type AS int)                                AS FreqType,
            CAST(sc.freq_interval AS int)                            AS FreqInterval,
            CAST(sc.freq_relative_interval AS int)                   AS FreqRelativeInterval,
            CAST(sc.freq_recurrence_factor AS int)                   AS FreqRecurrenceFactor,
            CAST(sc.active_start_time AS int)                        AS ActiveStartTime,
            CAST(sc.active_end_time AS int)                          AS ActiveEndTime,
            CAST(sc.active_start_date AS int)                        AS ActiveStartDate,
            CAST(ISNULL(sc.freq_subday_type, 1) AS int)              AS SubdayType,
            CAST(ISNULL(sc.freq_subday_interval, 0) AS int)          AS SubdayInterval
        FROM msdb.dbo.sysjobschedules AS jsc
        JOIN msdb.dbo.sysschedules AS sc ON sc.schedule_id = jsc.schedule_id
        WHERE jsc.job_id = \(literal)
        ORDER BY sc.name;
        """
        return try await runner.read(sql, database: "msdb").map { row in
            let description = AgentScheduleFormatter.describe(
                freqType: row.int("FreqType"),
                freqInterval: row.int("FreqInterval"),
                freqRelativeInterval: row.int("FreqRelativeInterval"),
                freqRecurrenceFactor: row.int("FreqRecurrenceFactor"),
                activeStartTime: row.int("ActiveStartTime"),
                activeEndTime: row.int("ActiveEndTime", default: 235_959),
                subdayType: row.int("SubdayType", default: 1),
                subdayInterval: row.int("SubdayInterval")
            )
            return AgentJobSchedule(
                scheduleID: row.int("ScheduleId"),
                name: row.string("ScheduleName"),
                isEnabled: row.bool("IsEnabled"),
                scheduleDescription: description,
                nextRunDate: AgentScheduleFormatter.date(row.int("ActiveStartDate"))
            )
        }
    }

    public func history(jobID: String, limit: Int = 200) async throws -> [AgentJobHistoryEntry] {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        let sql = """
        SELECT TOP (\(max(1, limit)))
            CAST(h.instance_id AS int)                               AS InstanceId,
            CAST(h.step_id AS int)                                   AS StepId,
            ISNULL(h.step_name, N'')                                 AS StepName,
            ISNULL(CONVERT(nvarchar(23),
                CASE WHEN h.run_date > 0
                     THEN msdb.dbo.agent_datetime(h.run_date, h.run_time) END, 121), N'')
                                                                     AS RunDate,
            CAST(ISNULL(h.run_duration, 0) AS int)                   AS RunDuration,
            CAST(h.run_status AS int)                                AS RunStatus,
            ISNULL(h.message, N'')                                   AS HistoryMessage,
            CAST(ISNULL(h.retries_attempted, 0) AS int)              AS RetriesAttempted
        FROM msdb.dbo.sysjobhistory AS h
        WHERE h.job_id = \(literal)
        ORDER BY h.instance_id DESC;
        """
        return try await runner.read(sql, database: "msdb").map { row in
            AgentJobHistoryEntry(
                instanceID: row.int("InstanceId"),
                stepID: row.int("StepId"),
                stepName: row.string("StepName"),
                runDate: row.string("RunDate"),
                durationSeconds: AgentScheduleFormatter.durationSeconds(
                    fromAgentDuration: row.int("RunDuration")),
                outcome: AgentJobAdmin.outcomeName(row.int("RunStatus", default: 5)),
                message: row.string("HistoryMessage"),
                retriesAttempted: row.int("RetriesAttempted")
            )
        }
    }

    // MARK: Actions

    public func start(jobID: String, stepName: String? = nil) async throws {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        var sql = "EXEC msdb.dbo.sp_start_job @job_id = \(literal)"
        if let stepName, !stepName.isEmpty {
            sql += ", @step_name = \(SQLIdentifier.literal(stepName))"
        }
        try await runner.run(sql + ";", database: "msdb")
    }

    public func stop(jobID: String) async throws {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        try await runner.run("EXEC msdb.dbo.sp_stop_job @job_id = \(literal);", database: "msdb")
    }

    public func setEnabled(jobID: String, enabled: Bool) async throws {
        try await requireAgent()
        let literal = try AgentJobAdmin.jobIDLiteral(jobID)
        try await runner.run(
            "EXEC msdb.dbo.sp_update_job @job_id = \(literal), @enabled = \(enabled ? 1 : 0);",
            database: "msdb")
    }

    /// Whether the Agent service is running. `sysjobactivity` exists even when it is not,
    /// so the service state is read from the process list.
    public func isAgentRunning() async throws -> Bool {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else { return false }
        let sql = """
        SELECT CAST(COUNT(*) AS int) AS AgentSessions
        FROM sys.dm_exec_sessions
        WHERE program_name LIKE N'SQLAgent%';
        """
        let rows = try await runner.read(sql, database: "master")
        return (rows.first?.int("AgentSessions") ?? 0) > 0
    }

    /// The script behind "Script Job as CREATE To", assembled from the job's own rows.
    public func createScript(jobID: String) async throws -> String {
        let all = try await jobs()
        guard let job = all.first(where: { $0.jobID.caseInsensitiveCompare(jobID) == .orderedSame })
        else { throw SQLServerError.objectNotFound("Job \(jobID)") }
        let jobSteps = try await steps(jobID: jobID)

        var out = "USE [msdb];\nGO\n\n"
        out += "EXEC msdb.dbo.sp_add_job\n"
        out += "    @job_name = \(SQLIdentifier.literal(job.name)),\n"
        out += "    @enabled = \(job.isEnabled ? 1 : 0),\n"
        out += "    @description = \(SQLIdentifier.literal(job.jobDescription));\nGO\n"
        for step in jobSteps {
            out += "\nEXEC msdb.dbo.sp_add_jobstep\n"
            out += "    @job_name = \(SQLIdentifier.literal(job.name)),\n"
            out += "    @step_id = \(step.stepID),\n"
            out += "    @step_name = \(SQLIdentifier.literal(step.name)),\n"
            out += "    @subsystem = \(SQLIdentifier.literal(step.subsystem)),\n"
            if !step.databaseName.isEmpty {
                out += "    @database_name = \(SQLIdentifier.literal(step.databaseName)),\n"
            }
            out += "    @retry_attempts = \(step.retryAttempts),\n"
            out += "    @retry_interval = \(step.retryIntervalMinutes),\n"
            out += "    @command = \(SQLIdentifier.literal(step.command));\nGO\n"
        }
        out += "\nEXEC msdb.dbo.sp_add_jobserver "
            + "@job_name = \(SQLIdentifier.literal(job.name)), @server_name = N'(local)';\nGO\n"
        return out
    }

    // MARK: Lookups

    /// `sysjobhistory.run_status` and `sysjobservers.last_run_outcome` share this coding.
    static func outcomeName(_ code: Int) -> String {
        switch code {
        case 0: return "Failed"
        case 1: return "Succeeded"
        case 2: return "Retry"
        case 3: return "Cancelled"
        case 4: return "In progress"
        default: return ""
        }
    }

    static func stepActionName(_ code: Int) -> String {
        switch code {
        case 1: return "Quit with success"
        case 2: return "Quit with failure"
        case 3: return "Go to next step"
        case 4: return "Go to step"
        default: return "Unknown (\(code))"
        }
    }
}
