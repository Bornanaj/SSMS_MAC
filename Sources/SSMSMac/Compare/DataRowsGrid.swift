import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

/// Rows of one table for one outcome. Different rows show each compared column twice —
/// source and target — with the values that differ highlighted; every row has a checkbox
/// that decides whether it is deployed.
struct DataRowsGrid: NSViewRepresentable {
    let table: DataTableResult
    let status: DataRowStatus
    let onlyDifferingColumns: Bool
    let version: Int
    let font: NSFont
    let nullText: String
    let onToggle: (Int, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = ceil(font.boundingRectForFont.height) + 6
        tableView.intercellSpacing = NSSize(width: 6, height: 1)
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(Coordinator.copyRows(_:)), keyEquivalent: "").target = context.coordinator
        tableView.menu = menu
        context.coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(table: table, status: status, onlyDifferingColumns: onlyDifferingColumns,
                                   version: version, font: font, nullText: nullText, onToggle: onToggle)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        enum ColumnKind {
            case select
            case key(Int)
            case source(Int)
            case target(Int)
        }

        struct GridColumn {
            var identifier: String
            var title: String
            var kind: ColumnKind
        }

        weak var tableView: NSTableView?
        private var rows: [DataRowDifference] = []
        private var columns: [GridColumn] = []
        private var layoutSignature = ""
        private var appliedVersion = -1
        private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        private var nullText = "NULL"
        private var onToggle: (Int, Bool) -> Void = { _, _ in }
        private var tableID = ""

        func update(table: DataTableResult, status: DataRowStatus, onlyDifferingColumns: Bool, version: Int,
                    font: NSFont, nullText: String, onToggle: @escaping (Int, Bool) -> Void) {
            self.font = font
            self.nullText = nullText
            self.onToggle = onToggle
            let filtered: [DataRowDifference] = table.rows.filter { $0.status == status }
            let signature = "\(table.id)|\(status.rawValue)|\(onlyDifferingColumns)|\(table.mapping.columns.count)"
            let changedTable = tableID != table.id || layoutSignature != signature
            rows = filtered
            tableID = table.id
            if changedTable {
                layoutSignature = signature
                rebuildColumns(table: table, status: status, onlyDifferingColumns: onlyDifferingColumns)
                appliedVersion = version
                tableView?.reloadData()
            } else if appliedVersion != version {
                appliedVersion = version
                tableView?.reloadData()
            } else {
                tableView?.reloadData()
            }
        }

        private func rebuildColumns(table: DataTableResult, status: DataRowStatus, onlyDifferingColumns: Bool) {
            guard let tableView else { return }
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }
            var layout: [GridColumn] = []
            if status != .identical {
                layout.append(GridColumn(identifier: "select", title: "", kind: .select))
            }
            for (index, column) in table.mapping.keyColumns.enumerated() {
                layout.append(GridColumn(identifier: "key\(index)", title: "🔑 " + column.sourceColumn, kind: .key(index)))
            }
            let compared = table.mapping.comparedColumns
            var visible: [Int] = Array(compared.indices)
            if status == .different && onlyDifferingColumns {
                var differing: Set<Int> = []
                for row in rows { differing.formUnion(row.differingColumns) }
                visible = visible.filter { differing.contains($0) }
            }
            for index in visible {
                let name = compared[index].sourceColumn
                switch status {
                case .different:
                    layout.append(GridColumn(identifier: "s\(index)", title: "\(name) (source)", kind: .source(index)))
                    layout.append(GridColumn(identifier: "t\(index)", title: "\(name) (target)", kind: .target(index)))
                case .onlyInTarget:
                    layout.append(GridColumn(identifier: "t\(index)", title: name, kind: .target(index)))
                case .onlyInSource, .identical:
                    layout.append(GridColumn(identifier: "s\(index)", title: name, kind: .source(index)))
                }
            }
            columns = layout
            for column in layout {
                let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.identifier))
                tableColumn.title = column.title
                if case .select = column.kind {
                    tableColumn.width = 24
                    tableColumn.minWidth = 24
                    tableColumn.maxWidth = 24
                } else {
                    tableColumn.width = 150
                    tableColumn.minWidth = 50
                    tableColumn.maxWidth = 900
                }
                tableView.addTableColumn(tableColumn)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < rows.count,
                  let column = columns.first(where: { $0.identifier == tableColumn.identifier.rawValue }) else { return nil }
            let item = rows[row]
            switch column.kind {
            case .select:
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
                button.tag = row
                button.state = item.isSelected ? .on : .off
                return button
            case .key(let index):
                return cell(tableView, identifier: tableColumn.identifier,
                            value: index < item.key.count ? item.key[index] : .null, highlight: false)
            case .source(let index):
                let value = item.source.map { index < $0.count ? $0[index] : .null } ?? .null
                return cell(tableView, identifier: tableColumn.identifier, value: value,
                            highlight: item.differingColumns.contains(index))
            case .target(let index):
                let value = item.target.map { index < $0.count ? $0[index] : .null } ?? .null
                return cell(tableView, identifier: tableColumn.identifier, value: value,
                            highlight: item.differingColumns.contains(index))
            }
        }

        private func cell(_ tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier, value: TDSValue,
                          highlight: Bool) -> NSView {
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? Coordinator.makeCell(identifier: identifier)
            guard let field = view.textField else { return view }
            field.font = font
            if value.isNull {
                field.stringValue = nullText
                field.textColor = .tertiaryLabelColor
            } else {
                field.stringValue = String(value.displayString().prefix(2000))
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: "")
                field.textColor = .labelColor
            }
            view.wantsLayer = true
            view.layer?.backgroundColor = highlight
                ? NSColor.systemOrange.withAlphaComponent(0.28).cgColor
                : NSColor.clear.cgColor
            field.toolTip = field.stringValue.count > 30 ? field.stringValue : nil
            return view
        }

        private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isSelectable = true
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        @objc func toggle(_ sender: NSButton) {
            let row = sender.tag
            guard row < rows.count else { return }
            let value = sender.state == .on
            rows[row].isSelected = value
            onToggle(rows[row].id, value)
        }

        @objc func copyRows(_ sender: Any?) {
            guard let tableView else { return }
            let indexes = tableView.selectedRowIndexes.isEmpty ? IndexSet(integersIn: 0..<rows.count)
                : tableView.selectedRowIndexes
            var lines: [String] = [columns.filter { if case .select = $0.kind { return false }; return true }
                .map(\.title).joined(separator: "\t")]
            for index in indexes where index < rows.count {
                let item = rows[index]
                var fields: [String] = []
                for column in columns {
                    switch column.kind {
                    case .select: continue
                    case .key(let position):
                        fields.append(position < item.key.count ? item.key[position].displayString() : "")
                    case .source(let position):
                        fields.append(item.source.map { position < $0.count ? $0[position].displayString() : "" } ?? "")
                    case .target(let position):
                        fields.append(item.target.map { position < $0.count ? $0[position].displayString() : "" } ?? "")
                    }
                }
                lines.append(fields.joined(separator: "\t"))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }
}
