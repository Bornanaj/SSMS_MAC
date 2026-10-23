import SwiftUI
import AppKit
import SQLServerKit

/// State of the Restore wizard.
@MainActor
final class RestoreWizardModel: ObservableObject {
    enum Step: String, CaseIterable, Identifiable {
        case backups = "Backups"
        case destination = "Destination and Files"
        case options = "Restore Options"
        case summary = "Summary"
        var id: String { rawValue }
    }

    enum Source: String, CaseIterable, Identifiable {
        case history = "Select from backup history"
        case files = "Browse for backup files"
        var id: String { rawValue }
    }

    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let serverName: String
    let databases: [DatabaseBackupStatus]

    @Published var step: Step = .backups
    @Published var source: Source = .history
    @Published var sourceDatabase = ""
    @Published private(set) var historyDatabases: [String] = []
    @Published private(set) var sets: [BackupSetInfo] = []
    @Published var files: [String] = []
    @Published private(set) var fileProblems: [String] = []
    @Published var selectedSetID: Int?
    @Published var usePointInTime = false
    @Published var pointInTime = Date()
    @Published private(set) var chain: RestoreChain?
    @Published private(set) var latestChain: RestoreChain?
    @Published private(set) var chainError: String?
    @Published private(set) var fileList: [RestoreFileInfo] = []
    @Published var options = RestoreOptions()
    @Published var createNew = true
    @Published private(set) var isLoading = false

    @Published private(set) var isRunning = false
    @Published private(set) var fraction: Double = 0
    @Published private(set) var progressText = ""
    @Published private(set) var outcome: RestoreOutcome?
    @Published var errorText: String?

    init(window: BackupWindowModel, session: SQLServerSession, capabilities: BackupServerCapabilities, database: String?) {
        self.session = session
        self.capabilities = capabilities
        self.serverName = window.serverName
        self.databases = window.databases
        sourceDatabase = database ?? ""
        options.destinationDatabase = database.map { "\($0)_Restored" } ?? ""
    }

    var stepIndex: Int { Step.allCases.firstIndex(of: step) ?? 0 }
    func next() { if stepIndex + 1 < Step.allCases.count { step = Step.allCases[stepIndex + 1] } }
    func back() { if stepIndex > 0 { step = Step.allCases[stepIndex - 1] } }

    // MARK: Loading

    func load() async {
        historyDatabases = (try? await BackupHistoryReader(session: session).databasesWithHistory()) ?? []
        if sourceDatabase.isEmpty { sourceDatabase = historyDatabases.first ?? "" }
        await loadSets()
    }

    func loadSets() async {
        isLoading = true
        defer { isLoading = false }
        switch source {
        case .history:
            guard !sourceDatabase.isEmpty else { sets = []; return }
            sets = (try? await BackupHistoryReader(session: session).backupSets(database: sourceDatabase)) ?? []
            fileProblems = []
        case .files:
            let read = await BackupMediaReader(session: session).read(paths: files)
            sets = read.sets
            fileProblems = read.problems
        }
        selectedSetID = sets.filter { $0.deviceType != 7 }.max { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) }?.id
        rebuildChain()
    }

    func addFiles(_ paths: [String]) {
        for path in paths where !files.contains(path) { files.append(path) }
        Task { await loadSets() }
    }

    func removeFile(_ path: String) {
        files.removeAll { $0 == path }
        Task { await loadSets() }
    }

    /// Newest first, as the list shows them.
    var sortedSets: [BackupSetInfo] {
        sets.sorted { ($0.finished ?? .distantPast) > ($1.finished ?? .distantPast) }
    }

    func isInChain(_ set: BackupSetInfo) -> Bool {
        chain?.steps.contains { $0.id == set.id } ?? false
    }

    // MARK: Chain

    func rebuildChain() {
        chainError = nil
        latestChain = nil
        guard !sets.isEmpty else {
            chain = nil
            return
        }
        // The point-in-time range is what the selected backup's chain can reach.
        if let id = selectedSetID, let target = sets.first(where: { $0.id == id }) {
            switch RestoreChainBuilder.chain(ending: target, in: sets) {
            case .success(let value): latestChain = value
            case .failure(let error): chainError = error.description
            }
        } else if case .success(let value) = RestoreChainBuilder.chain(pointInTime: nil, in: sets) {
            latestChain = value
        }
        guard let latest = latestChain else {
            chain = nil
            return
        }
        if usePointInTime, !latest.logs.isEmpty {
            let earliest = latest.earliestTime ?? pointInTime
            let latestTime = latest.latestTime ?? pointInTime
            if pointInTime < earliest || pointInTime > latestTime { pointInTime = latestTime }
            let allowed = Set(latest.steps.map(\.id))
            let restricted = sets.filter { allowed.contains($0.id) }
            switch RestoreChainBuilder.chain(pointInTime: pointInTime, in: restricted) {
            case .success(let value): chain = value
            case .failure(let error):
                chain = nil
                chainError = error.description
            }
        } else {
            chain = latest
        }
        if source == .history && !createNew && options.destinationDatabase.isEmpty {
            options.destinationDatabase = sourceDatabase
        }
        Task { await loadFileList() }
    }

    func loadFileList() async {
        guard let full = chain?.full else {
            fileList = []
            return
        }
        do {
            fileList = try await BackupMediaReader(session: session).fileList(for: full)
        } catch {
            fileList = []
            chainError = "The backup's file list could not be read: \(ScriptRunner.describeError(error))"
        }
    }

    var pointInTimeRange: ClosedRange<Date>? {
        guard let latest = latestChain, !latest.logs.isEmpty, let start = latest.earliestTime, let end = latest.latestTime,
              start < end else { return nil }
        return start...end
    }

    // MARK: Destination

    var destinationStatus: DatabaseBackupStatus? {
        databases.first { $0.name.caseInsensitiveCompare(options.destinationDatabase) == .orderedSame }
    }

    var destinationExists: Bool { destinationStatus != nil }

    var canBackUpTail: Bool {
        guard let status = destinationStatus else { return false }
        return status.operationalState == .operational && status.recoveryModel.uppercased() != "SIMPLE"
    }

    func suggestTailPath() {
        guard options.tailLogPath.isEmpty else { return }
        let stamp = ServerTime.format(capabilities.serverTime ?? Date(), "yyyyMMdd_HHmmss")
        options.tailLogPath = capabilities.join(capabilities.backupFolder,
                                                "LOG_\(capabilities.instanceTag)_\(options.destinationDatabase)_\(stamp)_tail.trn")
    }

    var planner: RestorePlanner? {
        guard let chain else { return nil }
        var adjusted = options
        if createNew { adjusted.replaceExisting = false; adjusted.tailLogBackup = false }
        return RestorePlanner(chain: chain, files: fileList, options: adjusted, capabilities: capabilities,
                              destinationExists: destinationExists,
                              destinationIsRestoring: destinationStatus?.operationalState == .nonOperational
                                || destinationStatus?.stateDescription.uppercased() == "RESTORING")
    }

    func errors(for step: Step) -> [String] {
        switch step {
        case .backups:
            var errors: [String] = []
            if source == .files && files.isEmpty { errors.append("Add the backup files to restore.") }
            if chain == nil { errors.append(chainError ?? "Choose the backup to restore.") }
            if let chain, chain.steps.contains(where: { $0.deviceType == 7 }) {
                errors.append("A backup made by another tool (a virtual device) is in the chain and cannot be restored here.")
            }
            return errors
        case .destination:
            var errors: [String] = []
            if options.destinationDatabase.trimmingCharacters(in: .whitespaces).isEmpty {
                errors.append("Enter the database to restore to.")
            }
            if createNew && destinationExists {
                errors.append("\(options.destinationDatabase) already exists. Choose to overwrite it instead.")
            }
            if let planner {
                errors += planner.validationErrors().filter { !$0.contains("Enter the name") }
            }
            return errors
        case .options:
            return []
        case .summary:
            return errors(for: .backups) + errors(for: .destination)
        }
    }

    // MARK: Run

    func run(window: BackupWindowModel) {
        guard !isRunning, chain != nil else { return }
        isRunning = true
        outcome = nil
        errorText = nil
        Task {
            await perform(window: window)
            isRunning = false
            await window.refresh()
        }
    }

    private func perform(window: BackupWindowModel) async {
        var plannerToRun = planner
        let takeTail = !createNew && options.tailLogBackup && canBackUpTail
        if takeTail {
            progressText = "Backing up the tail of the log"
            do {
                try await RestoreRunner.backUpTail(session: session, database: options.destinationDatabase,
                                                   path: options.tailLogPath, killConnections: options.killConnections)
                // The tail now belongs in the chain when restoring the same database to its latest point.
                if source == .history && sourceDatabase.caseInsensitiveCompare(options.destinationDatabase) == .orderedSame {
                    let refreshed = (try? await BackupHistoryReader(session: session).backupSets(database: sourceDatabase)) ?? sets
                    let rebuilt = usePointInTime ? RestoreChainBuilder.chain(pointInTime: pointInTime, in: refreshed)
                        : RestoreChainBuilder.chain(pointInTime: nil, in: refreshed)
                    if case .success(let value) = rebuilt { chain = value }
                }
                var adjusted = options
                adjusted.tailLogBackup = false
                adjusted.replaceExisting = true
                if let chain {
                    plannerToRun = RestorePlanner(chain: chain, files: fileList, options: adjusted, capabilities: capabilities,
                                                  destinationExists: true, destinationIsRestoring: true)
                }
            } catch {
                errorText = "The tail-log backup failed: \(ScriptRunner.describeError(error))"
                return
            }
        }
        guard let plannerToRun else { return }
        let result = await RestoreRunner(session: session, planner: plannerToRun).run { [weak self] event in
            Task { @MainActor in
                self?.progressText = event.message
                self?.fraction = event.fraction ?? self?.fraction ?? 0
            }
        }
        outcome = result
        window.recordRestoreFailure(database: plannerToRun.destination, outcome: result)
    }

    var summary: [(String, String)] {
        var lines: [(String, String)] = [("Server", serverName)]
        if let chain {
            lines.append(("Source database", chain.full.database))
            for set in chain.steps {
                lines.append((set.typeTitle, "\(BackupFormat.date(set.finished))  \(set.primaryFiles.joined(separator: ", "))"))
            }
            lines.append(("Restores to", chain.stopAt.map { "Point in time \(ServerTime.display($0))" }
                ?? "The end of the last backup (\(BackupFormat.date(chain.latestTime)))"))
        }
        lines.append(("Destination", (createNew ? "New database " : "Overwrite ") + options.destinationDatabase))
        if !createNew {
            lines.append(("Connections", options.killConnections ? "Killed before the restore" : "Left alone (the restore fails if any exist)"))
            if options.tailLogBackup { lines.append(("Tail of the log", "Backed up to \(options.tailLogPath)")) }
        }
        lines.append(("Files", options.fileLocation.title))
        lines.append(("Recovery", options.recoveryState.title))
        lines.append(("Orphaned users", options.orphanCheck ? (options.fixOrphanedUsers ? "Checked and fixed" : "Checked") : "Not checked"))
        lines.append(("Integrity check", options.checkDB ? "DBCC CHECKDB afterwards" : "None"))
        lines.append(("Afterwards", options.drop.title))
        return lines
    }
}
