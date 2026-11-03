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
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// Text selection is enabled per message rather than on the scroll view: a
    /// selectable container takes the click that should jump to the error's line.
    @ViewBuilder
    private func messageRow(_ message: SQLMessage) -> some View {
        if message.kind == .error {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if message.scriptLine > 0 { onSelectLine(message.scriptLine) }
                } label: {
                    Text(errorHeader(message))
                        .underline(message.scriptLine > 0)
                }
                .buttonStyle(.plain)
                .disabled(message.scriptLine <= 0)
                .help(message.scriptLine > 0 ? "Jump to line \(message.scriptLine)" : "")
                Text(message.text)
                    .textSelection(.enabled)
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Color.red)
        } else {
            Text(message.text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Color.primary)
                .textSelection(.enabled)
        }
    }

    private func errorHeader(_ message: SQLMessage) -> String {
        var header = "Msg \(message.number), Level \(message.severity), State \(message.state)"
        if !message.procedureName.isEmpty { header += ", Procedure \(message.procedureName)" }
        header += ", Line \(message.lineNumber)"
        return header
    }
}
