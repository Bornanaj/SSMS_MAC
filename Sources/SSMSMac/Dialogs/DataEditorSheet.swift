import SwiftUI
import TDSKit
import SQLServerKit

/// "Edit Top 200 Rows": an editable grid that writes changes back as targeted
/// UPDATE/INSERT/DELETE statements. Each row's statement runs in a transaction of its
/// own, the way SSMS commits a row when you leave it, so a row the server rejects is
/// reported on that row and does not hold back the others.
struct DataEditorSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String
    let schema: String
    let table: String

    @State private var editor: TableDataEditor?
    @State private var columns: [TDSColumn] = []
    @State private var rows: [EditableRow] = []
    @State private var keyColumns: [String] = []
    @State private var readOnlyReason: String?
    @State private var statusText: String?
    @State private var isError = false
    @State private var isBusy = false
    @State private var whereClause = ""
    @State private var pendingScript: String?

    private let rowLimit = 200
    /// The delete button and the error marker in front of every row.
    private let gutterWidth: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if let readOnlyReason {
                ContentUnavailableView("Read only", systemImage: "lock",
                                       description: Text(readOnlyReason))
            } else if columns.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                grid
            }
            Divider()
            footer
        }
        .frame(width: 1040, height: 640)
        .task { await load() }
        .sheet(isPresented: Binding(get: { pendingScript != nil },
                                    set: { if !$0 { pendingScript = nil } })) {
            if let script = pendingScript {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Statements to run").font(.headline).padding(12)
                    Divider()
                    ScrollView {
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    Divider()
                    HStack {
                        Spacer()
                        Button("Cancel") { pendingScript = nil }.keyboardShortcut(.cancelAction)
                        Button("Apply") {
                            pendingScript = nil
                            applyChanges()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
                .frame(width: 700, height: 520)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.pencil").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Edit Top \(rowLimit) Rows").font(.headline)
                Text("\(database).\(schema).\(table)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !keyColumns.isEmpty {
                Text("Key: \(keyColumns.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Text("WHERE").font(.caption.monospaced()).foregroundStyle(.secondary)
            TextField("optional filter", text: $whereClause)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await load() } }
            Button("Apply Filter") { Task { await load() } }
                .disabled(isBusy)
            Spacer()
            Button {
                addRow()
            } label: {
                Label("New Row", systemImage: "plus")
            }
            .disabled(readOnlyReason != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var grid: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text("")
                        .frame(width: gutterWidth, height: 24)
                    ForEach(columns, id: \.index) { column in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(column.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(column.sqlTypeName)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .frame(width: columnWidth(column), alignment: .leading)
                    }
                }
                .padding(.vertical, 3)
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                LazyVStack(spacing: 0) {
                    ForEach($rows) { $row in
                        rowView(row: $row)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(row: Binding<EditableRow>) -> some View {
        HStack(spacing: 0) {
            Button {
                row.wrappedValue.isDeleted.toggle()
            } label: {
                Image(systemName: row.wrappedValue.isDeleted ? "arrow.uturn.backward"
                      : row.wrappedValue.isNew ? "plus.circle" : "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(row.wrappedValue.isDeleted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 34)

            // The server's complaint about this row, from the last Save.
            Group {
                if let error = row.wrappedValue.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red)
                        .help(error)
                } else {
                    Color.clear
                }
            }
            .frame(width: gutterWidth - 34)

            ForEach(columns, id: \.index) { column in
                TextField("", text: Binding(
                    get: { row.wrappedValue.values[safe: column.index] ?? "" },
                    set: { newValue in row.wrappedValue.setText(newValue, column: column.index) }
                ), prompt: (row.wrappedValue.isNull[safe: column.index] ?? false) && !row.wrappedValue.isNew
                    ? Text("NULL") : nil)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 5)
                .frame(width: columnWidth(column), alignment: .leading)
                .disabled(column.isReadOnly && !row.wrappedValue.isNew)
                .foregroundStyle(column.isReadOnly ? Color.secondary : Color.primary)
            }
        }
        .frame(height: 22)
        .background(rowBackground(row.wrappedValue))
    }

    private func rowBackground(_ row: EditableRow) -> Color {
        if row.error != nil { return Color.red.opacity(0.22) }
        if row.isDeleted { return Color.red.opacity(0.15) }
        if row.isNew { return Color.green.opacity(0.12) }
        if row.isDirty { return Color.yellow.opacity(0.12) }
        return Color.clear
    }

    private func columnWidth(_ column: TDSColumn) -> CGFloat {
        let base = CGFloat(max(column.name.count, 8)) * 7.5 + 20
        return min(max(base, 90), 280)
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
            Text("\(changeCount) pending change\(changeCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Revert") { Task { await load() } }
                .disabled(changeCount == 0 || isBusy)
            Button("Script Changes") { previewScript() }
                .disabled(changeCount == 0 || isBusy)
            Button("Save") { previewScript() }
                .keyboardShortcut(.defaultAction)
                .disabled(changeCount == 0 || isBusy || readOnlyReason != nil)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var changeCount: Int {
        rows.filter { $0.isDirty || $0.isDeleted || $0.isNew }.count
    }

    // MARK: - Data

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        let editor = TableDataEditor(session: server.session, database: database,
                                     schema: schema, table: table)
        self.editor = editor
        do {
            let result = try await editor.load(top: rowLimit,
                                               whereClause: whereClause.isEmpty ? nil : whereClause,
                                               orderBy: nil)
            columns = result.columns
            keyColumns = result.keyColumns
            readOnlyReason = result.isReadOnly ? result.readOnlyReason : nil
            rows = result.rows.enumerated().map { index, values in
                EditableRow(id: index, original: values)
            }
            statusText = "\(rows.count) row\(rows.count == 1 ? "" : "s") loaded."
            isError = false
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func addRow() {
        rows.append(EditableRow(id: nextRowID(),
                                original: Array(repeating: .null, count: columns.count),
                                isNew: true))
    }

    private func nextRowID() -> Int {
        (rows.map(\.id).max() ?? -1) + 1
    }

    private func buildChanges() -> [(rowID: Int, change: TableDataEditor.RowChange)] {
        var changes: [(rowID: Int, change: TableDataEditor.RowChange)] = []
        for row in rows {
            if row.isDeleted && !row.isNew {
                changes.append((row.id, .init(kind: .delete, rowIndex: row.id,
                                              originalValues: dictionary(row.original),
                                              newValues: [:])))
                continue
            }
            if row.isNew && !row.isDeleted {
                // Only what was typed is sent; identity, default and computed columns
                // are the server's to fill in.
                changes.append((row.id, .init(kind: .insert, rowIndex: row.id, originalValues: [:],
                                              newValues: editedDictionary(row))))
                continue
            }
            if row.isDirty {
                changes.append((row.id, .init(kind: .update, rowIndex: row.id,
                                              originalValues: dictionary(row.original),
                                              newValues: editedDictionary(row))))
            }
        }
        return changes
    }

    private func dictionary(_ values: [TDSValue]) -> [String: TDSValue] {
        var result: [String: TDSValue] = [:]
        for column in columns where column.index < values.count {
            result[column.name] = values[column.index]
        }
        return result
    }

    /// The cells the user changed, and nothing else. Re-coercing every column of a
    /// dirty row turned an untouched empty Notes cell into NULL and an untouched
    /// datetime into a string, and both then went into the UPDATE.
    private func editedDictionary(_ row: EditableRow) -> [String: TDSValue] {
        var result: [String: TDSValue] = [:]
        for column in columns where row.editedColumns.contains(column.index) {
            guard column.index < row.values.count else { continue }
            if column.isReadOnly && !row.isNew { continue }
            result[column.name] = ValueCoercion.value(from: row.values[column.index], column: column,
                                                      wasNull: row.isNull[safe: column.index] ?? true)
        }
        return result
    }

    /// One transaction per row, exactly as Apply runs them.
    private func script(for changes: [(rowID: Int, change: TableDataEditor.RowChange)]) throws -> String {
        guard let editor else { return "" }
        return try changes.map { try editor.script(for: [$0.change]) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func previewScript() {
        do {
            let script = try script(for: buildChanges())
            guard !script.isEmpty else {
                statusText = "Nothing to save."
                return
            }
            pendingScript = script
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func applyChanges() {
        guard let editor else { return }
        let changes = buildChanges()
        guard !changes.isEmpty else { return }
        isBusy = true
        Task {
            var errorsByRowID: [Int: String] = [:]
            for entry in changes {
                do {
                    try await editor.apply([entry.change])
                } catch {
                    errorsByRowID[entry.rowID] = String(describing: error)
                }
            }
            let applied = changes.count - errorsByRowID.count

            // Rows the server rejected keep their edits, on top of whatever the server
            // holds now, with the complaint shown on the row.
            let rejected = rows.filter { errorsByRowID[$0.id] != nil }
            await load()
            restore(rejected, errors: errorsByRowID)

            if errorsByRowID.isEmpty {
                statusText = "\(applied) change\(applied == 1 ? "" : "s") applied."
                isError = false
            } else {
                let first = rejected.first.flatMap { errorsByRowID[$0.id] } ?? ""
                statusText = "\(applied) of \(changes.count) applied; \(errorsByRowID.count) "
                    + "row\(errorsByRowID.count == 1 ? "" : "s") rejected. "
                    + first.replacingOccurrences(of: "\n", with: " ")
                isError = true
            }
            if applied > 0 {
                await app.explorer.refreshTable(sessionID: server.id, database: database,
                                                schema: schema, table: table)
            }
            isBusy = false
        }
    }

    /// Puts rejected rows back after the grid was reloaded: a new row is appended
    /// again, an existing one has its edits laid over the row the server returned for
    /// the same key, so the next Save keys on the values the server holds now.
    private func restore(_ rejected: [EditableRow], errors: [Int: String]) {
        let keyIndexes = keyColumns.compactMap { name in
            columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.index
        }
        for var row in rejected {
            row.error = errors[row.id]
            if row.isNew {
                row.id = nextRowID()
                rows.append(row)
                continue
            }
            let match = rows.firstIndex { candidate in
                !keyIndexes.isEmpty && keyIndexes.allSatisfy { index in
                    candidate.original[safe: index] == row.original[safe: index]
                }
            }
            if let match {
                var target = rows[match]
                for column in row.editedColumns.sorted() {
                    target.setText(row.values[safe: column] ?? "", column: column)
                }
                target.isDeleted = row.isDeleted
                target.error = row.error
                rows[match] = target
            } else {
                // No longer in the loaded window; the edit stays visible rather than
                // silently disappearing, and a retry reports what the server says.
                row.id = nextRowID()
                rows.append(row)
            }
        }
    }
}

struct EditableRow: Identifiable {
    var id: Int
    var values: [String]
    /// What each cell showed when the row was loaded; a cell counts as edited while
    /// its text differs from this.
    let originalText: [String]
    var original: [TDSValue]
    var isNull: [Bool]
    var isNew = false
    var isDeleted = false
    /// Indexes of the columns the user actually changed. Only these are written.
    var editedColumns: Set<Int> = []
    /// What the server said when it rejected the row on the last Save.
    var error: String?

    init(id: Int, original: [TDSValue], isNew: Bool = false) {
        self.id = id
        self.original = original
        self.originalText = original.map { $0.isNull ? "" : $0.displayString(nullText: "") }
        self.values = originalText
        self.isNull = original.map(\.isNull)
        self.isNew = isNew
    }

    var isDirty: Bool { !editedColumns.isEmpty }

    mutating func setText(_ text: String, column: Int) {
        guard values.indices.contains(column) else { return }
        values[column] = text
        if text == (originalText[safe: column] ?? "") {
            editedColumns.remove(column)
        } else {
            editedColumns.insert(column)
        }
    }
}

/// Turns the text typed in a grid cell back into a typed value.
enum ValueCoercion {
    static func value(from text: String, column: TDSColumn, wasNull: Bool) -> TDSValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let type = column.typeInfo.dataType
        if trimmed.isEmpty {
            // The grid shows NULL and '' the same way, so an empty cell keeps whichever
            // the column held. A cleared text cell becomes '', and a cleared value of
            // any other type has nothing left to parse, so it becomes NULL.
            if wasNull { return .null }
            return type.isText ? .string(text) : .null
        }
        if trimmed.uppercased() == "NULL" && column.nullable { return .null }

        if type.isText { return .string(text) }
        if type.isBinary {
            var hex = trimmed
            if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
                guard let byte = UInt8(hex[index..<next], radix: 16) else { break }
                bytes.append(byte)
                index = next
            }
            return .binary(bytes)
        }
        if type == .uniqueIdentifier, let uuid = UUID(uuidString: trimmed) { return .uuid(uuid) }
        if type == .bit || type == .bitN {
            let truthy = ["1", "true", "yes"].contains(trimmed.lowercased())
            return .bool(truthy)
        }
        if type.isTemporal {
            // Hand the literal to the server rather than guessing a calendar here.
            return .string(trimmed)
        }
        switch type {
        case .real:
            return .float(Float(trimmed) ?? 0)
        case .float, .floatN:
            return .double(Double(trimmed) ?? 0)
        case .money, .smallMoney, .moneyN, .decimalN, .numericN, .decimalLegacy, .numericLegacy:
            let negative = trimmed.hasPrefix("-")
            let body = negative ? String(trimmed.dropFirst()) : trimmed
            let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let digits = parts.joined()
            let scale = parts.count > 1 ? parts[1].count : 0
            return .decimal(TDSDecimal(digits: digits, scale: scale, isNegative: negative))
        default:
            if let intValue = Int64(trimmed) { return .int(intValue) }
            if let doubleValue = Double(trimmed) { return .double(doubleValue) }
            return .string(trimmed)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
