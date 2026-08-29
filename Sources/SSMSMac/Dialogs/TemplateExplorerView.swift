import SwiftUI
import AppKit
import SQLServerKit

/// Template Explorer: a category tree of T-SQL templates that open in a query window.
struct TemplateExplorerView: View {
    @EnvironmentObject var app: AppState
    @State private var selection: String?
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var matching: [TSQLTemplate] {
        guard !search.isEmpty else { return TSQLTemplateLibrary.all }
        return TSQLTemplateLibrary.all.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
        }
    }

    private var categories: [String] {
        var seen = Set<String>()
        return matching.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    private var selectedTemplate: TSQLTemplate? {
        TSQLTemplateLibrary.all.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            detail
                .frame(minWidth: 420)
        }
        .frame(minWidth: 780, minHeight: 520)
        .onAppear {
            if expanded.isEmpty { expanded = Set(TSQLTemplateLibrary.categories) }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").foregroundStyle(.tint)
                Text("Template Explorer").font(.headline)
                Spacer()
            }
            .padding(10)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search templates", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            Divider()

            List(selection: $selection) {
                ForEach(categories, id: \.self) { category in
                    Section {
                        if expanded.contains(category) || !search.isEmpty {
                            ForEach(matching.filter { $0.category == category }) { template in
                                Label(template.name, systemImage: "doc.text")
                                    .tag(template.id)
                            }
                        }
                    } header: {
                        Button {
                            if expanded.contains(category) {
                                expanded.remove(category)
                            } else {
                                expanded.insert(category)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: expanded.contains(category) || !search.isEmpty
                                      ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(category)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let template = selectedTemplate {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(template.name).font(.headline)
                        Text(template.category).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(parameterSummary(template))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                Divider()
                ScrollView {
                    Text(template.body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                Divider()
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(template.body, forType: .string)
                    }
                    Spacer()
                    Button("Insert into Current Window") { insert(template) }
                        .disabled(app.selectedTab == nil)
                    Button("Open in New Query Window") { open(template) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(app.servers.isEmpty)
                }
                .padding(10)
            }
        } else {
            ContentUnavailableView("No template selected", systemImage: "doc.text",
                                   description: Text("Pick a template to see its script."))
        }
    }

    private func parameterSummary(_ template: TSQLTemplate) -> String {
        let count = TemplateParameters.parse(template.body).count
        return count == 0 ? "" : "\(count) parameter\(count == 1 ? "" : "s")"
    }

    private func open(_ template: TSQLTemplate) {
        let server = app.currentServer
        Task {
            let tab = await app.newQueryTab(server: server,
                                            database: app.selectedTab?.database,
                                            text: template.body)
            tab.title = template.name
            tab.isDirty = false
            // SSMS opens the parameter dialog straight away when a template has fields.
            if !TemplateParameters.parse(template.body).isEmpty {
                app.activeSheet = .templateParameters(tab.id)
            }
        }
    }

    /// Replaces the selection, which is how SSMS drops a template into an open window.
    private func insert(_ template: TSQLTemplate) {
        guard let tab = app.selectedTab else { return }
        let ns = tab.text as NSString
        let range = tab.selectedRange
        if range.location <= ns.length {
            tab.text = ns.replacingCharacters(in: NSRange(location: range.location,
                                                          length: min(range.length,
                                                                      ns.length - range.location)),
                                              with: template.body)
        } else {
            tab.text += "\n" + template.body
        }
        if !TemplateParameters.parse(template.body).isEmpty {
            app.activeSheet = .templateParameters(tab.id)
        }
    }
}
