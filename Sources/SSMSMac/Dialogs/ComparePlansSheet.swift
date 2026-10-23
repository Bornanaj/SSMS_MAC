import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SQLServerKit

/// Compares two execution plans: the one in the query window against a plan opened from
/// disk or pasted in.
///
/// SSMS matches operators by node and draws both diagrams; this matches them by position
/// in the tree — a plan that gained an operator renumbers everything below it, so node
/// ids only line up when the plans already agree — and leads with the finding rather
/// than the picture: what changed, what it costs, which side won.
struct ComparePlansSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let leftXML: String

    @State private var rightXML = ""
    @State private var rightSource = "No plan loaded"
    @State private var comparison: PlanComparison?
    @State private var showUnchanged = false
    @State private var showPaste = false
    @State private var pasteBuffer = ""
    @State private var status: String?
    @State private var isError = false

    private var differences: [PlanDifference] {
        guard let comparison else { return [] }
        return showUnchanged
            ? comparison.differences
            : comparison.differences.filter { $0.change.isDifference }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "arrow.left.and.right.square",
                           title: "Compare Execution Plans",
                           subtitle: "\(title)  vs  \(rightSource)", isBusy: false)
            Divider()
            toolbar
            Divider()
            if let comparison {
                summary(comparison)
                Divider()
                differenceTable
            } else {
                ContentUnavailableView(
                    "Open a plan to compare against",
                    systemImage: "arrow.left.and.right.square",
                    description: Text("Open a .sqlplan or .xml file, or paste showplan XML. "
                                      + "The plan in this query window is the first side."))
            }
            Divider()
            footer
        }
        .frame(width: 1020, height: 680)
        .sheet(isPresented: $showPaste) { pasteSheet }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                openPlanFile()
            } label: { Label("Open Plan…", systemImage: "folder") }

            Button {
                pasteBuffer = ""
                showPaste = true
            } label: { Label("Paste XML…", systemImage: "doc.on.clipboard") }

            if comparison != nil {
                Toggle("Show unchanged operators", isOn: $showUnchanged)
                    .toggleStyle(.checkbox)
            }
            Spacer()
        }
        .padding(8)
    }

    private func summary(_ comparison: PlanComparison) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: comparison.isIdentical
                      ? "equal.circle.fill"
                      : (comparison.costDelta <= 0 ? "arrow.down.circle.fill"
                                                   : "arrow.up.circle.fill"))
                    .foregroundStyle(comparison.isIdentical ? Color.secondary
                                     : (comparison.costDelta <= 0 ? Color.green : Color.orange))
                Text(comparison.isIdentical
                     ? "The two plans are the same, operator for operator."
                     : comparison.verdict)
                    .font(.headline)
                Spacer()
            }
            HStack(spacing: 16) {
                metric("First plan cost", String(format: "%.4f", comparison.leftTotalCost))
                metric("Second plan cost", String(format: "%.4f", comparison.rightTotalCost))
                metric("Statements",
                       "\(comparison.leftStatementCount) vs \(comparison.rightStatementCount)")
                metric("Operators changed", "\(comparison.changedCount)")
                Spacer()
            }
        }
        .padding(10)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }

    private var differenceTable: some View {
        Table(differences) {
            TableColumn("") { difference in
                Image(systemName: symbol(difference.change))
                    .foregroundStyle(color(difference.change))
            }.width(24)

            TableColumn("Change") { Text($0.change.title) }.width(140)

            TableColumn("Operator") { difference in
                Text(difference.label)
                    .lineLimit(1)
                    .padding(.leading, CGFloat(difference.depth) * 10)
            }.width(min: 200, ideal: 320)

            TableColumn("Statement") { Text("\($0.statementIndex + 1)") }.width(80)

            TableColumn("Cost") { difference in
                Text(costText(difference)).monospacedDigit()
            }.width(min: 120, ideal: 170)

            TableColumn("Rows") { difference in
                Text(rowsText(difference)).monospacedDigit()
            }.width(min: 120, ideal: 170)
        }
    }

    private var footer: some View {
        HStack {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Copy Findings") { copyFindings() }
                .disabled(comparison == nil)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Paste showplan XML").font(.headline).padding(12)
            Divider()
            TextEditor(text: $pasteBuffer)
                .font(.system(.caption, design: .monospaced))
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { showPaste = false }.keyboardShortcut(.cancelAction)
                Button("Compare") {
                    load(xml: pasteBuffer, source: "pasted XML")
                    showPaste = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pasteBuffer.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
    }

    // MARK: - Actions

    private func openPlanFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // .sqlplan has no registered UTI, so the filter is by extension.
        panel.allowedContentTypes = [UTType.xml, UTType.plainText, UTType.data]
        panel.message = "Choose a .sqlplan or showplan .xml file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // SSMS writes .sqlplan as UTF-16, so the encoding is detected rather than
            // assumed; a plan copied out of a query window is usually UTF-8.
            var encoding = String.Encoding.utf8
            let text: String
            if let detected = try? String(contentsOf: url, usedEncoding: &encoding) {
                text = detected
            } else {
                let data = try Data(contentsOf: url)
                guard let decoded = String(data: data, encoding: .utf16)
                        ?? String(data: data, encoding: .utf8) else {
                    isError = true
                    status = "That file is not text this app can read."
                    return
                }
                text = decoded
            }
            load(xml: text, source: url.lastPathComponent)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func load(xml: String, source: String) {
        let parsed = ShowplanParser.parse(xml)
        guard !parsed.isEmpty else {
            isError = true
            status = "That file does not parse as a showplan."
            return
        }
        rightXML = xml
        rightSource = source
        comparison = PlanComparer.compare(leftXML: leftXML, rightXML: xml)
        isError = false
        status = comparison.map {
            $0.isIdentical ? "The plans match." : "\($0.changedCount) operators differ."
        }
    }

    private func copyFindings() {
        guard let comparison else { return }
        var lines = ["Plan comparison: \(title) vs \(rightSource)",
                     comparison.verdict,
                     String(format: "Cost %.4f → %.4f", comparison.leftTotalCost,
                            comparison.rightTotalCost),
                     ""]
        for difference in differences {
            lines.append("\(difference.change.title): \(difference.label) "
                         + "[\(costText(difference))] [\(rowsText(difference))]")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        status = "Findings copied."
        isError = false
    }

    // MARK: - Formatting

    private func costText(_ difference: PlanDifference) -> String {
        switch (difference.leftCost, difference.rightCost) {
        case (let left?, let right?):
            return String(format: "%.4f → %.4f", left, right)
        case (let left?, nil):
            return String(format: "%.4f → —", left)
        case (nil, let right?):
            return String(format: "— → %.4f", right)
        default:
            return "—"
        }
    }

    private func rowsText(_ difference: PlanDifference) -> String {
        switch (difference.leftRows, difference.rightRows) {
        case (let left?, let right?):
            return String(format: "%.0f → %.0f", left, right)
        case (let left?, nil):
            return String(format: "%.0f → —", left)
        case (nil, let right?):
            return String(format: "— → %.0f", right)
        default:
            return "—"
        }
    }

    private func symbol(_ change: PlanDifference.Change) -> String {
        switch change {
        case .unchanged: return "equal.circle"
        case .operatorChanged: return "arrow.triangle.swap"
        case .costChanged: return "dollarsign.circle"
        case .rowsChanged: return "list.number"
        case .onlyInLeft: return "minus.circle"
        case .onlyInRight: return "plus.circle"
        }
    }

    private func color(_ change: PlanDifference.Change) -> Color {
        switch change {
        case .unchanged: return .secondary
        case .operatorChanged: return .orange
        case .costChanged: return .blue
        case .rowsChanged: return .purple
        case .onlyInLeft: return .red
        case .onlyInRight: return .green
        }
    }
}
