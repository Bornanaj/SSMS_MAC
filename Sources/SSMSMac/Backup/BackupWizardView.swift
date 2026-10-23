import SwiftUI
import AppKit
import SQLServerKit

/// The Back Up, Schedule Backup Jobs and Edit Backup Job wizard.
struct BackupWizardView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    @StateObject var model: BackupWizardModel

    var body: some View {
        VStack(spacing: 0) {
            WizardStepHeader(titles: model.steps.map(\.rawValue), current: model.stepIndex,
                             subtitle: "\(model.mode.title) · \(model.serverName)") { index in
                model.step = model.steps[index]
            }
            Divider()
            Group {
                if model.isRunning || model.result != nil || !model.createdJobs.isEmpty {
                    BackupRunView(model: model)
                } else {
                    page
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 900, height: 660)
        .task { await model.loadLookups() }
    }

    @ViewBuilder
    private var page: some View {
        switch model.step {
        case .databases: BackupDatabasesPage(model: model, preferences: window.preferences)
        case .files: BackupFilesPage(model: model)
        case .processing: BackupProcessingPage(model: model)
        case .verification: BackupVerificationPage(model: model)
        case .schedules: BackupSchedulesPage(model: model)
        case .summary: BackupSummaryPage(model: model, preferences: window.preferences)
        }
    }

    private var finished: Bool { !model.isRunning && (model.result != nil || !model.createdJobs.isEmpty) }

    private var footer: some View {
        VStack(spacing: 6) {
            if !model.isRunning && !finished {
                ValidationList(errors: model.errors(for: model.step))
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.cancel() }
                } else if finished {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if model.stepIndex > 0 { Button("Back") { model.back() } }
                    if model.step == .summary {
                        Button(runTitle) { model.run(window: window) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.errors(for: .summary).isEmpty)
                    } else {
                        Button("Next") { model.next() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canGoNext)
                    }
                }
            }
        }
        .padding(12)
    }

    private var runTitle: String {
        switch model.mode {
        case .backUpNow: return "Back Up"
        case .schedule: return model.effectiveTypes.count > 1 ? "Create Jobs" : "Create Job"
        case .edit: return "Save Changes"
        }
    }
}

// MARK: - Type and databases

struct BackupDatabasesPage: View {
    @ObservedObject var model: BackupWizardModel
    @ObservedObject var preferences: BackupPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 30) {
                typeSection
                scopeSection
                Spacer()
                if !preferences.templates.isEmpty && !model.isEditing {
                    Menu("Use Template") {
                        ForEach(preferences.templates) { template in
                            Button(template.name) { model.apply(template) }
                        }
                    }
                    .fixedSize()
                }
            }
            databaseList
        }
        .padding(16)
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Backup type").font(.subheadline.weight(.semibold))
            if model.mode == .schedule {
                ForEach(BackupType.allCases) { type in
                    Toggle(type.title, isOn: Binding(get: { model.types.contains(type) },
                                                     set: { on in
                                                         if on { model.types.insert(type) } else { model.types.remove(type) }
                                                     }))
                }
            } else {
                Picker("", selection: $model.options.type) {
                    ForEach(BackupType.allCases) { type in Text(type.title).tag(type) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(model.isEditing)
            }
            if model.effectiveTypes.contains(.full) || model.effectiveTypes.contains(.log) {
                Toggle("Copy-only (does not affect the backup chain)", isOn: $model.options.copyOnly)
            }
            if model.effectiveTypes.contains(.log) {
                Toggle("Remove inactive entries from the transaction log", isOn: $model.options.truncateLog)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Databases").font(.subheadline.weight(.semibold))
            Picker("", selection: $model.options.databases.scope) {
                ForEach(DatabaseSelection.Scope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(model.options.databases.scope == .selected ? "Tick the databases to back up."
                 : "Databases are found each time the backup runs, so new ones are included. Tick any to leave out.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var databaseList: some View {
        List(model.databases) { status in
            BackupDatabaseRow(model: model, status: status)
        }
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }
}

struct BackupDatabaseRow: View {
    @ObservedObject var model: BackupWizardModel
    let status: DatabaseBackupStatus

    private var selectedScope: Bool { model.options.databases.scope == .selected }

    var body: some View {
        let reason = model.reason(status)
        HStack(spacing: 8) {
            if selectedScope {
                Toggle("", isOn: Binding(get: { model.isSelected(status.name) },
                                         set: { model.setSelected(status.name, $0) }))
                    .labelsHidden()
                    .disabled(reason != nil && !model.isSelected(status.name))
            } else {
                Toggle("", isOn: Binding(get: { !model.isExcluded(status.name) && reason == nil },
                                         set: { model.setExcluded(status.name, !$0) }))
                    .labelsHidden()
                    .disabled(reason != nil)
            }
            DatabaseStateIcon(status: status)
            Text(status.name).frame(width: 200, alignment: .leading)
            Text(status.recoveryModel).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(String(format: "%.0f MB", status.sizeMB)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(reason ?? "Last full: \(BackupFormat.date(status.lastFull).isEmpty ? "never" : BackupFormat.date(status.lastFull))")
                .font(.caption)
                .foregroundStyle(reason == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
            Spacer()
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - Files

struct BackupFilesPage: View {
    @ObservedObject var model: BackupWizardModel
    @State private var addingCredential = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Back up to", selection: $model.options.destination) {
                    ForEach(BackupDestinationKind.allCases, id: \.self) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                .disabled(!model.capabilities.supportsAzureURL)
                if model.options.destination == .disk {
                    diskSection
                } else {
                    cloudSection
                }
                nameSection
                if model.options.destination == .disk { layoutSection }
                Toggle("Overwrite existing backup files of the same name", isOn: $model.options.overwrite)
                    .toggleStyle(.checkbox)
                if model.options.destination == .disk {
                    RetentionEditor(title: "Delete existing backup files in this folder", retention: $model.options.retention)
                    if model.options.layout == .mirrored {
                        RetentionEditor(title: "Delete existing backup files in the mirror folders",
                                        retention: $model.options.mirrorRetention, allowsBefore: false)
                    }
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $addingCredential) {
            CloudCredentialSheet(session: model.session, url: model.options.urlBase) {
                Task { await model.loadLookups() }
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folder on \(model.serverName)").font(.subheadline.weight(.semibold))
            ServerFolderField(placeholder: model.capabilities.backupFolder + " (the server's default backup folder)",
                              path: $model.options.folder, session: model.session, capabilities: model.capabilities,
                              showsTags: true)
            Text("Paths are on the server. A network share works if SQL Server's service account can write to it. "
                 + "Tags such as <DATABASE> make a folder per database.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Container or bucket URL").font(.subheadline.weight(.semibold))
            TextField("https://account.blob.core.windows.net/backups  or  s3://s3.us-east-1.amazonaws.com/bucket",
                      text: $model.options.urlBase)
                .textFieldStyle(.roundedBorder)
            if model.options.urlBase.lowercased().hasPrefix("s3://") {
                TextField("Region (optional, e.g. us-west-2)", text: $model.options.s3Region)
                    .textFieldStyle(.roundedBorder).frame(width: 260)
            }
            HStack {
                let base = model.options.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
                let hasCredential = !base.isEmpty && model.credentials.contains { base.hasPrefix($0.lowercased()) }
                Image(systemName: hasCredential ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(hasCredential ? Color.green : Color.orange)
                Text(hasCredential ? "SQL Server has a credential for this location."
                     : "SQL Server needs a credential named after this URL to write there.")
                Button("Create Credential…") { addingCredential = true }
            }
            .font(.callout)
            Text("Backups go straight to object storage and restore straight from it. Retention is set with the "
                 + "container's or bucket's lifecycle rules.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("File name").font(.subheadline.weight(.semibold))
            HStack {
                TextField(BackupOptions.defaultFileNameFormat, text: $model.options.fileNameFormat)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                FileNameTagMenu(text: $model.options.fileNameFormat)
                Button("Default") { model.options.fileNameFormat = BackupOptions.defaultFileNameFormat }
            }
            Text(model.filePreview())
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $model.options.layout) {
                ForEach(BackupFileLayout.allCases, id: \.self) { layout in Text(layout.title).tag(layout) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if model.options.layout == .split {
                Stepper("Split into \(model.options.fileCount) files (all are needed to restore)",
                        value: $model.options.fileCount, in: 2...64)
            }
            if model.options.layout == .mirrored {
                if !model.capabilities.canMirror {
                    Label("Mirrored backups need the Enterprise or Developer edition.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption)
                }
                ForEach(0..<3, id: \.self) { index in
                    ServerFolderField(placeholder: "Mirror folder \(index + 1)\(index == 0 ? "" : " (optional)")",
                                      path: mirrorBinding(index), session: model.session,
                                      capabilities: model.capabilities, showsTags: true)
                }
            }
        }
    }

    private func mirrorBinding(_ index: Int) -> Binding<String> {
        Binding(get: { index < model.options.mirrorFolders.count ? model.options.mirrorFolders[index] : "" },
                set: { value in
                    var folders = model.options.mirrorFolders
                    while folders.count <= index { folders.append("") }
                    folders[index] = value
                    while let last = folders.last, last.isEmpty { folders.removeLast() }
                    model.options.mirrorFolders = folders
                })
    }
}

/// Creates the credential backup to URL needs.
struct CloudCredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    @State var url: String
    let onDone: () -> Void
    @State private var secret = ""
    @State private var accessKey = ""
    @State private var error: String?

    private var isS3: Bool { url.lowercased().hasPrefix("s3://") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Credential").font(.headline)
            TextField(isS3 ? "s3://host/bucket" : "https://account.blob.core.windows.net/container", text: $url)
                .textFieldStyle(.roundedBorder)
            if isS3 {
                TextField("Access key ID", text: $accessKey).textFieldStyle(.roundedBorder)
                SecureField("Secret access key", text: $secret).textFieldStyle(.roundedBorder)
            } else {
                SecureField("Shared access signature token (without the leading ?)", text: $secret)
                    .textFieldStyle(.roundedBorder)
                Text("Create a SAS token for the container with read, write, delete and list permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(url.isEmpty || secret.isEmpty || (isS3 && accessKey.isEmpty))
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    private func create() {
        let script = isS3 ? CloudCredential.s3Script(bucketURL: url, accessKey: accessKey, secretKey: secret)
            : CloudCredential.azureScript(containerURL: url, sasToken: secret)
        Task {
            do {
                try await CloudCredential.create(script, session: session)
                onDone()
                dismiss()
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
        }
    }
}

// MARK: - Compression and encryption

struct BackupProcessingPage: View {
    @ObservedObject var model: BackupWizardModel
    @State private var analyzing = false
    @State private var creatingCertificate = false

    private let transferSizes: [Int] = [0, 65_536, 131_072, 262_144, 524_288, 1_048_576, 2_097_152, 4_194_304]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                compression
                Divider()
                encryption
                Divider()
                optimization
                Divider()
                resilience
            }
            .padding(16)
        }
        .sheet(isPresented: $analyzing) {
            CompressionAnalyzerSheet(session: model.session, capabilities: model.capabilities,
                                     databases: model.databases.map(\.name),
                                     database: model.resolvedDatabases.first ?? "")
        }
        .sheet(isPresented: $creatingCertificate) {
            NewCertificateSheet(session: model.session) { name in
                Task {
                    await model.loadLookups()
                    model.options.encryption.encryptor = name
                }
            }
        }
    }

    private var compression: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Compression").font(.subheadline.weight(.semibold))
            HStack {
                Text("None")
                Slider(value: Binding(get: { Double(model.options.compressionLevel) },
                                      set: { model.options.compressionLevel = Int($0.rounded()) }),
                       in: 0...4, step: 1)
                    .frame(width: 260)
                    .disabled(!model.capabilities.canCompress)
                Text("Smallest")
                Text("Level \(model.options.compressionLevel): \(model.capabilities.compressionDescription(level: model.options.compressionLevel))")
                    .foregroundStyle(.secondary)
            }
            if let note = model.capabilities.compressionNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Compression Analyzer…") { analyzing = true }
                .disabled(!model.capabilities.canCompress)
        }
    }

    private var encryption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Encrypt backup", isOn: $model.options.encryption.isEnabled)
                .toggleStyle(.checkbox)
                .font(.subheadline.weight(.semibold))
                .disabled(!model.capabilities.canEncrypt)
            if !model.capabilities.canEncrypt {
                Text("\(model.capabilities.editionTitle) cannot create encrypted backups.").font(.caption).foregroundStyle(.secondary)
            }
            if model.options.encryption.isEnabled {
                HStack {
                    Picker("Algorithm", selection: $model.options.encryption.algorithm) {
                        ForEach(BackupEncryptionAlgorithm.allCases, id: \.self) { algorithm in
                            Text(algorithm.title).tag(algorithm)
                        }
                    }
                    .frame(width: 240)
                    Picker("Certificate", selection: $model.options.encryption.encryptor) {
                        Text("Choose…").tag("")
                        ForEach(model.certificates.filter(\.hasPrivateKey)) { certificate in
                            Text(certificate.name).tag(certificate.name)
                        }
                    }
                    .frame(width: 280)
                    Button("New Certificate…") { creatingCertificate = true }
                }
                Text("Native backup encryption uses a certificate in master instead of a password. Restoring needs the "
                     + "same certificate on the server, so export it (Server Options › Encryption) and keep it safe.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let chosen = model.certificates.first(where: { $0.name == model.options.encryption.encryptor }),
                   chosen.privateKeyLastBackedUp == nil {
                    Label("This certificate's private key has never been backed up.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.caption)
                }
            }
        }
    }

    private var optimization: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Optimization").font(.subheadline.weight(.semibold))
            HStack(spacing: 20) {
                Picker("Maximum transfer size", selection: $model.options.maxTransferSize) {
                    ForEach(transferSizes, id: \.self) { size in
                        Text(size == 0 ? "Server default" : ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .memory))
                            .tag(size)
                    }
                }
                .frame(width: 300)
                Stepper("Buffers: \(model.options.bufferCount == 0 ? "default" : String(model.options.bufferCount))",
                        value: $model.options.bufferCount, in: 0...1024)
            }
            Text("A split backup writes the stripes in parallel; more buffers and a larger transfer size speed up "
                 + "large backups at the cost of memory.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var resilience: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Network resilience").font(.subheadline.weight(.semibold))
            HStack(spacing: 20) {
                Stepper("Retry up to \(model.options.retryCount) times", value: $model.options.retryCount, in: 0...50)
                Stepper("every \(model.options.retryIntervalSeconds) seconds", value: $model.options.retryIntervalSeconds,
                        in: 1...600, step: 5)
            }
            Text("When writing the backup fails with a file or network error, the backup is retried. Native backups "
                 + "cannot resume, so each retry starts the backup again.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Creates a certificate for backup encryption (and master's key when it is missing).
struct NewCertificateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    let onCreated: (String) -> Void
    @State private var name = "BackupEncryption"
    @State private var subject = "Backup encryption"
    @State private var years = 10
    @State private var masterKeyPassword = ""
    @State private var needsMasterKey = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Encryption Certificate").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
            Stepper("Expires in \(years) years", value: $years, in: 1...50)
            if needsMasterKey {
                SecureField("Password for master's database master key", text: $masterKeyPassword)
                    .textFieldStyle(.roundedBorder)
                Text("master has no database master key yet; it protects the certificate's private key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty || (needsMasterKey && masterKeyPassword.isEmpty))
            }
        }
        .padding(16)
        .frame(width: 460)
        .task { needsMasterKey = !((try? await BackupEncryptionKeys(session: session).hasMasterKey()) ?? true) }
    }

    private func create() {
        let expiry = Date().addingTimeInterval(Double(years) * 365 * 86_400)
        Task {
            do {
                try await BackupEncryptionKeys(session: session).create(name: name, subject: subject, expiry: expiry,
                                                                        masterKeyPassword: needsMasterKey ? masterKeyPassword : nil)
                onCreated(name)
                dismiss()
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
        }
    }
}

// MARK: - Verification and email

struct BackupVerificationPage: View {
    @ObservedObject var model: BackupWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Checks").font(.subheadline.weight(.semibold))
                    Toggle("Check page checksums and write a backup checksum (CHECKSUM)", isOn: $model.options.checksum)
                    if model.options.checksum {
                        Toggle("Continue past checksum errors (CONTINUE_AFTER_ERROR)", isOn: $model.options.continueAfterError)
                            .padding(.leading, 20)
                    }
                    Toggle("Verify the backup when it finishes (RESTORE VERIFYONLY)", isOn: $model.options.verify)
                    Text("Neither check validates the data's logical structure: schedule a restore with DBCC CHECKDB for that.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.capabilities.isHadrEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Availability groups").font(.subheadline.weight(.semibold))
                        Toggle("Back up only on the preferred backup replica", isOn: $model.options.checkPreferredReplica)
                        Toggle("Make full backups on a secondary replica copy-only", isOn: $model.options.secondaryReplicaCopyOnly)
                    }
                }
                email
                VStack(alignment: .leading, spacing: 6) {
                    Text("Backup set").font(.subheadline.weight(.semibold))
                    HStack {
                        TextField("Name (optional, tags allowed)", text: $model.options.backupName).textFieldStyle(.roundedBorder)
                        FileNameTagMenu(text: $model.options.backupName, includeAuto: false)
                    }
                    HStack {
                        TextField("Description (optional, tags allowed)", text: $model.options.backupDescription)
                            .textFieldStyle(.roundedBorder)
                        FileNameTagMenu(text: $model.options.backupDescription, includeAuto: false)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .padding(16)
        }
    }

    private var email: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email notification").font(.subheadline.weight(.semibold))
            Picker("Send email", selection: $model.options.notification.level) {
                ForEach(NotificationLevel.allCases, id: \.self) { level in Text(level.title).tag(level) }
            }
            .frame(width: 320)
            if model.options.notification.level != .never {
                TextField("Recipients, separated by ;", text: $model.options.notification.recipients)
                    .textFieldStyle(.roundedBorder)
                if !model.mailProfiles.isEmpty {
                    Picker("Database Mail profile", selection: $model.options.notification.mailProfile) {
                        Text("Default profile").tag("")
                        ForEach(model.mailProfiles, id: \.self) { profile in Text(profile).tag(profile) }
                    }
                    .frame(width: 360)
                }
                if !model.capabilities.databaseMailEnabled {
                    Label("Database Mail is not set up on this server. Set it up in Server Options › Email.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                Text("Mail goes through SQL Server's Database Mail; warnings include failed verification and files that "
                     + "could not be deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Schedules

struct BackupSchedulesPage: View {
    @ObservedObject var model: BackupWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Each backup type becomes a SQL Server Agent job with its own schedules.")
                    .foregroundStyle(.secondary)
                ForEach(model.effectiveTypes) { type in
                    ScheduleListEditor(title: "\(type.title) backups",
                                       schedules: Binding(get: { model.schedules[type] ?? [] },
                                                          set: { model.schedules[type] = $0 }),
                                       suggestion: BackupSchedule.suggested(for: type, today: model.capabilities.serverTime ?? Date()))
                    Divider()
                }
                if model.mode == .schedule && model.types.contains(.full) {
                    Toggle("Remind me to schedule restore jobs that verify these backups", isOn: $model.createReminder)
                        .toggleStyle(.checkbox)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Summary

struct BackupSummaryPage: View {
    @EnvironmentObject var settings: AppSettings
    @ObservedObject var model: BackupWizardModel
    @ObservedObject var preferences: BackupPreferences
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
            .frame(maxHeight: showScript ? 180 : .infinity)
            HStack {
                TextField("Template name", text: $model.templateName).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Save as Template") { model.saveTemplate(preferences) }
                    .disabled(model.templateName.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Toggle("Show Script", isOn: $showScript).toggleStyle(.switch)
                Button("Copy Script") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.script(), forType: .string)
                }
            }
            if showScript {
                ScriptTextView(text: model.script(), settings: settings)
                    .border(Color.secondary.opacity(0.3))
            }
        }
        .padding(16)
    }
}

// MARK: - Run

struct BackupRunView: View {
    @ObservedObject var model: BackupWizardModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.createdJobs.isEmpty {
                    Label(model.isEditing ? "The job was updated." : "Created \(model.createdJobs.count) SQL Server Agent job(s):",
                          systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    ForEach(model.createdJobs, id: \.self) { name in Text("• \(name)") }
                } else if let result = model.result {
                    Label(result.summary, systemImage: result.hasErrors ? "xmark.circle.fill"
                          : (result.hasWarnings ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                        .foregroundStyle(result.hasErrors ? Color.red : (result.hasWarnings ? Color.orange : Color.green))
                        .font(.headline)
                    ForEach(result.results) { item in
                        BackupResultRow(item: item)
                    }
                } else {
                    ForEach(model.resolvedDatabases, id: \.self) { name in
                        HStack {
                            Text(name).frame(width: 200, alignment: .leading)
                            ProgressView(value: model.progress[name] ?? 0).frame(width: 260)
                            Text(model.phases[name] ?? "Waiting").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}

struct BackupResultRow: View {
    let item: DatabaseBackupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: item.succeeded ? (item.warnings.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                      : (item.skipped ? "minus.circle" : "xmark.circle.fill"))
                    .foregroundStyle(item.succeeded ? (item.warnings.isEmpty ? Color.green : Color.orange)
                                     : (item.skipped ? Color.secondary : Color.red))
                Text(item.database).fontWeight(.semibold)
                if item.succeeded && !item.skipped {
                    Text(BackupFormat.duration(item.duration)).foregroundStyle(.secondary)
                    if item.compressedSize > 0 { Text(BackupFormat.size(item.compressedSize)).foregroundStyle(.secondary) }
                    if let ratio = item.compressionRatio { Text(String(format: "%.0f%% smaller", ratio * 100)).foregroundStyle(.secondary) }
                    if item.verified == true { Text("verified").foregroundStyle(.green) }
                }
            }
            ForEach(item.files + item.mirrorFiles, id: \.self) { file in
                Text(file).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(item.deletedFiles, id: \.self) { file in
                Text("Deleted \(file)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(item.warnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ForEach(item.errors, id: \.self) { error in
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }
}
