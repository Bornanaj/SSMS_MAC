import SwiftUI
import SQLServerKit

/// The SSMS server properties dialog: read-only pages plus an editable sp_configure grid.
struct ServerPropertiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    private enum Page: String, CaseIterable, Identifiable {
        case general, configuration
        var id: String { rawValue }
        var title: String { self == .general ? "Properties" : "Configuration" }
    }

    @State private var page: Page = .general
    @State private var groups: [ServerPropertyGroup] = []
    @State private var settings: [ConfigurationSetting] = []
    @State private var selection: Int?
    @State private var search = ""
    @State private var showAdvanced = false
    @State private var editingValue = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var pendingScript: PendingScript?

    private var visibleSettings: [ConfigurationSetting] {
        settings.filter { setting in
            if !showAdvanced && setting.isAdvanced { return false }
            guard !search.isEmpty else { return true }
            return setting.name.localizedCaseInsensitiveContains(search)
                || setting.settingDescription.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: ConfigurationSetting? {
        guard let selection else { return nil }
        return settings.first { $0.configurationID == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "server.rack", title: "Server Properties",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            Picker("", selection: $page) {
                ForEach(Page.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch page {
            case .general: generalPage
            case .configuration: configurationPage
            }
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 940, height: 640)
        .task { await load() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in await apply(script) }
        }
    }

    private var generalPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name).font(.headline)
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.key)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 190, alignment: .leading)
                                Text(entry.value)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var configurationPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("Show advanced options", isOn: $showAdvanced)
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
            }
            .padding(8)
            Divider()

            Table(visibleSettings, selection: $selection) {
                TableColumn("Setting") { setting in
                    HStack(spacing: 5) {
                        Text(setting.name).lineLimit(1)
                        if setting.isPending {
                            Image(systemName: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                                .help("Configured but not yet in use")
                        }
                    }
                }.width(min: 180, ideal: 240)
                TableColumn("Configured") { Text($0.configuredValue).monospacedDigit() }.width(100)
                TableColumn("In use") { Text($0.runningValue).monospacedDigit() }.width(100)
                TableColumn("Range") { Text("\($0.minimum) … \($0.maximum)") }.width(140)
                TableColumn("Advanced") { Text($0.isAdvanced ? "Yes" : "") }.width(70)
                TableColumn("Dynamic") { Text($0.isDynamic ? "Yes" : "Restart") }.width(70)
            }

            Divider()
            editor
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let setting = selected {
            VStack(alignment: .leading, spacing: 8) {
                Text(setting.settingDescription.isEmpty ? setting.name : setting.settingDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    if setting.isBoolean {
                        Picker("Value", selection: $editingValue) {
                            Text("Off (0)").tag("0")
                            Text("On (1)").tag("1")
                        }
                        .frame(width: 200)
                    } else {
                        LabeledContent("Value") {
                            TextField("", text: $editingValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                        }
                        Text("allowed \(setting.minimum) … \(setting.maximum)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !setting.isDynamic {
                        Label("Needs a service restart", systemImage: "arrow.clockwise.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Script change") { build(setting) }
                        .disabled(editingValue == setting.configuredValue || editingValue.isEmpty)
                }
            }
            .padding(12)
            .onChange(of: selection) { _, _ in
                editingValue = selected?.configuredValue ?? ""
            }
            .onAppear { editingValue = setting.configuredValue }
        } else {
            Text("Select a setting to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }

    private func build(_ setting: ConfigurationSetting) {
        let service = ServerConfiguration(session: server.session)
        let script = service.changeScript(setting: setting, newValue: editingValue)
        pendingScript = PendingScript(title: "Change \(setting.name)", script: script,
                                      destructive: !setting.isDynamic)
    }

    private func apply(_ script: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await ServerConfiguration(session: server.session).apply(script)
            isError = false
            status = "Applied."
            await load()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        let service = ServerConfiguration(session: server.session)
        do {
            groups = try await service.properties()
            settings = (try? await service.settings()) ?? []
            isError = false
            let pending = settings.filter(\.isPending).count
            status = pending > 0
                ? "\(settings.count) settings, \(pending) pending a restart or RECONFIGURE."
                : "\(settings.count) settings."
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}
