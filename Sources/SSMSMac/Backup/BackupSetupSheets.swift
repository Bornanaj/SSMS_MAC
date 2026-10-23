import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SQLServerKit

// MARK: - Log shipping

/// The Log Shipping wizard, on SQL Server's own log shipping: a backup job on the primary,
/// copy and restore jobs on the standby, optionally initialized from a fresh full backup.
struct LogShippingSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities

    @State private var options = LogShippingOptions()
    @State private var standbyProfile: ConnectionProfile?
    @State private var standbySession: SQLServerSession?
    @State private var standbyCapabilities: BackupServerCapabilities?
    @State private var page = 0
    @State private var log: [String] = []
    @State private var isRunning = false
    @State private var done = false
    @State private var error: String?
    @State private var showScript = false

    private let pages = ["Databases", "Backups", "Copy", "Restore", "Summary"]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepHeader(titles: pages, current: page, subtitle: "Log Shipping · \(window.serverName)") { page = $0 }
            Divider()
            Group {
                if isRunning || done {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(log.enumerated()), id: \.offset) { _, line in Text(line) }
                            if done { Label("Log shipping is set up.", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }
                } else {
                    ScrollView { pageContent.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .task {
            standbyProfile = window.profile
            standbySession = session
            standbyCapabilities = capabilities
            options.primaryDatabase = window.selectedDatabase ?? ""
            options.backupFolder = capabilities.join(capabilities.backupFolder, "LogShipping")
            options.backupShare = options.backupFolder
            options.copyFolder = capabilities.join(capabilities.backupFolder, "LogShippingCopy")
            if !options.primaryDatabase.isEmpty { options.secondaryDatabase = options.primaryDatabase + "_Standby" }
        }
    }

    private var sameServer: Bool { standbyCapabilities?.serverName == capabilities.serverName }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            VStack(alignment: .leading, spacing: 10) {
                Picker("Primary database on \(window.serverName)", selection: $options.primaryDatabase) {
                    Text("Choose…").tag("")
                    ForEach(window.databases.filter { !$0.isSystem && $0.recoveryModel.uppercased() != "SIMPLE"
                        && $0.operationalState == .operational }) { status in
                        Text(status.name).tag(status.name)
                    }
                }
                .frame(width: 460)
                Text("Databases in the simple recovery model cannot be log shipped.").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(window.serverChoices(app: app)) { profile in
                        Button(profile.displayName) { Task { await chooseStandby(profile) } }
                    }
                } label: {
                    Label("Standby server: \(standbyProfile?.displayName ?? window.serverName)", systemImage: "server.rack")
                }
                .frame(width: 460)
                TextField("Standby database name", text: $options.secondaryDatabase)
                    .textFieldStyle(.roundedBorder).frame(width: 460)
                Toggle("Initialize the standby with a full backup of the primary (overwrites it)", isOn: $options.initialize)
                    .toggleStyle(.checkbox)
                if !options.initialize {
                    Text("The standby must already be restored WITH NORECOVERY or STANDBY from the primary's latest backups.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                Text("Folder the primary writes log backups to").font(.subheadline.weight(.semibold))
                ServerFolderField(placeholder: "On \(window.serverName)", path: $options.backupFolder,
                                  session: session, capabilities: capabilities)
                Stepper("Back up the log every \(options.backupEveryMinutes) minute(s)", value: $options.backupEveryMinutes, in: 1...1440)
                Stepper("Delete backup files older than \(options.retentionMinutes / 60) hour(s)",
                        value: $options.retentionMinutes, in: 60...43_200, step: 60)
                Toggle("Compress log backups", isOn: $options.compression).toggleStyle(.checkbox)
                    .disabled(!capabilities.canCompress)
                Stepper("Alert when no backup for \(options.backupThresholdMinutes) minutes",
                        value: $options.backupThresholdMinutes, in: 5...1440, step: 5)
            }
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Text("The same folder as the standby reaches it").font(.subheadline.weight(.semibold))
                TextField(sameServer ? "Same path on one server" : "\\\\primary\\share or a mounted path",
                          text: $options.backupShare)
                    .textFieldStyle(.roundedBorder)
                Text("On Windows this is usually a UNC share both SQL Server Agent accounts can read. On Linux, mount the "
                     + "primary's folder on the standby (for example over SMB) and give its path here.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Copy folder on the standby").font(.subheadline.weight(.semibold))
                ServerFolderField(placeholder: "On \(standbyCapabilities?.serverName ?? "")", path: $options.copyFolder,
                                  session: standbySession, capabilities: standbyCapabilities)
                Stepper("Copy and restore every \(options.copyEveryMinutes) minute(s)", value: $options.copyEveryMinutes, in: 1...1440)
                Stepper("Start \(options.restoreOffsetMinutes) minute(s) after the backup", value: $options.restoreOffsetMinutes,
                        in: 0...120)
            }
        case 3:
            VStack(alignment: .leading, spacing: 10) {
                Picker("Standby database state", selection: $options.restoreMode) {
                    ForEach(LogShippingOptions.RestoreMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.radioGroup)
                Toggle("Disconnect users while restoring", isOn: $options.disconnectUsers).toggleStyle(.checkbox)
                Stepper("Delay restoring each backup by \(options.restoreDelayMinutes) minute(s)",
                        value: $options.restoreDelayMinutes, in: 0...10_080)
                Stepper("Alert when nothing is restored for \(options.restoreThresholdMinutes) minutes",
                        value: $options.restoreThresholdMinutes, in: 5...1440, step: 5)
                if options.initialize {
                    ServerFolderField(placeholder: "Standby data folder (default)", path: $options.dataFolder,
                                      session: standbySession, capabilities: standbyCapabilities)
                    ServerFolderField(placeholder: "Standby log folder (default)", path: $options.logFolder,
                                      session: standbySession, capabilities: standbyCapabilities)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                ValidationList(errors: options.validationErrors(sameServer: sameServer))
                Text("\(window.serverName).\(options.primaryDatabase) → \(standbyCapabilities?.serverName ?? "").\(options.secondaryDatabase)")
                    .font(.headline)
                Text("Backups every \(options.backupEveryMinutes) min to \(options.backupFolder); copied to \(options.copyFolder) "
                     + "and restored every \(options.copyEveryMinutes) min.")
                Toggle("Show Script", isOn: $showScript).toggleStyle(.switch)
                if showScript, let setup = setup {
                    ScriptTextView(text: setup.script(), settings: settings).frame(height: 280)
                }
            }
        }
    }

    private var setup: LogShippingSetup? {
        guard let standbySession, let standbyCapabilities else { return nil }
        return LogShippingSetup(primary: session, secondary: standbySession, options: options,
                                primaryCapabilities: capabilities, secondaryCapabilities: standbyCapabilities)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                if done || isRunning {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).disabled(isRunning)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if page > 0 { Button("Back") { page -= 1 } }
                    if page < pages.count - 1 {
                        Button("Next") { page += 1 }.keyboardShortcut(.defaultAction).disabled(options.primaryDatabase.isEmpty)
                    } else {
                        Button("Set Up Log Shipping") { run() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!options.validationErrors(sameServer: sameServer).isEmpty || setup == nil
                                      || !capabilities.canSchedule)
                    }
                }
            }
        }
        .padding(12)
    }

    private func chooseStandby(_ profile: ConnectionProfile) async {
        do {
            let endpoint = CompareEndpoint(kind: .database, connection: profile, database: "master")
            let session = try await window.pool.session(for: endpoint, app: app)
            standbyCapabilities = try await BackupCapabilityProbe(session: session).probe()
            standbySession = session
            standbyProfile = profile
            if let standbyCapabilities { options.copyFolder = standbyCapabilities.join(standbyCapabilities.backupFolder, "LogShippingCopy") }
            error = nil
        } catch {
            self.error = ScriptRunner.describeError(error)
        }
    }

    private func run() {
        guard let setup else { return }
        isRunning = true
        log = []
        Task {
            do {
                try await setup.run { message in Task { @MainActor in log.append(message) } }
                done = true
                await window.refresh()
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
            isRunning = false
        }
    }
}

// MARK: - Server options

struct BackupServerOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    @ObservedObject var preferences: BackupPreferences
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities

    enum Tab: String, CaseIterable, Identifiable {
        case files = "File Management"
        case monitoring = "Monitoring"
        case email = "Email"
        case encryption = "Encryption"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .files
    @State private var message = ""
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .files: BackupFileOptionsTab(window: window, preferences: preferences, session: session,
                                                      capabilities: capabilities, report: report)
                    case .monitoring: BackupMonitoringTab(preferences: preferences)
                    case .email: BackupEmailTab(session: session, capabilities: capabilities, report: report)
                    case .encryption: BackupEncryptionTab(session: session, report: report)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(message).font(.caption).foregroundStyle(isError ? Color.red : Color.secondary).lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 580)
    }

    private func report(_ text: String, _ error: Bool) {
        message = text
        isError = error
    }
}

struct BackupFileOptionsTab: View {
    @ObservedObject var window: BackupWindowModel
    @ObservedObject var preferences: BackupPreferences
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let report: (String, Bool) -> Void

    @State private var format = ""
    @State private var compressionDefault = false
    @State private var checksumDefault = false
    @State private var historyDays = 180
    @State private var testFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Default file name format (<AUTO>)").font(.subheadline.weight(.semibold))
                HStack {
                    TextField(BackupOptions.defaultFileNameFormat, text: $format).textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    FileNameTagMenu(text: $format, includeAuto: false)
                    Button("Save") {
                        preferences.defaultFormats[window.serverName.lowercased()] = format.isEmpty ? nil : format
                        report("Saved the default file name format for \(window.serverName).", false)
                    }
                }
                Text("The default backup folder is the server's: \(capabilities.backupFolder)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Server defaults").font(.subheadline.weight(.semibold))
                Toggle("Compress backups by default (backup compression default)", isOn: $compressionDefault)
                    .disabled(!capabilities.canCompress)
                Toggle("Write checksums by default (backup checksum default)", isOn: $checksumDefault)
                    .disabled(capabilities.majorVersion < 12)
                Button("Apply to \(window.serverName)") { applyDefaults() }
                Text("These apply to every backup on the server that does not say otherwise, including other tools'.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 6) {
                Text("History").font(.subheadline.weight(.semibold))
                Stepper("Activity History shows the last \(preferences.historyDays) days", value: $preferences.historyDays, in: 1...3650)
                HStack {
                    Stepper("Delete backup and restore history older than \(historyDays) days", value: $historyDays, in: 7...3650)
                    Button("Delete Now") { deleteHistory() }
                }
                Text("Runs msdb.dbo.sp_delete_backuphistory; the backup files themselves are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Folder check").font(.subheadline.weight(.semibold))
                ServerFolderField(placeholder: "Folder or share to test", path: $testFolder, session: session, capabilities: capabilities)
                Button("Check Permissions") { checkFolder() }.disabled(testFolder.isEmpty)
                Text("Backs up model to the folder copy-only, verifies and deletes it, to prove SQL Server's service account "
                     + "can write, read and delete there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            format = preferences.defaultFormats[window.serverName.lowercased()] ?? ""
            compressionDefault = capabilities.compressionDefault
            checksumDefault = capabilities.checksumDefault
        }
    }

    private func applyDefaults() {
        Task {
            do {
                try await BackupServerSettings(session: session).setDefaults(compression: compressionDefault, checksum: checksumDefault,
                                                                             majorVersion: capabilities.majorVersion)
                report("Server defaults updated.", false)
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }

    private func deleteHistory() {
        let cutoff = window.serverNow.addingTimeInterval(-Double(historyDays) * 86_400)
        Task {
            do {
                try await BackupServerSettings(session: session).deleteHistory(olderThan: cutoff)
                report("Deleted history older than \(ServerTime.display(cutoff)).", false)
                await window.refresh()
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }

    private func checkFolder() {
        Task {
            do {
                report(try await ServerFileBrowser(session: session, capabilities: capabilities).testFolder(testFolder), false)
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }
}

struct BackupMonitoringTab: View {
    @ObservedObject var preferences: BackupPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When is a database behind on backups?").font(.subheadline.weight(.semibold))
            Stepper("No full or differential backup for \(preferences.thresholds.fullBackupHours) hours",
                    value: $preferences.thresholds.fullBackupHours, in: 1...2160)
            Stepper("No log backup for \(preferences.thresholds.logBackupMinutes) minutes (full and bulk-logged recovery)",
                    value: $preferences.thresholds.logBackupMinutes, in: 5...10_080, step: 5)
            Text("Databases past these limits are marked in red in the database list, the status bar and reports.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct BackupEmailTab: View {
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let report: (String, Bool) -> Void
    @State private var settings = DatabaseMailSettings()
    @State private var profiles: [String] = []
    @State private var testRecipient = ""
    @State private var testProfile = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notifications are sent by SQL Server's Database Mail.").foregroundStyle(.secondary)
            if !profiles.isEmpty {
                Text("Existing profiles: \(profiles.joined(separator: ", "))").font(.caption)
            }
            Form {
                TextField("Profile name", text: $settings.profileName)
                TextField("SMTP server", text: $settings.smtpServer)
                TextField("Port", value: $settings.port, format: .number)
                Toggle("Use TLS (STARTTLS)", isOn: $settings.useSSL)
                TextField("User name (optional)", text: $settings.userName)
                SecureField("Password", text: $settings.password)
                TextField("Send from", text: $settings.fromAddress)
                TextField("Display name", text: $settings.displayName)
            }
            .formStyle(.grouped)
            .frame(height: 300)
            HStack {
                Button("Set Up Database Mail") { configure() }
                    .disabled(settings.smtpServer.isEmpty || settings.fromAddress.isEmpty)
                Spacer()
                TextField("Test recipient", text: $testRecipient).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Send Test Email") { test() }.disabled(testRecipient.isEmpty)
            }
        }
        .task { await loadProfiles() }
    }

    private func loadProfiles() async {
        profiles = (try? await DatabaseMailService(session: session).profiles()) ?? []
        testProfile = profiles.first ?? ""
    }

    private func configure() {
        Task {
            do {
                try await DatabaseMailService(session: session).configure(settings)
                report("Database Mail is set up with profile \(settings.profileName).", false)
                await loadProfiles()
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }

    private func test() {
        Task {
            do {
                try await DatabaseMailService(session: session).sendTest(profile: testProfile, recipients: testRecipient)
                report("Test email queued. Database Mail's log (msdb.dbo.sysmail_event_log) shows delivery problems.", false)
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }
}

struct BackupEncryptionTab: View {
    let session: SQLServerSession
    let report: (String, Bool) -> Void
    @State private var certificates: [BackupCertificate] = []
    @State private var selection: String?
    @State private var creating = false
    @State private var exporting: String?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Certificates in master that can encrypt backups. A backup encrypted with a certificate can only be "
                 + "restored where that certificate (with its private key) exists — export it and keep it safe.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Table(certificates, selection: $selection) {
                TableColumn("Name") { certificate in Text(certificate.name) }
                TableColumn("Expires") { certificate in Text(BackupFormat.date(certificate.expiry)) }.width(140)
                TableColumn("Private key") { certificate in
                    Text(certificate.hasPrivateKey ? (certificate.privateKeyLastBackedUp == nil ? "Never backed up" : "Backed up") : "Missing")
                        .foregroundStyle(certificate.hasPrivateKey && certificate.privateKeyLastBackedUp != nil ? Color.secondary : Color.orange)
                }
                .width(130)
            }
            .frame(height: 220)
            HStack {
                Button("New Certificate…") { creating = true }
                Button("Export…") { exporting = selection }.disabled(selection == nil)
                Button("Import…") { importing = true }
            }
        }
        .task { await load() }
        .sheet(isPresented: $creating) {
            NewCertificateSheet(session: session) { _ in Task { await load() } }
        }
        .sheet(item: Binding(get: { exporting.map { CertificateName(name: $0) } }, set: { exporting = $0?.name })) { item in
            CertificateExportSheet(session: session, name: item.name, report: report)
        }
        .sheet(isPresented: $importing) {
            CertificateImportSheet(session: session, report: report) { Task { await load() } }
        }
    }

    private func load() async {
        certificates = (try? await BackupEncryptionKeys(session: session).certificates()) ?? []
    }
}

struct CertificateName: Identifiable {
    var name: String
    var id: String { name }
}

extension UTType {
    static let backupCertificate = UTType(filenameExtension: BackupCertificateBundle.fileExtension, conformingTo: .json) ?? .json
}

struct CertificateExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    let name: String
    let report: (String, Bool) -> Void
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export \(name)").font(.headline)
            Text("The certificate and its private key are saved to a file on this Mac. The password encrypts the private "
                 + "key; it is needed to import the certificate on another server.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Confirm password", text: $confirm).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.count < 8 || password != confirm)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func export() {
        guard let url = CompareFilePanels.save(name: "\(name).\(BackupCertificateBundle.fileExtension)",
                                               types: [.backupCertificate]) else { return }
        Task {
            do {
                let bundle = try await BackupEncryptionKeys(session: session).export(name: name, password: password)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(bundle).write(to: url, options: .atomic)
                report("Exported \(name) to \(url.path).", false)
                dismiss()
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }
}

struct CertificateImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    let report: (String, Bool) -> Void
    let onImported: () -> Void
    @State private var url: URL?
    @State private var password = ""
    @State private var masterKeyPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import Certificate").font(.headline)
            HStack {
                Text(url?.lastPathComponent ?? "No file chosen").foregroundStyle(.secondary)
                Button("Choose…") { url = CompareFilePanels.open(directory: false, types: [.backupCertificate]) }
            }
            SecureField("Export password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Password for master's database master key, if it has none yet", text: $masterKeyPassword)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { importFile() }.keyboardShortcut(.defaultAction).disabled(url == nil || password.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func importFile() {
        guard let url else { return }
        Task {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let bundle = try decoder.decode(BackupCertificateBundle.self, from: Data(contentsOf: url))
                try await BackupEncryptionKeys(session: session).importBundle(bundle, password: password,
                                                                             masterKeyPassword: masterKeyPassword.isEmpty ? nil : masterKeyPassword)
                report("Imported certificate \(bundle.name).", false)
                onImported()
                dismiss()
            } catch {
                report(ScriptRunner.describeError(error), true)
            }
        }
    }
}
