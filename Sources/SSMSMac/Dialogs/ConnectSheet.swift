import SwiftUI
import SQLServerKit
import TDSKit

/// The "Connect to Server" dialog, with the same fields SSMS asks for.
struct ConnectSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var profile = ConnectionProfile()
    @State private var password = ""
    @State private var accessToken = ""
    @State private var showOptions = false
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var selectedSavedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                savedList
                    .frame(minWidth: 210, idealWidth: 240, maxWidth: 320)
                form
                    .frame(minWidth: 430)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: showOptions ? 620 : 470)
        .onAppear(perform: prefill)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connect to Server").font(.headline)
                Text("SQL Server Database Engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var savedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Saved connections")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            List(selection: $selectedSavedID) {
                ForEach(app.connections.profiles) { saved in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(saved.displayName).lineLimit(1)
                        Text(saved.authentication.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(saved.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { app.connections.remove(saved) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selectedSavedID) { _, newValue in
                guard let newValue,
                      let saved = app.connections.profiles.first(where: { $0.id == newValue }) else { return }
                profile = saved
                password = app.connections.password(for: saved) ?? ""
            }
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Server name") {
                    TextField("localhost,1433", text: $profile.server)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Authentication") {
                    Picker("", selection: $profile.authentication) {
                        ForEach(SQLAuthenticationType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                }

                if profile.authentication == .windows {
                    LabeledContent("Domain") {
                        TextField("CONTOSO", text: $profile.domain)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if profile.authentication == .entraIDAccessToken {
                    LabeledContent("Access token") {
                        SecureField("eyJ0eXAiOi…", text: $accessToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("Obtain a token with: az account get-access-token "
                         + "--resource https://database.windows.net/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Login") {
                        TextField("sa", text: $profile.username)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("Password") {
                        SecureField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Remember password", isOn: $profile.savePassword)
                }

                DisclosureGroup("Connection options", isExpanded: $showOptions) {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Connect to database") {
                            TextField("<default>", text: $profile.database)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Encryption") {
                            Picker("", selection: $profile.encryption) {
                                Text("Mandatory").tag(TDSEncryptionMode.required)
                                Text("Strict (TDS 8.0)").tag(TDSEncryptionMode.strict)
                                Text("Optional").tag(TDSEncryptionMode.disabled)
                            }
                            .labelsHidden()
                        }
                        Toggle("Trust server certificate", isOn: $profile.trustServerCertificate)
                        Toggle("Read-only intent (ApplicationIntent)",
                               isOn: $profile.applicationIntentReadOnly)

                        LabeledContent("Connection timeout") {
                            HStack {
                                TextField("", value: $profile.connectTimeoutSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Text("seconds").foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Execution timeout") {
                            HStack {
                                TextField("", value: $profile.executionTimeoutSeconds, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                                Text("seconds (0 = no limit)").foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Application name") {
                            TextField("", text: $profile.applicationName)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Custom colour") {
                            Picker("", selection: Binding(
                                get: { profile.colorHex ?? "" },
                                set: { profile.colorHex = $0.isEmpty ? nil : $0 }
                            )) {
                                ForEach(Theme.connectionColors, id: \.hex) { entry in
                                    Text(entry.name).tag(entry.hex)
                                }
                            }
                            .labelsHidden()
                        }
                        LabeledContent("Display name") {
                            TextField("optional", text: $profile.name)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(14)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let testResult {
                Label(testResult, systemImage: testResult.hasPrefix("Connected")
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("Connected") ? Color.green : Color.red)
                    .lineLimit(2)
            }
            if let error = app.connectionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Test") { test() }
                .disabled(isTesting || profile.server.isEmpty)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(app.isConnecting ? "Connecting…" : "Connect") { connect() }
                .keyboardShortcut(.defaultAction)
                .disabled(app.isConnecting || profile.server.isEmpty)
        }
        .padding(14)
    }

    private func prefill() {
        if profile.server.isEmpty, let recent = app.connections.profiles.first {
            profile = recent
            selectedSavedID = recent.id
            password = app.connections.password(for: recent) ?? ""
        } else if profile.server.isEmpty {
            profile.server = "localhost"
            profile.username = "sa"
        }
    }

    private func connect() {
        // Picking a saved connection fills the form, including its display name. If the
        // server or login is then edited, this is a different connection: it gets its
        // own entry, and the inherited name is dropped so it cannot be filed under the
        // label of the connection it was copied from.
        var target = profile
        if let existing = app.connections.profiles.first(where: { $0.id == profile.id }),
           existing.server != profile.server || existing.username != profile.username {
            target.id = UUID()
            if target.name == existing.name { target.name = "" }
        }
        Task {
            await app.connect(profile: target,
                              password: password.isEmpty ? nil : password,
                              accessToken: accessToken.isEmpty ? nil : accessToken)
            if app.connectionError == nil { dismiss() }
        }
    }

    private func test() {
        isTesting = true
        testResult = nil
        let target = profile
        let pw = password
        let token = accessToken
        Task {
            do {
                let session = try await SQLServerSession.connect(
                    profile: target,
                    password: pw.isEmpty ? nil : pw,
                    accessToken: token.isEmpty ? nil : token)
                let info = await session.serverInfo
                await session.close()
                testResult = "Connected to \(info.serverName) — \(info.friendlyVersion)"
            } catch {
                testResult = String(describing: error)
            }
            isTesting = false
        }
    }
}
