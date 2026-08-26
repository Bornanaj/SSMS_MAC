import SwiftUI
import SQLServerKit

// MARK: - Logins

/// The SSMS Security > Logins node, with the operations that node offers.
struct LoginsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var logins: [ServerLogin] = []
    @State private var roles: [String] = []
    @State private var databases: [String] = []
    @State private var selection: Int?
    @State private var search = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var pendingScript: PendingScript?
    @State private var showNewLogin = false
    @State private var passwordTarget: ServerLogin?

    private var visible: [ServerLogin] {
        guard !search.isEmpty else { return logins }
        return logins.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var selected: ServerLogin? {
        guard let selection else { return nil }
        return logins.first { $0.principalID == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "person.badge.key", title: "Logins",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            toolbar
            Divider()
            HSplitView {
                list.frame(minWidth: 340)
                detail.frame(minWidth: 300)
            }
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 900, height: 600)
        .task { await load() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in
                await apply(script, database: "master")
            }
        }
        .sheet(isPresented: $showNewLogin) {
            NewLoginSheet(server: server, roles: roles, databases: databases) { script in
                pendingScript = PendingScript(title: "Create login", script: script)
            }
        }
        .sheet(item: $passwordTarget) { login in
            ChangePasswordSheet(login: login.name) { script in
                pendingScript = PendingScript(title: "Change password", script: script)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { showNewLogin = true } label: { Label("New Login", systemImage: "plus") }

            Button {
                guard let login = selected else { return }
                let service = SecurityService(session: server.session)
                pendingScript = PendingScript(title: "Drop login",
                                              script: service.dropLoginScript(login.name),
                                              destructive: true)
            } label: { Label("Drop", systemImage: "trash") }
                .disabled(selected == nil)

            Button {
                guard let login = selected else { return }
                Task { await toggleEnabled(login) }
            } label: {
                Label(selected?.isDisabled == true ? "Enable" : "Disable",
                      systemImage: selected?.isDisabled == true ? "play.circle" : "pause.circle")
            }
            .disabled(selected == nil)

            Button {
                passwordTarget = selected
            } label: { Label("Password…", systemImage: "key") }
                .disabled(selected?.isSQLLogin != true)

            Spacer()
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(8)
    }

    private var list: some View {
        Table(visible, selection: $selection) {
            TableColumn("Name") { login in
                HStack(spacing: 6) {
                    Image(systemName: login.isDisabled ? "person.slash" : "person.fill")
                        .foregroundStyle(login.isDisabled ? Color.secondary : Color.accentColor)
                    Text(login.name).lineLimit(1)
                }
            }.width(min: 150, ideal: 200)
            TableColumn("Type") { Text($0.typeLabel) }.width(130)
            TableColumn("Default database") { Text($0.defaultDatabase) }.width(140)
            TableColumn("Server roles") { Text($0.serverRoles.joined(separator: ", ")) }
                .width(min: 120, ideal: 180)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let login = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(login.name).font(.headline)
                    LabeledContent("Type", value: login.typeLabel)
                    LabeledContent("Status", value: login.isDisabled ? "Disabled" : "Enabled")
                    LabeledContent("Default database", value: login.defaultDatabase)
                    LabeledContent("Created", value: login.createDate)
                    if login.isSQLLogin {
                        LabeledContent("Enforce policy", value: login.isPolicyChecked ? "Yes" : "No")
                        LabeledContent("Enforce expiration",
                                       value: login.isExpirationChecked ? "Yes" : "No")
                    }

                    Divider()
                    Text("Server roles").font(.subheadline.weight(.medium))
                    ForEach(roles, id: \.self) { role in
                        Toggle(role, isOn: Binding(
                            get: { login.serverRoles.contains(role) },
                            set: { _ in toggleRole(role, for: login) }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a login", systemImage: "person.crop.circle")
        }
    }

    private func toggleRole(_ role: String, for login: ServerLogin) {
        let service = SecurityService(session: server.session)
        let current = Set(login.serverRoles)
        var target = current
        if current.contains(role) { target.remove(role) } else { target.insert(role) }
        let script = service.setServerRoleMembership(login: login.name, roles: target,
                                                     current: current)
        guard !script.isEmpty else { return }
        pendingScript = PendingScript(title: "Change role membership", script: script)
    }

    private func toggleEnabled(_ login: ServerLogin) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let service = SecurityService(session: server.session)
            try await service.setLoginEnabled(login.name, enabled: login.isDisabled)
            isError = false
            status = "\(login.name) \(login.isDisabled ? "enabled" : "disabled")."
            await load()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func apply(_ script: String, database: String?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await SecurityService(session: server.session).execute(script, database: database)
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
        let service = SecurityService(session: server.session)
        do {
            async let loginsTask = service.logins()
            async let rolesTask = service.serverRoles()
            logins = try await loginsTask
            roles = try await rolesTask
            let dbResult = try await server.session.metadataQuery(
                "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' ORDER BY name")
            databases = (dbResult.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
            isError = false
            status = "\(logins.count) logins."
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}

// MARK: - New login

private struct NewLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let roles: [String]
    let databases: [String]
    var onScript: (String) -> Void

    @State private var definition = SecurityService.LoginDefinition()
    @State private var confirmPassword = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "person.badge.plus", title: "New Login",
                           subtitle: server.displayName, isBusy: false)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Login name") {
                        TextField("", text: $definition.name)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Authentication", selection: $definition.kind) {
                        ForEach(SecurityService.LoginDefinition.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }

                    if definition.kind == .sqlLogin {
                        LabeledContent("Password") {
                            SecureField("", text: $definition.password)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledContent("Confirm") {
                            SecureField("", text: $confirmPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                        Toggle("Enforce password policy", isOn: $definition.enforcePolicy)
                        Toggle("Enforce password expiration", isOn: $definition.enforceExpiration)
                            .disabled(!definition.enforcePolicy)
                        Toggle("User must change password at next login",
                               isOn: $definition.mustChangePassword)
                            .disabled(!definition.enforcePolicy)
                    }

                    Picker("Default database", selection: $definition.defaultDatabase) {
                        ForEach(databases, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Login is disabled", isOn: $definition.isDisabled)

                    Divider()
                    Text("Server roles").font(.subheadline.weight(.medium))
                    ForEach(roles, id: \.self) { role in
                        Toggle(role, isOn: Binding(
                            get: { definition.serverRoles.contains(role) },
                            set: { on in
                                if on { definition.serverRoles.append(role) }
                                else { definition.serverRoles.removeAll { $0 == role } }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { build() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 600)
        .onAppear {
            if definition.defaultDatabase.isEmpty || !databases.contains(definition.defaultDatabase) {
                definition.defaultDatabase = databases.first ?? "master"
            }
        }
    }

    private func build() {
        if definition.kind == .sqlLogin, definition.password != confirmPassword {
            errorText = "The passwords do not match."
            return
        }
        do {
            let script = try SecurityService(session: server.session)
                .createLoginScript(definition)
            onScript(script)
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }
}

// MARK: - Change password

private struct ChangePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let login: String
    var onScript: (String) -> Void

    @State private var password = ""
    @State private var confirm = ""
    @State private var mustChange = false
    @State private var unlock = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change password").font(.headline)
            Text(login).font(.caption).foregroundStyle(.secondary)
            LabeledContent("New password") {
                SecureField("", text: $password).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Confirm") {
                SecureField("", text: $confirm).textFieldStyle(.roundedBorder)
            }
            Toggle("User must change password at next login", isOn: $mustChange)
            Toggle("Unlock the login", isOn: $unlock)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") {
                    guard password == confirm else {
                        errorText = "The passwords do not match."
                        return
                    }
                    guard !password.isEmpty else {
                        errorText = "Enter a password."
                        return
                    }
                    onScript(SecurityService.changePasswordScriptStatic(
                        login: login, newPassword: password,
                        mustChange: mustChange, unlock: unlock))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420, height: 300)
    }
}

// MARK: - Database security

/// Users, roles and their membership for one database.
struct DatabaseSecuritySheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    private enum Tab: String, CaseIterable, Identifiable {
        case users, roles
        var id: String { rawValue }
        var title: String { self == .users ? "Users" : "Roles" }
    }

    @State private var tab: Tab = .users
    @State private var users: [DatabasePrincipal] = []
    @State private var roles: [DatabasePrincipal] = []
    @State private var logins: [String] = []
    @State private var schemas: [String] = []
    @State private var selection: Int?
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var pendingScript: PendingScript?
    @State private var showNewUser = false
    @State private var newRoleName = ""
    @State private var showNewRole = false

    private var rows: [DatabasePrincipal] { tab == .users ? users : roles }
    private var selected: DatabasePrincipal? {
        guard let selection else { return nil }
        return rows.first { $0.principalID == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "lock.shield", title: "Database Security",
                           subtitle: "\(server.displayName) · \(database)", isBusy: isBusy)
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            toolbar
            Divider()
            HSplitView {
                table.frame(minWidth: 380)
                detail.frame(minWidth: 280)
            }
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 900, height: 600)
        .task { await load() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in
                await apply(script)
            }
        }
        .sheet(isPresented: $showNewUser) {
            NewDatabaseUserSheet(database: database, logins: logins, schemas: schemas,
                                 roles: roles.map(\.name)) { script in
                pendingScript = PendingScript(title: "Create user", script: script)
            }
        }
        .alert("New role", isPresented: $showNewRole) {
            TextField("Role name", text: $newRoleName)
            Button("Cancel", role: .cancel) { newRoleName = "" }
            Button("Script") {
                let service = SecurityService(session: server.session)
                let script = service.createRoleScript(database: database, name: newRoleName,
                                                      owner: "")
                newRoleName = ""
                pendingScript = PendingScript(title: "Create role", script: script)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if tab == .users {
                Button { showNewUser = true } label: { Label("New User", systemImage: "plus") }
                Button {
                    guard let user = selected else { return }
                    let service = SecurityService(session: server.session)
                    pendingScript = PendingScript(
                        title: "Drop user",
                        script: service.dropUserScript(database: database, name: user.name),
                        destructive: true)
                } label: { Label("Drop", systemImage: "trash") }
                    .disabled(selected == nil || selected?.isFixedRole == true)
            } else {
                Button { showNewRole = true } label: { Label("New Role", systemImage: "plus") }
            }
            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(8)
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { principal in
                HStack(spacing: 6) {
                    Image(systemName: principal.isRole ? "person.3" : "person")
                        .foregroundStyle(principal.isFixedRole ? Color.secondary : Color.accentColor)
                    Text(principal.name).lineLimit(1)
                }
            }.width(min: 140, ideal: 190)
            TableColumn("Type") { Text($0.typeLabel) }.width(130)
            TableColumn("Login") { Text($0.loginName) }.width(130)
            TableColumn(tab == .users ? "Roles" : "Members") {
                Text($0.roles.joined(separator: ", ")).foregroundStyle(.secondary)
            }.width(min: 120, ideal: 200)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let principal = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(principal.name).font(.headline)
                    LabeledContent("Type", value: principal.typeLabel)
                    if !principal.loginName.isEmpty {
                        LabeledContent("Login", value: principal.loginName)
                    }
                    if !principal.defaultSchema.isEmpty {
                        LabeledContent("Default schema", value: principal.defaultSchema)
                    }
                    LabeledContent("Created", value: principal.createDate)

                    if tab == .users {
                        Divider()
                        Text("Database roles").font(.subheadline.weight(.medium))
                        ForEach(roles.filter { !$0.name.isEmpty }, id: \.principalID) { role in
                            Toggle(role.name, isOn: Binding(
                                get: { principal.roles.contains(role.name) },
                                set: { _ in toggleRole(role.name, for: principal) }
                            ))
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select a principal", systemImage: "lock.shield")
        }
    }

    private func toggleRole(_ role: String, for principal: DatabasePrincipal) {
        let service = SecurityService(session: server.session)
        let current = Set(principal.roles)
        var target = current
        if current.contains(role) { target.remove(role) } else { target.insert(role) }
        let script = service.setDatabaseRoleMembership(database: database, member: principal.name,
                                                       roles: target, current: current)
        guard !script.isEmpty else { return }
        pendingScript = PendingScript(title: "Change role membership", script: script)
    }

    private func apply(_ script: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await SecurityService(session: server.session).execute(script, database: database)
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
        let service = SecurityService(session: server.session)
        do {
            users = try await service.users(database: database)
            roles = try await service.roles(database: database)
            let loginResult = try await server.session.metadataQuery(
                "SELECT name FROM sys.server_principals WHERE type IN ('S','U','G') "
                    + "AND name NOT LIKE '##%' ORDER BY name")
            logins = (loginResult.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
            let schemaResult = try await server.session.metadataQuery(
                "SELECT name FROM sys.schemas ORDER BY name", database: database)
            schemas = (schemaResult.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
            isError = false
            status = "\(users.count) users, \(roles.count) roles."
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}

private struct NewDatabaseUserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let database: String
    let logins: [String]
    let schemas: [String]
    let roles: [String]
    var onScript: (String) -> Void

    @State private var name = ""
    @State private var login = ""
    @State private var defaultSchema = "dbo"
    @State private var withoutLogin = false
    @State private var selectedRoles: Set<String> = []
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "person.badge.plus", title: "New User",
                           subtitle: database, isBusy: false)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("User name") {
                        TextField("", text: $name).textFieldStyle(.roundedBorder)
                    }
                    Toggle("User without login (contained)", isOn: $withoutLogin)
                    if !withoutLogin {
                        Picker("Login", selection: $login) {
                            Text("<select>").tag("")
                            ForEach(logins, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Picker("Default schema", selection: $defaultSchema) {
                        ForEach(schemas, id: \.self) { Text($0).tag($0) }
                    }
                    Divider()
                    Text("Database roles").font(.subheadline.weight(.medium))
                    ForEach(roles, id: \.self) { role in
                        Toggle(role, isOn: Binding(
                            get: { selectedRoles.contains(role) },
                            set: { on in
                                if on { selectedRoles.insert(role) } else { selectedRoles.remove(role) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                if let errorText {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") {
                    do {
                        let script = try SecurityService.createUserScriptStatic(
                            database: database, name: name, login: login,
                            defaultSchema: defaultSchema, roles: Array(selectedRoles).sorted(),
                            withoutLogin: withoutLogin)
                        onScript(script)
                        dismiss()
                    } catch {
                        errorText = String(describing: error)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 500, height: 560)
    }
}

// MARK: - Permissions

/// The Permissions page of an object's properties in SSMS.
struct PermissionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String
    let schema: String?
    let object: String?

    @State private var entries: [PermissionEntry] = []
    @State private var principals: [String] = []
    @State private var selectedPrincipal = ""
    @State private var selectedPermissions: Set<String> = []
    @State private var withGrantOption = false
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var pendingScript: PendingScript?

    private var securableClass: String { object == nil ? "DATABASE" : "OBJECT" }

    private var securable: String? {
        guard let schema, let object else { return nil }
        return SQLIdentifier.quote(schema: schema, name: object)
    }

    private var title: String {
        guard let schema, let object else { return database }
        return "\(schema).\(object)"
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "checkmark.shield", title: "Permissions",
                           subtitle: "\(server.displayName) · \(title)", isBusy: isBusy)
            Divider()
            Table(entries) {
                TableColumn("Principal", value: \.grantee).width(160)
                TableColumn("Permission", value: \.permission).width(180)
                TableColumn("State") { entry in
                    Text(entry.stateLabel)
                        .foregroundStyle(entry.state == "D" ? Color.red : Color.primary)
                }.width(120)
                TableColumn("Securable", value: \.securableName).width(min: 140, ideal: 200)
                TableColumn("Granted by", value: \.grantor).width(120)
            }
            .frame(minHeight: 200)
            Divider()
            grantControls
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 900, height: 620)
        .task { await load() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in await apply(script) }
        }
    }

    private var grantControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Principal", selection: $selectedPrincipal) {
                    Text("<select>").tag("")
                    ForEach(principals, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 280)
                Toggle("With grant option", isOn: $withGrantOption)
                Spacer()
                ForEach(SecurityService.PermissionAction.allCases) { action in
                    Button(action.rawValue.capitalized) { build(action) }
                        .disabled(selectedPrincipal.isEmpty || selectedPermissions.isEmpty)
                }
            }

            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
                          alignment: .leading, spacing: 4) {
                    ForEach(SecurityService.grantablePermissions(for: securableClass)) { permission in
                        Toggle(permission.name, isOn: Binding(
                            get: { selectedPermissions.contains(permission.name) },
                            set: { on in
                                if on { selectedPermissions.insert(permission.name) }
                                else { selectedPermissions.remove(permission.name) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 130)
        }
        .padding(12)
    }

    private func build(_ action: SecurityService.PermissionAction) {
        let service = SecurityService(session: server.session)
        let script = service.permissionScript(
            database: database, action: action,
            permissions: Array(selectedPermissions).sorted(),
            securable: securable, principal: selectedPrincipal,
            withGrantOption: withGrantOption)
        guard !script.isEmpty else { return }
        pendingScript = PendingScript(title: "\(action.rawValue) permissions", script: script,
                                      destructive: action == .deny)
    }

    private func apply(_ script: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await SecurityService(session: server.session).execute(script, database: database)
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
        let service = SecurityService(session: server.session)
        do {
            if let schema, let object {
                entries = try await service.permissions(database: database, schema: schema,
                                                        object: object)
            } else {
                entries = []
            }
            let principalResult = try await server.session.metadataQuery(
                "SELECT name FROM sys.database_principals WHERE type NOT IN ('C','K') "
                    + "AND name NOT LIKE '##%' ORDER BY name",
                database: database)
            principals = (principalResult.resultSets.first?.dictionaries() ?? [])
                .map { $0.string("name") }
            isError = false
            status = "\(entries.count) permission entries."
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}

// MARK: - Shared pieces

struct PendingScript: Identifiable {
    let id = UUID()
    var title: String
    var script: String
    var destructive = false
}

/// Nothing in the security dialogs runs without the statement being shown first.
struct ScriptConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pending: PendingScript
    var onApply: (String) async -> Void

    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: pending.destructive
                      ? "exclamationmark.triangle.fill" : "doc.text")
                    .foregroundStyle(pending.destructive ? Color.orange : Color.accentColor)
                Text(pending.title).font(.headline)
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(pending.script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pending.script, forType: .string)
                }
                if isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(pending.destructive ? "Run anyway" : "Run") {
                    isRunning = true
                    Task {
                        await onApply(pending.script)
                        isRunning = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning)
            }
            .padding(12)
        }
        .frame(width: 640, height: 440)
    }
}

struct SecurityHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }
}

struct SecurityFooter: View {
    let status: String?
    let isError: Bool
    var onClose: () -> Void

    var body: some View {
        HStack {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}
