import SwiftUI
import SQLServerKit

/// "Specify Values for Template Parameters". Parses `<name, type, default>` out of the
/// script, lets the user edit each value, and hands the substituted script to `onApply`.
struct TemplateParametersSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sql: String
    private let onApply: (String) -> Void
    private let defaults: [TemplateParameter]

    @State private var parameters: [TemplateParameter]
    @State private var showsPreview = true
    @FocusState private var focusedParameter: TemplateParameter.ID?

    init(sql: String, onApply: @escaping (String) -> Void) {
        self.sql = sql
        self.onApply = onApply
        let parsed: [TemplateParameter] = SQLTemplates.parameters(in: sql)
        self.defaults = parsed
        _parameters = State(initialValue: parsed)
    }

    private let nameWidth: CGFloat = 210
    private let typeWidth: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if parameters.isEmpty {
                emptyState
            } else {
                parameterGrid
                Divider()
                previewSection
            }
            Divider()
            footer
        }
        .frame(width: 660, height: parameters.isEmpty ? 240 : 580)
        .onAppear {
            focusedParameter = parameters.first?.id
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "curlybraces.square").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Specify Values for Template Parameters").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var subtitle: String {
        if parameters.isEmpty { return "No parameters found in this script" }
        let count: Int = parameters.count
        return "\(count) parameter\(count == 1 ? "" : "s") in this script"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "text.badge.checkmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("This script has no template parameters.")
                .font(.callout)
            Text(verbatim: "Template parameters use the form <name, type, default>.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Grid

    private var parameterGrid: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($parameters) { $parameter in
                        HStack(spacing: 10) {
                            Text(parameter.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: nameWidth, alignment: .leading)
                                .help(parameter.name)
                            Text(parameter.type.isEmpty ? "—" : parameter.type)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: typeWidth, alignment: .leading)
                            TextField("value", text: $parameter.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .focused($focusedParameter, equals: parameter.id)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Parameter").frame(width: nameWidth, alignment: .leading)
            Text("Type").frame(width: typeWidth, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Preview substituted script", isOn: $showsPreview)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if showsPreview {
                Divider()
                ScrollView([.vertical, .horizontal]) {
                    Text(substitutedScript)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 190)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !parameters.isEmpty {
                Button("Reset") { parameters = defaults }
                    .help("Restore every value to the template default")
                    .disabled(parameters == defaults)
            }
            Spacer()
            if parameters.isEmpty {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { apply() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - Data

    private var substitutedScript: String {
        SQLTemplates.substitute(sql, with: parameters)
    }

    private func apply() {
        onApply(substitutedScript)
        dismiss()
    }
}
