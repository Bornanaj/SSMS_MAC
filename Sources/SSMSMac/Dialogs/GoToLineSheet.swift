import SwiftUI
import AppKit

/// The Edit > Go To dialog. Small on purpose: it exists to get out of the way.
struct GoToLineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let lineCount: Int
    let currentLine: Int
    var onGo: (Int) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var target: Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              value >= 1, value <= lineCount else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go To Line").font(.headline)
            Text("Line number (1 – \(lineCount))")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { go() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            text = "\(currentLine)"
            focused = true
        }
    }

    private func go() {
        guard let target else { return }
        onGo(target)
        dismiss()
    }
}
