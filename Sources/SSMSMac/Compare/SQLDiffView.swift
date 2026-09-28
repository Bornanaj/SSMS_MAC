import SwiftUI
import SQLServerKit

/// Source and target scripts side by side, aligned line by line, with changed words marked
/// and next/previous difference navigation.
struct SQLDiffView: View {
    let left: String
    let right: String
    let leftTitle: String
    let rightTitle: String
    var ignoreWhitespace: Bool = true
    @ObservedObject var settings: AppSettings

    @State private var rows: [TextDiff.Row] = []
    @State private var starts: [Int] = []
    @State private var current: Int = -1
    @State private var computedFor: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            SQLDiffRowView(row: row, font: font)
                                .id(row.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: current) { _, newValue in
                    guard newValue >= 0, newValue < starts.count else { return }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(starts[newValue], anchor: .top)
                    }
                }
            }
        }
        .task(id: signature) { recompute() }
    }

    private var signature: String {
        "\(left.hashValue)|\(right.hashValue)|\(ignoreWhitespace)"
    }

    private var font: Font {
        .system(size: max(10, settings.editorFontSize - 1), design: .monospaced)
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack {
                Text(leftTitle).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            Divider().frame(height: 18)
            HStack {
                Text(rightTitle).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(differenceCountText).font(.caption).foregroundStyle(.secondary)
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Previous difference")
                .disabled(starts.isEmpty)
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Next difference")
                .disabled(starts.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var differenceCountText: String {
        if starts.isEmpty { return "No differences" }
        if current >= 0 { return "\(current + 1) of \(starts.count)" }
        return "\(starts.count) difference\(starts.count == 1 ? "" : "s")"
    }

    private func move(_ step: Int) {
        guard !starts.isEmpty else { return }
        if current < 0 {
            current = step > 0 ? 0 : starts.count - 1
        } else {
            current = (current + step + starts.count) % starts.count
        }
    }

    private func recompute() {
        guard computedFor != signature else { return }
        computedFor = signature
        let options = TextDiff.Options(ignoreWhitespace: ignoreWhitespace, ignoreCase: false, inlineHighlights: true)
        let computed: [TextDiff.Row] = TextDiff.sideBySide(left: left, right: right, options: options)
        rows = computed
        starts = TextDiff.differenceStarts(computed)
        current = -1
    }
}

/// One aligned line pair.
struct SQLDiffRowView: View {
    let row: TextDiff.Row
    let font: Font

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumber(row.leftNumber)
            text(row.left, highlights: row.leftHighlights, isLeft: true)
                .background(background(isLeft: true))
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            lineNumber(row.rightNumber)
            text(row.right, highlights: row.rightHighlights, isLeft: false)
                .background(background(isLeft: false))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(font)
            .foregroundStyle(.tertiary)
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private func text(_ line: String?, highlights: [Range<Int>], isLeft: Bool) -> some View {
        let attributed: AttributedString = SQLDiffRowView.attributed(line ?? "", highlights: highlights, isLeft: isLeft)
        return Text(attributed)
            .font(font)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func background(isLeft: Bool) -> Color {
        switch row.kind {
        case .same, .similar:
            return .clear
        case .changed:
            return Color.orange.opacity(0.14)
        case .removed:
            return isLeft ? Color.green.opacity(0.14) : Color.gray.opacity(0.08)
        case .added:
            return isLeft ? Color.gray.opacity(0.08) : Color.red.opacity(0.14)
        }
    }

    static func attributed(_ line: String, highlights: [Range<Int>], isLeft: Bool) -> AttributedString {
        guard !highlights.isEmpty else { return AttributedString(line) }
        let units: [UInt16] = Array(line.utf16)
        var result = AttributedString()
        var cursor = 0
        let mark: Color = isLeft ? Color.green.opacity(0.35) : Color.red.opacity(0.35)
        for range in highlights where range.lowerBound >= cursor && range.upperBound <= units.count {
            if range.lowerBound > cursor {
                result += AttributedString(String(decoding: units[cursor..<range.lowerBound], as: UTF16.self))
            }
            var marked = AttributedString(String(decoding: units[range], as: UTF16.self))
            marked.backgroundColor = mark
            result += marked
            cursor = range.upperBound
        }
        if cursor < units.count {
            result += AttributedString(String(decoding: units[cursor...], as: UTF16.self))
        }
        return result
    }
}
