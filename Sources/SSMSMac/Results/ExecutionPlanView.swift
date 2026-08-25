import SwiftUI

/// Renders a SHOWPLAN tree. Not a pixel copy of the SSMS graphical plan, but it shows
/// the same information: operator, relative cost, estimated vs actual rows, and the
/// object each operator touches.
struct ExecutionPlanView: View {
    let xml: String
    @State private var statements: [PlanStatement] = []
    @State private var selected: PlanNode?
    @State private var showXML = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if statements.isEmpty {
                    ContentUnavailableView("No execution plan",
                                           systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                                           description: Text("Run the query with an execution plan enabled."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(statements) { statement in
                                statementSection(statement)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 380)

            detailPane
                .frame(minWidth: 260, idealWidth: 320)
        }
        .toolbar {
            ToolbarItem {
                Toggle("XML", isOn: $showXML)
                    .help("Show the raw showplan XML")
            }
        }
        .sheet(isPresented: $showXML) {
            VStack(alignment: .leading) {
                Text("Showplan XML").font(.headline)
                ScrollView {
                    Text(xml)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(xml, forType: .string)
                    }
                    Spacer()
                    Button("Close") { showXML = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 720, height: 520)
        }
        .onAppear { statements = ShowplanParser.parse(xml) }
        .onChange(of: xml) { _, newValue in
            statements = ShowplanParser.parse(newValue)
            selected = nil
        }
    }

    @ViewBuilder
    private func statementSection(_ statement: PlanStatement) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statement.statementText.isEmpty ? "Query" : statement.statementText)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.secondary)

            if let impact = statement.missingIndexImpact, let script = statement.missingIndexDefinition {
                missingIndexBanner(impact: impact, script: script)
            }

            if let root = statement.root {
                PlanTreeRow(node: root,
                            totalCost: max(statement.subtreeCost, root.estimatedTotalSubtreeCost),
                            depth: 0,
                            selected: $selected)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func missingIndexBanner(impact: Double, script: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Missing index (impact \(String(format: "%.1f", impact))%)")
                    .font(.callout.weight(.medium))
                Text(script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(script, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let node = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(node.physicalOp).font(.headline)
                    if node.logicalOp != node.physicalOp {
                        Text("Logical operation: \(node.logicalOp)").foregroundStyle(.secondary)
                    }
                    Divider()
                    detailRow("Estimated rows", String(format: "%.0f", node.estimateRows))
                    if let actual = node.actualRows {
                        detailRow("Actual rows", String(format: "%.0f", actual))
                    }
                    if let executions = node.actualExecutions, executions > 0 {
                        detailRow("Executions", String(format: "%.0f", executions))
                    }
                    detailRow("Estimated I/O cost", String(format: "%.6f", node.estimateIO))
                    detailRow("Estimated CPU cost", String(format: "%.6f", node.estimateCPU))
                    detailRow("Operator cost", String(format: "%.6f", node.operatorCost))
                    detailRow("Subtree cost", String(format: "%.6f", node.estimatedTotalSubtreeCost))
                    detailRow("Average row size", "\(Int(node.averageRowSize)) B")
                    if let object = node.objectName { detailRow("Object", object) }
                    if let index = node.indexName { detailRow("Index", index) }
                    if let predicate = node.predicate, !predicate.isEmpty {
                        detailBlock("Predicate", predicate)
                    }
                    if let seek = node.seekPredicate, !seek.isEmpty {
                        detailBlock("Seek predicate", seek)
                    }
                    if !node.outputList.isEmpty {
                        detailBlock("Output list", node.outputList.joined(separator: "\n"))
                    }
                    if !node.warnings.isEmpty {
                        detailBlock("Warnings", node.warnings.joined(separator: "\n"))
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("Select an operator", systemImage: "hand.tap",
                                   description: Text("Operator details appear here."))
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .font(.callout)
    }

    @ViewBuilder
    private func detailBlock(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(.secondary).font(.callout)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// Recursive operator row. This has to be its own `View` type: a function returning
/// `some View` cannot call itself.
private struct PlanTreeRow: View {
    let node: PlanNode
    let totalCost: Double
    let depth: Int
    @Binding var selected: PlanNode?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            operatorRow(node, totalCost: totalCost, depth: depth)
            ForEach(node.children) { child in
                PlanTreeRow(node: child, totalCost: totalCost, depth: depth + 1, selected: $selected)
            }
        }
    }

    @ViewBuilder
    private func operatorRow(_ node: PlanNode, totalCost: Double, depth: Int) -> some View {
        let percent = totalCost > 0 ? node.operatorCost / totalCost * 100 : 0
        HStack(spacing: 8) {
            Color.clear.frame(width: CGFloat(depth) * 18, height: 1)
            Image(systemName: node.symbol)
                .foregroundStyle(percent >= 25 ? Color.orange : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(node.physicalOp).font(.callout.weight(.medium))
                    if node.isParallel {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    }
                    if !node.warnings.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if let object = node.objectName {
                    Text(node.indexName.map { "\(object) · \($0)" } ?? object)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(rowsLabel(node))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            costBar(percent: percent)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(selected?.id == node.id ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { selected = node }
    }

    private func rowsLabel(_ node: PlanNode) -> String {
        if let actual = node.actualRows {
            return "\(Int(actual)) / \(Int(node.estimateRows.rounded())) rows"
        }
        return "\(Int(node.estimateRows.rounded())) rows"
    }

    @ViewBuilder
    private func costBar(percent: Double) -> some View {
        HStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(percent >= 25 ? Color.orange : Color.accentColor)
                        .frame(width: max(2, geometry.size.width * min(percent / 100, 1)))
                }
            }
            .frame(width: 70, height: 6)
            Text(String(format: "%.0f%%", percent))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }
}
