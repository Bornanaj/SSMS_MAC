import SwiftUI
import SQLServerKit

/// The Messages tab: PRINT output, row counts and server errors, coloured like SSMS.
struct MessagesView: View {
    let messages: [SQLMessage]
    var onSelectLine: (Int) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 2) {
                if messages.isEmpty {
                    Text("No messages.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                ForEach(messages) { message in
                    messageRow(message)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func messageRow(_ message: SQLMessage) -> some View {
        if message.kind == .error {
            VStack(alignment: .leading, spacing: 0) {
                Text(errorHeader(message))
                Text(message.text)
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Color.red)
            .contentShape(Rectangle())
            .onTapGesture {
                if message.scriptLine > 0 { onSelectLine(message.scriptLine) }
            }
            .help("Click to jump to line \(message.scriptLine)")
        } else {
            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.primary)
        }
    }

    private func errorHeader(_ message: SQLMessage) -> String {
        var header = "Msg \(message.number), Level \(message.severity), State \(message.state)"
        if !message.procedureName.isEmpty { header += ", Procedure \(message.procedureName)" }
        header += ", Line \(message.lineNumber)"
        return header
    }
}
