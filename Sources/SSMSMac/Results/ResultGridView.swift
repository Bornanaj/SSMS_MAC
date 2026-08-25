import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

/// The results grid. NSTableView is used directly because SwiftUI's `Table` does not
/// stay responsive with the hundred-thousand row result sets SSMS users routinely open.
struct ResultGridView: NSViewRepresentable {
    @ObservedObject var model: ResultSetModel
    @ObservedObject var settings: AppSettings
    var onCopy: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(model: model, settings: settings) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = false
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = ceil(settings.gridFont.boundingRectForFont.height) + 6
        tableView.intercellSpacing = NSSize(width: 6, height: 1)
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        tableView.menu = context.coordinator.makeContextMenu()

        context.coordinator.tableView = tableView
        context.coordinator.rebuildColumns()

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.settings = settings
        context.coordinator.onCopy = onCopy
        guard let tableView = context.coordinator.tableView else { return }
        if context.coordinator.appliedVersion != model.version {
            context.coordinator.appliedVersion = model.version
            tableView.reloadData()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: ResultSetModel
        var settings: AppSettings
        var onCopy: (String) -> Void = { _ in }
        weak var tableView: NSTableView?
        var appliedVersion = -1

        init(model: ResultSetModel, settings: AppSettings) {
            self.model = model
            self.settings = settings
        }

        func rebuildColumns() {
            guard let tableView else { return }
            for column in tableView.tableColumns { tableView.removeTableColumn(column) }

            let rowNumberColumn = NSTableColumn(identifier: .init("__rownum"))
            rowNumberColumn.title = ""
            rowNumberColumn.width = 46
            rowNumberColumn.minWidth = 34
            rowNumberColumn.maxWidth = 90
            tableView.addTableColumn(rowNumberColumn)

            for column in model.columns {
                let identifier = NSUserInterfaceItemIdentifier("col\(column.index)")
                let tableColumn = NSTableColumn(identifier: identifier)
                tableColumn.title = column.name.isEmpty ? "(No column name)" : column.name
                tableColumn.headerToolTip = "\(column.name) — \(column.sqlTypeName)"
                tableColumn.width = Coordinator.estimatedWidth(for: column, font: settings.gridFont)
                tableColumn.minWidth = 40
                tableColumn.maxWidth = 1200
                tableView.addTableColumn(tableColumn)
            }
        }

        static func estimatedWidth(for column: TDSColumn, font: NSFont) -> CGFloat {
            let characterWidth = font.boundingRectForFont.width * 0.62
            let headerWidth = CGFloat(column.name.count) * (characterWidth + 1) + 28
            let typeWidth: CGFloat
            switch column.typeInfo.dataType {
            case .bit, .bitN: typeWidth = 40
            case .tinyInt, .smallInt, .int, .intN: typeWidth = 90
            case .bigInt: typeWidth = 130
            case .uniqueIdentifier: typeWidth = 250
            case .dateTime, .dateTime2N, .dateTimeOffsetN, .dateTimeN: typeWidth = 200
            case .dateN: typeWidth = 100
            case .timeN: typeWidth = 120
            default:
                let length = column.typeInfo.characterLength
                let characters = length < 0 ? 60 : min(max(length, 6), 60)
                typeWidth = CGFloat(characters) * characterWidth + 20
            }
            return max(70, min(420, max(headerWidth, typeWidth)))
        }

        func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let identifier = tableColumn.identifier
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? Coordinator.makeCell(identifier: identifier)

            guard let field = cell.textField else { return cell }
            field.font = settings.gridFont

            if identifier.rawValue == "__rownum" {
                field.stringValue = "\(row + 1)"
                field.alignment = .right
                field.textColor = .secondaryLabelColor
                return cell
            }

            let columnIndex = Int(identifier.rawValue.dropFirst(3)) ?? 0
            let value = model.value(row: row, column: columnIndex)
            let column = columnIndex < model.columns.count ? model.columns[columnIndex] : nil

            if value.isNull {
                field.stringValue = settings.gridNullText
                field.textColor = .tertiaryLabelColor
                field.alignment = .left
            } else {
                var text = value.displayString(nullText: settings.gridNullText)
                if text.count > settings.gridMaxCharsPerCell {
                    text = String(text.prefix(settings.gridMaxCharsPerCell))
                }
                // Grids show one line per row; embedded newlines would break alignment.
                field.stringValue = text.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: "")
                field.textColor = .labelColor
                field.alignment = (column?.typeInfo.dataType.isNumeric ?? false) ? .right : .left
            }
            field.toolTip = field.stringValue.count > 40 ? field.stringValue : nil
            return cell
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

        // MARK: Context menu

        func makeContextMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy", action: #selector(copySelection), keyEquivalent: "")
                .target = self
            menu.addItem(withTitle: "Copy with Headers", action: #selector(copySelectionWithHeaders),
                         keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Select All", action: #selector(selectAllRows), keyEquivalent: "")
                .target = self
            return menu
        }

        @objc private func copySelection() { copy(includeHeaders: false) }
        @objc private func copySelectionWithHeaders() { copy(includeHeaders: true) }

        @objc private func selectAllRows() {
            tableView?.selectAll(nil)
        }

        private func copy(includeHeaders: Bool) {
            guard let tableView else { return }
            let rows = tableView.selectedRowIndexes.isEmpty
                ? Array(0..<model.rows.count)
                : Array(tableView.selectedRowIndexes)
            let columnIndexes = Array(0..<model.columns.count)
            let slice = model.slice(rows: rows, columns: columnIndexes)

            var lines: [String] = []
            if includeHeaders { lines.append(slice.cols.map(\.name).joined(separator: "\t")) }
            for row in slice.rows {
                lines.append(row.map { value in
                    value.isNull ? "NULL" : value.displayString().replacingOccurrences(of: "\t", with: " ")
                }.joined(separator: "\t"))
            }
            let text = lines.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onCopy(text)
        }
    }
}
