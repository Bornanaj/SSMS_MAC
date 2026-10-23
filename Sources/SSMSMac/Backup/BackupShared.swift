import SwiftUI
import AppKit
import SQLServerKit

// MARK: - Formatting

enum BackupFormat {
    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        if seconds < 1 { return "< 1 s" }
        if seconds < 60 { return String(format: "%.0f s", seconds) }
        if seconds < 3600 { return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }
        return String(format: "%d:%02d:%02d", Int(seconds) / 3600, (Int(seconds) / 60) % 60, Int(seconds) % 60)
    }

    static func date(_ date: Date?) -> String {
        date.map(ServerTime.display) ?? ""
    }

    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "Never" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 120 { return "Just now" }
        if seconds < 7200 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 172_800 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) days ago"
    }
}

// MARK: - Icons

enum BackupColors {
    static let backup = Color.green
    static let restore = Color.blue
    static let failure = Color.red
    static let verify = Color.teal

    static func risk(_ risk: BackupRisk) -> Color {
        switch risk {
        case .ok: return .green
        case .warning: return .orange
        case .overdue, .never: return .red
        case .notApplicable: return .secondary
        }
    }
}

struct DatabaseStateIcon: View {
    let status: DatabaseBackupStatus

    var body: some View {
        switch status.operationalState {
        case .operational:
            Image(systemName: "cylinder.split.1x2").foregroundStyle(Color.accentColor)
        case .nonOperational:
            Image(systemName: "cylinder.split.1x2").foregroundStyle(Color.orange)
        case .readOnly:
            Image(systemName: "lock.circle").foregroundStyle(Color.secondary)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red)
        }
    }
}

struct ActivityOutcomeIcon: View {
    let activity: BackupActivity

    var body: some View {
        if !activity.succeeded {
            Image(systemName: "xmark.circle.fill").foregroundStyle(BackupColors.failure).help("Failed")
        } else if activity.hasWarnings || activity.isDamaged {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange).help("Completed with warnings")
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(BackupColors.backup).help("Succeeded")
        }
    }
}

struct ActivityKindIcon: View {
    let activity: BackupActivity

    var body: some View {
        switch activity.kind {
        case .backup:
            Image(systemName: activity.typeCode == "L" ? "doc.text" : "archivebox").foregroundStyle(BackupColors.backup)
        case .restore:
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(BackupColors.restore)
        case .verify:
            Image(systemName: "checkmark.shield").foregroundStyle(BackupColors.verify)
        case .jobFailure:
            Image(systemName: "gearshape.2").foregroundStyle(BackupColors.failure)
        }
    }
}

// MARK: - Wizard chrome

/// Numbered steps across the top of a wizard; finished steps can be revisited.
struct WizardStepHeader: View {
    let titles: [String]
    let current: Int
    var subtitle: String = ""
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 5) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                        .background(index == current ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                        .foregroundStyle(index == current ? Color.white : Color.primary)
                    Text(title).fontWeight(index == current ? .semibold : .regular).lineLimit(1)
                }
                .onTapGesture { if index < current { onSelect(index) } }
            }
            Spacer(minLength: 8)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
    }
}

/// A list of problems in red above a wizard's footer.
struct ValidationList: View {
    let errors: [String]

    var body: some View {
        if !errors.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(errors, id: \.self) { error in
                    Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tags

/// Inserts file name tags into a text field's value.
struct FileNameTagMenu: View {
    @Binding var text: String
    var includeAuto = true

    private var tags: [(String, String)] {
        var list: [(String, String)] = [("<DATABASE>", "Database name"), ("<TYPE>", "FULL, DIFF or LOG"),
                                        ("<INSTANCE>", "Instance name, (local) for a default instance"),
                                        ("<SERVER>", "Server name"), ("<AVAILABILITYGROUP>", "Availability group"),
                                        ("<DATETIME yyyymmdd_hhnnss>", "Backup start time"),
                                        ("<DATETIME yyyy-mm-dd>", "Backup start date")]
        if includeAuto { list.insert(("<AUTO>", "The default name format"), at: 0) }
        return list
    }

    var body: some View {
        Menu {
            ForEach(tags, id: \.0) { tag in
                Button("\(tag.0)  —  \(tag.1)") { text += tag.0 }
            }
        } label: {
            Image(systemName: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Insert a file name tag")
    }
}

// MARK: - Retention

struct RetentionEditor: View {
    let title: String
    @Binding var retention: BackupRetention
    var allowsBefore = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack {
                Picker("", selection: $retention.rule) {
                    ForEach(BackupRetention.Rule.allCases, id: \.self) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .labelsHidden()
                .frame(width: 280)
                if retention.rule != .none {
                    TextField("", value: $retention.value, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Stepper("", value: $retention.value, in: 1...9999).labelsHidden()
                }
            }
            if retention.rule != .none && allowsBefore {
                Picker("When", selection: $retention.beforeBackup) {
                    Text("After the backup succeeds").tag(false)
                    Text("Before the backup starts").tag(true)
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            }
            if retention.rule != .none {
                Text("Only files SQL Server wrote for the same database and backup type, directly in this folder, are "
                     + "deleted (found from the backup history).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Server file browser

/// Browses the SQL Server machine's folders through the server: backup paths are the server's,
/// not this Mac's.
struct ServerFileBrowserView: View {
    enum Purpose {
        case folder
        case files
    }

    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let purpose: Purpose
    let start: String
    let onChoose: ([String]) -> Void

    @State private var folder = ""
    @State private var entries: [ServerFileEntry] = []
    @State private var roots: [ServerFileEntry] = []
    @State private var selection: Set<String> = []
    @State private var error: String?
    @State private var isLoading = false
    @State private var newFolder = ""

    private var browser: ServerFileBrowser { ServerFileBrowser(session: session, capabilities: capabilities) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let parent = capabilities.folder(of: folder.hasSuffix("/") || folder.hasSuffix("\\")
                                                     ? String(folder.dropLast()) : folder)
                    if !parent.isEmpty { open(parent) } else if capabilities.platform == .linux { open("/") }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Parent folder")
                TextField("Folder on \(capabilities.serverName)", text: $folder)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { open(folder) }
                Menu {
                    ForEach(roots) { root in
                        Button(root.name) { open(root.path) }
                    }
                } label: {
                    Image(systemName: "internaldrive")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if isLoading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()
            List(selection: $selection) {
                ForEach(entries) { entry in
                    HStack {
                        Image(systemName: entry.isDirectory ? "folder" : (entry.isBackupFile ? "archivebox" : "doc"))
                            .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                        Text(entry.name)
                        Spacer()
                        if !entry.isDirectory {
                            Text(BackupFormat.size(entry.size)).font(.caption).foregroundStyle(.secondary)
                            Text(BackupFormat.date(entry.modified)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.path)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if entry.isDirectory { open(entry.path) } else if purpose == .files { finish([entry.path]) }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
            Divider()
            HStack {
                if purpose == .folder {
                    TextField("New folder", text: $newFolder).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button("Create") { createFolder() }.disabled(newFolder.isEmpty)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if purpose == .folder {
                    Button("Choose This Folder") { finish([folder]) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(folder.isEmpty)
                } else {
                    Button("Choose") { finish(Array(selection).filter { path in !(entries.first { $0.path == path }?.isDirectory ?? true) }) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.isEmpty)
                }
            }
            .padding(10)
        }
        .frame(width: 640, height: 480)
        .task {
            roots = await browser.roots()
            open(start.isEmpty ? capabilities.backupFolder : start)
        }
    }

    private func open(_ path: String) {
        folder = path
        selection = []
        isLoading = true
        Task {
            do {
                entries = try await browser.list(path)
                error = nil
            } catch {
                entries = []
                self.error = ScriptRunner.describeError(error)
            }
            isLoading = false
        }
    }

    private func createFolder() {
        let path = capabilities.join(folder, newFolder)
        Task {
            do {
                try await browser.createFolder(path)
                newFolder = ""
                open(path)
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
        }
    }

    private func finish(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        onChoose(paths)
        dismiss()
    }
}

/// A folder field with a Browse button that opens the server file browser.
struct ServerFolderField: View {
    let placeholder: String
    @Binding var path: String
    let session: SQLServerSession?
    let capabilities: BackupServerCapabilities?
    var showsTags = false
    @State private var browsing = false

    var body: some View {
        HStack {
            TextField(placeholder, text: $path).textFieldStyle(.roundedBorder)
            if showsTags { FileNameTagMenu(text: $path, includeAuto: false) }
            Button("Browse…") { browsing = true }
                .disabled(session == nil || capabilities == nil)
        }
        .sheet(isPresented: $browsing) {
            if let session, let capabilities {
                ServerFileBrowserView(session: session, capabilities: capabilities, purpose: .folder,
                                      start: path.contains("<") ? "" : path) { paths in
                    if let first = paths.first { path = first }
                }
            }
        }
    }
}

// MARK: - Schedules

/// SQL Backup's Schedule Editor: when a job runs.
struct ScheduleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var schedule: BackupSchedule
    let onSave: (BackupSchedule) -> Void

    private var startTimeBinding: Binding<Date> { timeBinding(\.startTime) }
    private var endTimeBinding: Binding<Date> { timeBinding(\.endTime) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $schedule.name)
                Picker("Occurs", selection: $schedule.frequency) {
                    ForEach(BackupSchedule.Frequency.allCases, id: \.self) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                frequencyFields
                if schedule.frequency != .agentStart && schedule.frequency != .cpuIdle {
                    if schedule.frequency != .once {
                        Toggle("Repeat during the day", isOn: $schedule.repeats)
                    }
                    if schedule.repeats && schedule.frequency != .once {
                        HStack {
                            Text("Every")
                            TextField("", value: $schedule.repeatInterval, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 60)
                            Picker("", selection: $schedule.repeatUnit) {
                                ForEach(BackupSchedule.RepeatUnit.allCases, id: \.self) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                        DatePicker("Starting at", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                        DatePicker("Ending at", selection: endTimeBinding, displayedComponents: .hourAndMinute)
                    } else {
                        DatePicker("At", selection: startTimeBinding, displayedComponents: .hourAndMinute)
                    }
                    DatePicker(schedule.frequency == .once ? "On" : "Start date", selection: startDateBinding,
                               displayedComponents: .date)
                    if schedule.frequency != .once {
                        Toggle("End date", isOn: Binding(get: { schedule.endDate != nil },
                                                         set: { schedule.endDate = $0 ? schedule.startDate.addingTimeInterval(30 * 86_400) : nil }))
                        if schedule.endDate != nil {
                            DatePicker("Ends", selection: endDateBinding, displayedComponents: .date)
                        }
                    }
                }
                Toggle("Enabled", isOn: $schedule.isEnabled)
            }
            .formStyle(.grouped)
            .environment(\.timeZone, ServerTime.calendar.timeZone)
            .environment(\.calendar, ServerTime.calendar)
            Text(schedule.summary).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 20)
            Text("Times are the server's clock.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    onSave(schedule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 480, height: 560)
    }

    @ViewBuilder
    private var frequencyFields: some View {
        switch schedule.frequency {
        case .daily:
            Stepper("Every \(schedule.interval) day(s)", value: $schedule.interval, in: 1...365)
        case .weekly:
            Stepper("Every \(schedule.interval) week(s)", value: $schedule.interval, in: 1...52)
            HStack(spacing: 4) {
                ForEach(0..<7, id: \.self) { day in
                    Toggle(String(BackupSchedule.weekdayNames[day].prefix(3)), isOn: weekdayBinding(day))
                        .toggleStyle(.button)
                        .controlSize(.small)
                }
            }
        case .monthly:
            Stepper("Day \(schedule.dayOfMonth) of the month", value: $schedule.dayOfMonth, in: 1...31)
            Stepper("Every \(schedule.interval) month(s)", value: $schedule.interval, in: 1...12)
        case .monthlyRelative:
            Picker("The", selection: $schedule.relativeOrdinal) {
                ForEach(BackupSchedule.ordinalNames, id: \.0) { item in Text(item.1).tag(item.0) }
            }
            Picker("Day", selection: $schedule.relativeDay) {
                ForEach(BackupSchedule.relativeDayNames, id: \.0) { item in Text(item.1).tag(item.0) }
            }
            Stepper("Every \(schedule.interval) month(s)", value: $schedule.interval, in: 1...12)
        case .once, .agentStart, .cpuIdle:
            EmptyView()
        }
    }

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(get: { schedule.weekdays & (1 << day) != 0 },
                set: { on in
                    if on { schedule.weekdays |= 1 << day } else { schedule.weekdays &= ~(1 << day) }
                })
    }

    /// Times of day as dates on the server's (UTC-read) calendar, so the picker shows server time.
    private func timeBinding(_ keyPath: WritableKeyPath<BackupSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            let base = ServerTime.calendar.startOfDay(for: Date())
            return base.addingTimeInterval(TimeInterval(schedule[keyPath: keyPath]))
        }, set: { date in
            let parts = ServerTime.calendar.dateComponents([.hour, .minute], from: date)
            schedule[keyPath: keyPath] = (parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60
        })
    }

    private var startDateBinding: Binding<Date> {
        Binding(get: { schedule.startDate }, set: { schedule.startDate = ServerTime.calendar.startOfDay(for: $0) })
    }

    private var endDateBinding: Binding<Date> {
        Binding(get: { schedule.endDate ?? schedule.startDate }, set: { schedule.endDate = ServerTime.calendar.startOfDay(for: $0) })
    }
}

/// The schedules of one job, with add, edit and remove.
struct ScheduleListEditor: View {
    let title: String
    @Binding var schedules: [BackupSchedule]
    let suggestion: BackupSchedule
    @State private var editing: BackupSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    editing = BackupSchedule(name: suggestion.name, frequency: suggestion.frequency,
                                             repeats: suggestion.repeats, repeatInterval: suggestion.repeatInterval,
                                             repeatUnit: suggestion.repeatUnit, startTime: suggestion.startTime,
                                             endTime: suggestion.endTime, startDate: suggestion.startDate)
                } label: {
                    Label("Add Schedule", systemImage: "plus")
                }
                .controlSize(.small)
            }
            if schedules.isEmpty {
                Text("No schedule: the job only runs when started by hand.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(schedules) { schedule in
                HStack {
                    Image(systemName: schedule.isEnabled ? "calendar" : "calendar.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text(schedule.summary)
                    Spacer()
                    Button("Edit") { editing = schedule }.buttonStyle(.link)
                    Button {
                        schedules.removeAll { $0.id == schedule.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .sheet(item: $editing) { schedule in
            ScheduleEditorView(schedule: schedule) { saved in
                if let index = schedules.firstIndex(where: { $0.id == saved.id }) {
                    schedules[index] = saved
                } else {
                    schedules.append(saved)
                }
            }
        }
    }
}
