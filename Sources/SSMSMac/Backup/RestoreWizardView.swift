import SwiftUI
import AppKit
import SQLServerKit

/// The Restore wizard: choose backups (from history or files), where to restore them, how, and run.
struct RestoreWizardView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    @StateObject var model: RestoreWizardModel

    var body: some View {
        VStack(spacing: 0) {
            WizardStepHeader(titles: RestoreWizardModel.Step.allCases.map(\.rawValue), current: model.stepIndex,
                             subtitle: "Restore · \(model.serverName)") { index in
                model.step = RestoreWizardModel.Step.allCases[index]
            }
            Divider()
            Group {
                if model.isRunning || model.outcome != nil {
                    RestoreRunView(model: model)
                } else {
                    switch model.step {
                    case .backups: RestoreBackupsPage(model: model)
                    case .destination: RestoreDestinationPage(model: model)
                    case .options: RestoreOptionsPage(model: model)
                    case .summary: RestoreSummaryPage(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 920, height: 660)
        .task { await model.load() }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if !model.isRunning && model.outcome == nil {
                ValidationList(errors: model.errors(for: model.step))
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                } else if model.outcome != nil {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if model.stepIndex > 0 { Button("Back") { model.back() } }
                    if model.step == .summary {
                        Button("Restore") { model.run(window: window) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.errors(for: .summary).isEmpty)
                    } else {
                        Button("Next") { model.next() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.errors(for: model.step).isEmpty)
                    }
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Backups

struct RestoreBackupsPage: View {
    @ObservedObject var model: RestoreWizardModel
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $model.source) {
                    ForEach(RestoreWizardModel.Source.allCases) { source in Text(source.rawValue).tag(source) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 460)
                .onChange(of: model.source) { _, _ in Task { await model.loadSets() } }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            if model.source == .history {
                Picker("Database", selection: $model.sourceDatabase) {
                    ForEach(model.historyDatabases, id: \.self) { name in Text(name).tag(name) }
                }
                .frame(width: 360)
                .onChange(of: model.sourceDatabase) { _, _ in Task { await model.loadSets() } }
            } else {
                filesSection
            }
            setsTable
            pointInTime
            chainSummary
        }
        .padding(16)
        .sheet(isPresented: $browsing) {
            ServerFileBrowserView(session: model.session, capabilities: model.capabilities, purpose: .files,
                                  start: model.capabilities.backupFolder) { paths in
                model.addFiles(paths)
            }
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Add Files…") { browsing = true }
                Text("Pick every stripe of a split backup. Files are read by SQL Server, on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.files, id: \.self) { file in
                HStack {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                    Text(file).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.removeFile(file) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            ForEach(model.fileProblems, id: \.self) { problem in
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var setsTable: some View {
        Table(model.sortedSets, selection: Binding(get: { model.selectedSetID },
                                                   set: { model.selectedSetID = $0; model.rebuildChain() })) {
            TableColumn("") { set in
                Image(systemName: model.isInChain(set) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.isInChain(set) ? Color.green : Color.secondary.opacity(0.4))
            }
            .width(22)
            TableColumn("Finished") { set in Text(BackupFormat.date(set.finished)) }
                .width(min: 140, ideal: 150)
            TableColumn("Type") { set in Text(set.typeTitle) }
                .width(min: 90, ideal: 110)
            TableColumn("Database") { set in Text(set.database) }
                .width(min: 90, ideal: 120)
            TableColumn("Size") { set in Text(BackupFormat.size(set.compressedSize)).foregroundStyle(.secondary) }
                .width(70)
            TableColumn("") { set in
                HStack(spacing: 3) {
                    if set.isEncrypted { Image(systemName: "lock.fill").help("Encrypted (\(set.keyAlgorithm))") }
                    if set.hasChecksums { Image(systemName: "checkmark.seal").help("Has checksums") }
                    if set.isDamaged { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Damaged") }
                    if set.deviceType == 7 { Image(systemName: "puzzlepiece").help("Made by another backup tool") }
                }
                .foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Files") { set in
                Text(set.primaryFiles.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(minHeight: 200)
    }

    @ViewBuilder
    private var pointInTime: some View {
        if let range = model.pointInTimeRange {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Restore to a point in time", isOn: Binding(get: { model.usePointInTime },
                                                                   set: { model.usePointInTime = $0; model.rebuildChain() }))
                    .toggleStyle(.checkbox)
                if model.usePointInTime {
                    HStack {
                        Text(ServerTime.displayShort(range.lowerBound)).font(.caption)
                        Slider(value: Binding(get: { model.pointInTime.timeIntervalSince(range.lowerBound) },
                                              set: { model.pointInTime = range.lowerBound.addingTimeInterval($0.rounded()) }),
                               in: 0...max(1, range.upperBound.timeIntervalSince(range.lowerBound)),
                               onEditingChanged: { editing in if !editing { model.rebuildChain() } })
                        Text(ServerTime.displayShort(range.upperBound)).font(.caption)
                        DatePicker("", selection: Binding(get: { model.pointInTime },
                                                          set: { model.pointInTime = $0; model.rebuildChain() }),
                                   in: range, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .environment(\.timeZone, ServerTime.calendar.timeZone)
                    }
                    Text("Server time. Committed transactions up to \(ServerTime.display(model.pointInTime)) are restored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var chainSummary: some View {
        if let chain = model.chain {
            HStack(spacing: 6) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text(chain.steps.map(\.typeTitle).joined(separator: " → "))
                if let notes = chain.notes.first { Text("· \(notes)").foregroundStyle(.secondary) }
            }
            .font(.callout)
        } else if let error = model.chainError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
    }
}

// MARK: - Destination

struct RestoreDestinationPage: View {
    @ObservedObject var model: RestoreWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("", selection: $model.createNew) {
                    Text("Create a new database").tag(true)
                    Text("Overwrite an existing database").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if model.createNew {
                    TextField("New database name", text: $model.options.destinationDatabase)
                        .textFieldStyle(.roundedBorder).frame(width: 360)
                } else {
                    existing
                }
                Divider()
                locations
            }
            .padding(16)
        }
    }

    private var existing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Database", selection: $model.options.destinationDatabase) {
                Text("Choose…").tag("")
                ForEach(model.databases.filter { !$0.isSystem }) { status in Text(status.name).tag(status.name) }
            }
            .frame(width: 360)
            Toggle("Kill any existing connections to the database", isOn: $model.options.killConnections)
            if model.canBackUpTail {
                Toggle("Back up the tail of the transaction log first", isOn: Binding(get: { model.options.tailLogBackup },
                                                                                    set: { on in
                                                                                        model.options.tailLogBackup = on
                                                                                        if on { model.suggestTailPath() }
                                                                                    }))
                if model.options.tailLogBackup {
                    TextField("Tail-log backup file on the server", text: $model.options.tailLogPath)
                        .textFieldStyle(.roundedBorder)
                    Text("The database is left restoring after the tail backup. Restoring it to its latest point includes "
                         + "the tail, so nothing committed since the last log backup is lost.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.options.tailLogBackup {
                Toggle("Overwrite the database, discarding anything not in the backups (REPLACE)",
                       isOn: $model.options.replaceExisting)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File locations").font(.subheadline.weight(.semibold))
            Picker("", selection: $model.options.fileLocation) {
                ForEach(RestoreOptions.FileLocation.allCases, id: \.self) { location in Text(location.title).tag(location) }
            }
            .labelsHidden()
            .frame(width: 400)
            if model.options.fileLocation == .folders {
                ServerFolderField(placeholder: "Data files folder (\(model.capabilities.defaultDataFolder))",
                                  path: $model.options.dataFolder, session: model.session, capabilities: model.capabilities)
                ServerFolderField(placeholder: "Log files folder (\(model.capabilities.defaultLogFolder))",
                                  path: $model.options.logFolder, session: model.session, capabilities: model.capabilities)
            }
            if let planner = model.planner {
                let moves = planner.relocations()
                Table(model.fileList) {
                    TableColumn("Logical name") { file in Text(file.logicalName) }
                        .width(min: 120, ideal: 160)
                    TableColumn("Type") { file in Text(file.type).foregroundStyle(.secondary) }
                        .width(80)
                    TableColumn("Size") { file in Text(String(format: "%.0f MB", file.sizeMB)).foregroundStyle(.secondary) }
                        .width(70)
                    TableColumn("Restore to") { file in
                        if model.options.fileLocation == .custom {
                            TextField("", text: Binding(
                                get: { model.options.fileMoves[file.logicalName]
                                       ?? moves.first { $0.logical == file.logicalName }?.physical ?? "" },
                                set: { model.options.fileMoves[file.logicalName] = $0 }))
                                .font(.caption.monospaced())
                        } else {
                            Text(moves.first { $0.logical == file.logicalName }?.physical ?? "")
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                .frame(minHeight: 140)
            }
        }
    }
}

// MARK: - Options

struct RestoreOptionsPage: View {
    @ObservedObject var model: RestoreWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recovery completion state").font(.subheadline.weight(.semibold))
                    Picker("", selection: $model.options.recoveryState) {
                        ForEach(RestoreOptions.RecoveryState.allCases, id: \.self) { state in Text(state.title).tag(state) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if model.options.recoveryState == .readOnly {
                        TextField("Undo file (default: UNDO_<database>.dat in the backup folder)", text: $model.options.undoFile)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Checks").font(.subheadline.weight(.semibold))
                    Toggle("Check for orphaned users (users whose login is missing on this server)", isOn: $model.options.orphanCheck)
                    if model.options.orphanCheck {
                        Toggle("Map orphaned users to the login of the same name, where one exists",
                               isOn: $model.options.fixOrphanedUsers).padding(.leading, 20)
                    }
                    Toggle("Run DBCC CHECKDB after the restore", isOn: $model.options.checkDB)
                    if model.options.checkDB { CheckDBOptionsEditor(options: $model.options.checkDBOptions).padding(.leading, 20) }
                    Toggle("Verify backup checksums while restoring", isOn: $model.options.checksum)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Afterwards").font(.subheadline.weight(.semibold))
                    Picker("", selection: $model.options.drop) {
                        ForEach(RestoreOptions.DropPolicy.allCases, id: \.self) { policy in Text(policy.title).tag(policy) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Advanced").font(.subheadline.weight(.semibold))
                    Toggle("Keep change data capture settings (KEEP_CDC)", isOn: $model.options.keepCDC)
                    Toggle("Keep replication settings (KEEP_REPLICATION)", isOn: $model.options.keepReplication)
                    Toggle("Restrict access to db_owner, dbcreator and sysadmin (RESTRICTED_USER)", isOn: $model.options.restrictedUser)
                    Picker("Service Broker", selection: $model.options.broker) {
                        Text("Keep as in the backup").tag(RestoreOptions.BrokerOption.keep)
                        Text("Enable").tag(RestoreOptions.BrokerOption.enable)
                        Text("New broker identifier").tag(RestoreOptions.BrokerOption.new)
                        Text("End conversations with an error").tag(RestoreOptions.BrokerOption.errorConversations)
                    }
                    .frame(width: 380)
                }
            }
            .toggleStyle(.checkbox)
            .padding(16)
        }
    }
}

struct CheckDBOptionsEditor: View {
    @Binding var options: CheckDBOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Physical checks only, faster (PHYSICAL_ONLY)", isOn: $options.physicalOnly)
            Toggle("Take locks instead of a snapshot, faster (TABLOCK)", isOn: $options.tablock)
            if !options.physicalOnly {
                Toggle("Column value checks (DATA_PURITY)", isOn: $options.dataPurity)
                Toggle("Extended logical checks", isOn: $options.extendedLogicalChecks)
            }
            Toggle("Report all errors (ALL_ERRORMSGS)", isOn: $options.allErrorMessages)
            Toggle("Hide information messages (NO_INFOMSGS)", isOn: $options.noInfoMessages)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Summary and run

struct RestoreSummaryPage: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model: RestoreWizardModel
    @State private var showScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    ForEach(Array(model.summary.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.0).foregroundStyle(.secondary)
                            Text(line.1).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: showScript ? 200 : .infinity)
            HStack {
                Spacer()
                Toggle("Show Script", isOn: $showScript).toggleStyle(.switch)
                Button("Copy Script") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.planner?.script() ?? "", forType: .string)
                }
            }
            if showScript {
                ScriptTextView(text: model.planner?.script() ?? "", settings: settings)
                    .border(Color.secondary.opacity(0.3))
            }
        }
        .padding(16)
    }
}

struct RestoreRunView: View {
    @ObservedObject var model: RestoreWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let outcome = model.outcome {
                    Label(outcome.succeeded ? String(format: "The restore succeeded in %.1f s.", outcome.duration)
                          : "The restore failed\(outcome.failedStep.map { " at: \($0)" } ?? "").",
                          systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                        .font(.headline)
                    if let error = outcome.error, !outcome.succeeded {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                    if !outcome.orphanedUsers.isEmpty {
                        Text("Orphaned users").font(.subheadline.weight(.semibold))
                        ForEach(outcome.orphanedUsers) { user in
                            Text("• \(user.name)" + (user.fixed ? " — mapped to its login"
                                 : (user.loginExists ? " — a login of that name exists" : " — no login of that name")))
                                .foregroundStyle(user.fixed ? Color.secondary : Color.orange)
                        }
                    }
                    ForEach(outcome.checkDBErrors, id: \.self) { error in
                        Text("DBCC CHECKDB: \(error)").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if outcome.dropped { Text("The restored database was dropped.").foregroundStyle(.secondary) }
                    DisclosureGroup("Messages") {
                        Text(outcome.messages.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(model.progressText)
                    ProgressView(value: model.fraction).frame(width: 400)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
