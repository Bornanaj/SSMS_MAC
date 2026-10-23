import SwiftUI
import SQLServerKit

/// Live Query Statistics: what each operator is doing while the query is still running.
///
/// SSMS animates the plan diagram; this shows the same numbers as a list that stays
/// readable — rows produced against rows estimated, where the time is going, and which
/// operator has already blown past its estimate.
struct LiveQueryStatsView: View {
    @ObservedObject var tab: QueryTab

    private var snapshot: LiveQuerySnapshot { tab.liveSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshot.isEmpty {
                placeholder
            } else {
                table
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if tab.isExecuting {
                    ProgressView().controlSize(.small)
                }
                item("Progress", String(format: "%.0f%%", snapshot.progress * 100))
                item("Rows produced", format(snapshot.rowsProduced))
                item("Rows estimated", format(snapshot.rowsEstimated))
                item("Logical reads", format(snapshot.logicalReads))
                item("Operators",
                     "\(snapshot.finishedOperators) of \(snapshot.operators.count) done")
                Spacer()
            }
            ProgressView(value: snapshot.progress)
                .progressViewStyle(.linear)
            Text("Progress is rows produced over rows the optimizer estimated, so a bad "
                 + "estimate makes it optimistic.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    private func item(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).monospacedDigit()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let message = tab.liveStatisticsMessage {
            ContentUnavailableView("No live statistics", systemImage: "waveform.path.ecg",
                                   description: Text(message))
        } else if tab.isExecuting {
            ContentUnavailableView("Waiting for the first sample",
                                   systemImage: "waveform.path.ecg",
                                   description: Text("Operators appear as the engine "
                                                     + "starts reporting their progress."))
        } else {
            ContentUnavailableView(
                "Live query statistics are off",
                systemImage: "waveform.path.ecg",
                description: Text("Turn them on in the Query menu, then run the query. "
                                  + "They need VIEW SERVER STATE and SQL Server 2014 or later."))
        }
    }

    private var table: some View {
        Table(snapshot.operators) {
            TableColumn("Node") { Text("\($0.nodeID)").monospacedDigit() }.width(45)

            TableColumn("Operator") { op in
                HStack(spacing: 5) {
                    Image(systemName: op.isClosed ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption2)
                        .foregroundStyle(op.isClosed ? Color.green : Color.secondary)
                    Text(op.physicalOperator).lineLimit(1)
                }
            }.width(min: 140, ideal: 200)

            TableColumn("Object") { Text($0.objectName).lineLimit(1) }.width(min: 90, ideal: 150)

            TableColumn("Progress") { op in
                HStack(spacing: 6) {
                    ProgressView(value: op.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 70)
                    Text(String(format: "%.0f%%", op.progress * 100))
                        .font(.caption2)
                        .monospacedDigit()
                }
            }.width(120)

            TableColumn("Rows") { op in
                HStack(spacing: 4) {
                    Text(format(op.rowCount)).monospacedDigit()
                    if op.isOverrun {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("Far more rows than estimated — the plan was built for "
                                  + "a much smaller result.")
                    }
                }
            }.width(110)

            TableColumn("Estimated") { Text(format($0.estimatedRows)).monospacedDigit() }
                .width(100)
            TableColumn("Elapsed") { Text($0.elapsedText).monospacedDigit() }.width(80)
            TableColumn("CPU") { Text("\($0.cpuMilliseconds) ms").monospacedDigit() }.width(80)
            TableColumn("Logical reads") { Text(format($0.logicalReads)).monospacedDigit() }
                .width(110)
            TableColumn("Threads") { Text("\($0.threadCount)").monospacedDigit() }.width(70)
        }
    }

    private func format(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
