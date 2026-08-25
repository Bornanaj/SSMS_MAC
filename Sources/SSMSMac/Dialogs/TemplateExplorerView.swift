import AppKit
import SwiftUI
import SQLServerKit

/// Template Explorer: the category tree on the left, a monospaced preview on the right.
/// `onInsert` receives the raw template body; the caller decides where it lands (a new
/// query tab, or the caret position of the active editor).
struct TemplateExplorerView: View {
    @Environment(\.dismiss) private var dismiss

    private let onInsert: (String) -> Void

    init(onInsert: @escaping (String) -> Void) {
        self.onInsert = onInsert
    }

    @State private var search = ""
    @State private var selection: SQLTemplate.ID?
    @State private var collapsed: Set<String> = []
    @State private var statusText: String?

    private struct CategoryGroup: Identifiable {
        var category: String
        var templates: [SQLTemplate]
        var id: String { category }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                sidebar
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 420)
                detail
                    .frame(minWidth: 380)
            }
            Divider()
            footer
        }
        .frame(width: 920, height: 620)
        .onAppear {
            if selection == nil { selection = SQLTemplates.all.first?.id }
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Template Explorer").font(.headline)
                Text("\(SQLTemplates.all.count) templates in \(SQLTemplates.categories.count) categories")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Copy") {
                if let template = selectedTemplate { copyToClipboard(template.body) }
            }
            .disabled(selectedTemplate == nil)

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Insert") {
                if let template = selectedTemplate { insert(template) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTemplate == nil)
        }
        .padding(12)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if groups.isEmpty {
                VStack {
                    Spacer()
                    Text("No template matches “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                templateList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search name or script", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
            }
        }
        .padding(8)
    }

    private var templateList: some View {
        List(selection: $selection) {
            ForEach(groups) { group in
                DisclosureGroup(isExpanded: expansion(for: group.category)) {
                    ForEach(group.templates) { template in
                        row(for: template).tag(template.id)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(group.category).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(group.templates.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(for template: SQLTemplate) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.plaintext").foregroundStyle(.secondary)
            Text(template.name).lineLimit(1)
        }
        // A double click inserts, matching SSMS; the simultaneous gesture keeps the
        // single click selection behaviour of the list intact.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selection = template.id
            insert(template)
        })
        .help(template.name)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let template = selectedTemplate {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name).font(.headline)
                    Text(template.category).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)

                Divider()

                ScrollView([.vertical, .horizontal]) {
                    Text(template.body)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))

                Divider()
                parameterSummary(for: template)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Select a template to preview it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func parameterSummary(for template: SQLTemplate) -> some View {
        let parameters: [TemplateParameter] = SQLTemplates.parameters(in: template.body)
        let names: String = parameters.map(\.name).joined(separator: ", ")
        let title: String = parameters.isEmpty
            ? "No template parameters"
            : "\(parameters.count) template parameter\(parameters.count == 1 ? "" : "s")"

        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.medium))
            if !names.isEmpty {
                Text(names)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    // MARK: - Data

    private var groups: [CategoryGroup] {
        let needle: String = search.trimmingCharacters(in: .whitespaces).lowercased()
        var result: [CategoryGroup] = []
        for category in SQLTemplates.categories {
            let members: [SQLTemplate] = SQLTemplates.templates(in: category)
                .filter { matches($0, needle: needle) }
            guard !members.isEmpty else { continue }
            result.append(CategoryGroup(category: category, templates: members))
        }
        return result
    }

    private func matches(_ template: SQLTemplate, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        if template.name.lowercased().contains(needle) { return true }
        if template.category.lowercased().contains(needle) { return true }
        return template.body.lowercased().contains(needle)
    }

    private var selectedTemplate: SQLTemplate? {
        guard let selection else { return nil }
        return SQLTemplates.template(id: selection)
    }

    /// While a search is active every category stays open, otherwise the user would have
    /// to expand folders to see what they just searched for.
    private func expansion(for category: String) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || !collapsed.contains(category) },
            set: { isExpanded in
                if isExpanded {
                    collapsed.remove(category)
                } else {
                    collapsed.insert(category)
                }
            }
        )
    }

    // MARK: - Actions

    private func insert(_ template: SQLTemplate) {
        onInsert(template.body)
        dismiss()
    }

    private func copyToClipboard(_ body: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(body, forType: .string)
        statusText = "Template copied to the clipboard."
    }
}
