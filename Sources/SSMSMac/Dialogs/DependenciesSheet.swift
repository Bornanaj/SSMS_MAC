import SwiftUI
import SQLServerKit

/// The SSMS "View Dependencies" dialog: what an object needs, and what needs it.
struct DependenciesSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String
    let schema: String
    let name: String

    private enum Direction: String, CaseIterable, Identifiable {
        case dependents
        case dependsOn
        var id: String { rawValue }
        var title: String {
            switch self {
            case .dependents: return "Objects that depend on this"
            case .dependsOn: return "Objects this depends on"
            }
        }
    }

    @State private var direction: Direction = .dependents
    @State private var rows: [ObjectDependency] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var loadedDirections: Set<Direction> = []
    @State private var cache: [Direction: [ObjectDependency]] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $direction) {
                ForEach(Direction.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .task(id: direction) { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Object Dependencies").font(.headline)
                Text("\(database).\(schema).\(name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read dependencies",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            ContentUnavailableView(
                direction == .dependents ? "Nothing depends on this object"
                                         : "This object depends on nothing",
                systemImage: "checkmark.circle",
                description: Text(direction == .dependents
                                  ? "No other object references \(schema).\(name)."
                                  : "\(schema).\(name) references no other object."))
        } else {
            Table(rows) {
                TableColumn("Schema", value: \.schema).width(100)
                TableColumn("Name", value: \.name).width(min: 140, ideal: 200)
                TableColumn("Type", value: \.kind).width(140)
                TableColumn("Dependency", value: \.dependencyType).width(150)
                TableColumn("Schema bound") { row in
                    Text(row.isSchemaBound ? "Yes" : "No")
                        .foregroundStyle(row.isSchemaBound ? Color.primary : Color.secondary)
                }.width(100)
            }
        }
    }

    private var footer: some View {
        HStack {
            if !rows.isEmpty {
                Text("\(rows.count) object\(rows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy List") {
                let text = rows.map { "\($0.schema).\($0.name)\t\($0.kind)\t\($0.dependencyType)" }
                    .joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(rows.isEmpty)
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func load() async {
        if let cached = cache[direction] {
            rows = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        let service = DependencyService(session: server.session)
        do {
            let result: [ObjectDependency]
            switch direction {
            case .dependents:
                result = try await service.dependents(database: database, schema: schema, name: name)
            case .dependsOn:
                result = try await service.dependsOn(database: database, schema: schema, name: name)
            }
            cache[direction] = result
            rows = result
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}
