import SwiftUI
import SQLServerKit

// MARK: - Items

/// One block on the Time Line: a finished operation, a scheduled one or one running now.
struct TimeLineItem: Identifiable {
    enum Style {
        case succeeded
        case warning
        case failed
        case scheduled
        case conflict
        case running
    }

    var id: String
    var row: Int
    var start: Date
    var end: Date
    var kind: BackupActivity.Kind
    var typeCode: String
    var style: Style
    var title: String
    var detail: String
    var activityID: String?
    var jobID: String?

    /// Full backups stand tallest, then differentials, then logs, as in SQL Backup.
    var heightFraction: CGFloat {
        if style == .failed || kind == .jobFailure { return 1 }
        switch typeCode.uppercased() {
        case "I": return 0.7
        case "L": return 0.42
        default: return 1
        }
    }

    var color: Color {
        switch style {
        case .failed: return BackupColors.failure
        case .conflict: return Color.pink
        default: break
        }
        switch kind {
        case .backup: return BackupColors.backup
        case .restore: return BackupColors.restore
        case .verify: return BackupColors.verify
        case .jobFailure: return BackupColors.failure
        }
    }
}

/// Builds the Time Line's blocks from the window's history, jobs and running operations.
@MainActor
enum TimeLineBuilder {
    static func items(model: BackupWindowModel, rows: [String], start: Date, end: Date) -> [TimeLineItem] {
        var index: [String: Int] = [:]
        for (offset, name) in rows.enumerated() { index[name.lowercased()] = offset }
        var items: [TimeLineItem] = []

        for activity in model.activities {
            guard let row = index[activity.database.lowercased()] else { continue }
            guard let first = activity.started ?? activity.finished else { continue }
            let last: Date = activity.finished ?? first
            guard last >= start && first <= end else { continue }
            let style: TimeLineItem.Style = !activity.succeeded ? .failed
                : (activity.hasWarnings || activity.isDamaged ? .warning : .succeeded)
            var detail: String = "\(BackupFormat.date(first)) · \(BackupFormat.duration(activity.duration))"
            if activity.backupSize > 0 { detail += " · \(BackupFormat.size(activity.compressedSize > 0 ? activity.compressedSize : activity.backupSize))" }
            if !activity.succeeded, !activity.message.isEmpty { detail += " · \(activity.message.prefix(160))" }
            items.append(TimeLineItem(id: "a\(activity.id)", row: row, start: first, end: last, kind: activity.kind,
                                      typeCode: activity.typeCode, style: style,
                                      title: "\(activity.kindTitle): \(activity.typeTitle) of \(activity.database)",
                                      detail: detail, activityID: activity.id))
        }

        let now: Date = model.serverNow
        for progress in model.inProgress {
            guard let row = index[progress.database.lowercased()] else { continue }
            let first: Date = progress.started ?? now.addingTimeInterval(-60)
            let isRestore: Bool = progress.command.uppercased().contains("RESTORE")
            let estimate: Date = now.addingTimeInterval(max(progress.estimatedSecondsLeft, 0))
            items.append(TimeLineItem(id: "p\(progress.sessionID)", row: row, start: first, end: estimate,
                                      kind: isRestore ? .restore : .backup, typeCode: isRestore ? "D" : typeCode(of: progress.statement),
                                      style: .running,
                                      title: "\(progress.command.capitalized) of \(progress.database) — running",
                                      detail: String(format: "%.0f%% complete", progress.percentComplete), jobID: nil))
        }

        let from: Date = max(now, start)
        if from < end {
            // Log shipping copies files and raises alerts; only its backups and restores are drawn.
            for job in model.jobs where job.isEnabled && !job.name.hasPrefix("LSCopy_") && !job.name.hasPrefix("LSAlert_") {
                let names: [String] = databases(of: job, in: model.databases)
                let rowsForJob: [Int] = names.compactMap { index[$0.lowercased()] }
                guard !rowsForJob.isEmpty else { continue }
                let duration: TimeInterval = max(job.averageDuration ?? 60, 30)
                let restores: Bool = job.config?.kind == .restoreVerification || job.name.hasPrefix("LSRestore_")
                let kind: BackupActivity.Kind = restores ? .restore : .backup
                let code: String = job.config?.backup?.type.historyCode
                    ?? (job.config?.kind == .restoreVerification ? "D" : codeFromName(job.name))
                for schedule in job.schedules {
                    for date in schedule.occurrences(from: from, to: end, limit: 400) {
                        for row in rowsForJob {
                            items.append(TimeLineItem(id: "s\(job.id)-\(row)-\(date.timeIntervalSince1970)", row: row,
                                                      start: date, end: date.addingTimeInterval(duration), kind: kind,
                                                      typeCode: code, style: .scheduled, title: "\(job.name) — scheduled",
                                                      detail: "\(BackupFormat.date(date)) · \(schedule.summary)", jobID: job.id))
                        }
                    }
                }
            }
        }
        markConflicts(&items)
        return items
    }

    /// Operations planned for the same database at overlapping times are shown in pink.
    private static func markConflicts(_ items: inout [TimeLineItem]) {
        let pending: [Int] = items.indices.filter { items[$0].style == .scheduled || items[$0].style == .running }
        let byRow: [Int: [Int]] = Dictionary(grouping: pending) { items[$0].row }
        for (_, indices) in byRow {
            let sorted: [Int] = indices.sorted { items[$0].start < items[$1].start }
            guard sorted.count > 1 else { continue }
            for position in 1..<sorted.count {
                let previous: Int = sorted[position - 1]
                let current: Int = sorted[position]
                guard items[current].start < items[previous].end else { continue }
                if items[previous].style == .scheduled { items[previous].style = .conflict }
                if items[current].style == .scheduled { items[current].style = .conflict }
            }
        }
    }

    static func databases(of job: BackupJobInfo, in all: [DatabaseBackupStatus]) -> [String] {
        if let backup = job.config?.backup {
            let selection: DatabaseSelection = backup.databases
            let candidates: [String]
            switch selection.scope {
            case .selected: candidates = selection.names
            case .all: candidates = all.map(\.name)
            case .user: candidates = all.filter { !$0.isSystem }.map(\.name)
            case .system: candidates = all.filter { $0.isSystem }.map(\.name)
            }
            return candidates.filter { name in
                !selection.excluded.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
        if let restore = job.config?.restore { return [restore.sourceDatabase] }
        return job.databases.isEmpty ? [] : [job.databases]
    }

    private static func typeCode(of statement: String) -> String {
        let upper: String = statement.uppercased()
        if upper.contains("BACKUP LOG") { return "L" }
        if upper.contains("DIFFERENTIAL") { return "I" }
        return "D"
    }

    private static func codeFromName(_ name: String) -> String {
        let upper: String = name.uppercased()
        // Log shipping jobs (LSBackup_, LSRestore_) back up and restore logs.
        if upper.contains("LOG") || upper.hasPrefix("LS") { return "L" }
        if upper.contains("DIFF") { return "I" }
        return "D"
    }
}

// MARK: - Geometry

/// Maps times to x positions for the visible window.
struct TimeLineScale {
    var start: Date
    var end: Date
    var width: CGFloat

    func x(_ date: Date) -> CGFloat {
        let span: TimeInterval = max(end.timeIntervalSince(start), 1)
        return CGFloat(date.timeIntervalSince(start) / span) * width
    }

    func date(atX x: CGFloat) -> Date {
        start.addingTimeInterval(Double(x / max(width, 1)) * end.timeIntervalSince(start))
    }

    /// A tick interval leaving at least ~80 points between labels.
    var tickStep: TimeInterval {
        let candidates: [TimeInterval] = [300, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800]
        let span: TimeInterval = end.timeIntervalSince(start)
        let wanted: TimeInterval = span / Double(max(width / 80, 1))
        return candidates.first { $0 >= wanted } ?? 604_800
    }

    var ticks: [Date] {
        let step: TimeInterval = tickStep
        var value: TimeInterval = (start.timeIntervalSince1970 / step).rounded(.up) * step
        var result: [Date] = []
        while value <= end.timeIntervalSince1970 && result.count < 200 {
            result.append(Date(timeIntervalSince1970: value))
            value += step
        }
        return result
    }

    func label(_ date: Date) -> String {
        let step: TimeInterval = tickStep
        let parts = ServerTime.calendar.dateComponents([.hour, .minute], from: date)
        if step >= 86_400 || (parts.hour == 0 && parts.minute == 0) { return ServerTime.format(date, "d MMM") }
        return ServerTime.format(date, "HH:mm")
    }
}

// MARK: - View

/// SQL Backup's Time Line: a row per database, past operations as solid blocks (green backups,
/// blue restores, red failures), scheduled ones hollow, running ones striped, conflicts in pink
/// and the current time as a yellow line.
struct BackupTimeLineView: View {
    @ObservedObject var model: BackupWindowModel

    enum Zoom: Double, CaseIterable, Identifiable {
        case hour = 1
        case sixHours = 6
        case halfDay = 12
        case day = 24
        case threeDays = 72
        case week = 168
        case twoWeeks = 336
        case month = 744
        var id: Double { rawValue }

        var title: String {
            switch self {
            case .hour: return "1 hour"
            case .sixHours: return "6 hours"
            case .halfDay: return "12 hours"
            case .day: return "1 day"
            case .threeDays: return "3 days"
            case .week: return "1 week"
            case .twoWeeks: return "2 weeks"
            case .month: return "1 month"
            }
        }
    }

    @State private var zoom: Zoom = .day
    /// Seconds the window is moved from its default position (negative is the past).
    @State private var pan: TimeInterval = 0
    @State private var dragStartPan: TimeInterval?
    @State private var hovered: TimeLineItem?

    private let labelWidth: CGFloat = 170
    private let rowHeight: CGFloat = 24
    private let headerHeight: CGFloat = 20

    private var span: TimeInterval { zoom.rawValue * 3600 }
    private var windowEnd: Date { model.serverNow.addingTimeInterval(span * 0.25 + pan) }
    private var windowStart: Date { windowEnd.addingTimeInterval(-span) }

    private var rows: [String] {
        if let selected = model.selectedDatabase { return [selected] }
        return model.filteredDatabases.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            GeometryReader { proxy in
                let plotWidth: CGFloat = max(proxy.size.width - labelWidth - 12, 50)
                let scale = TimeLineScale(start: windowStart, end: windowEnd, width: plotWidth)
                let items: [TimeLineItem] = TimeLineBuilder.items(model: model, rows: rows, start: windowStart, end: windowEnd)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: labelWidth, height: headerHeight)
                        TimeLineHeader(scale: scale, now: model.serverNow).frame(width: plotWidth, height: headerHeight)
                        Spacer(minLength: 0)
                    }
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            rowLabels
                            rowsCanvas(scale: scale, items: items, plotWidth: plotWidth)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Divider()
            hoverLine
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Text("Time Line").font(.headline)
            Spacer()
            legend
            Divider().frame(height: 16)
            Button { pan -= span / 2 } label: { Image(systemName: "chevron.left") }
                .help("Earlier")
            Button("Now") { pan = 0 }
                .help("Back to the current time")
            Button { pan += span / 2 } label: { Image(systemName: "chevron.right") }
                .help("Later (scheduled jobs)")
            Picker("Zoom", selection: $zoom) {
                ForEach(Zoom.allCases) { zoom in Text(zoom.title).tag(zoom) }
            }
            .labelsHidden()
            .frame(width: 110)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            LegendSwatch(color: BackupColors.backup, title: "Backup")
            LegendSwatch(color: BackupColors.restore, title: "Restore")
            LegendSwatch(color: BackupColors.failure, title: "Failed")
            LegendSwatch(color: BackupColors.backup, title: "Scheduled", hollow: true)
            LegendSwatch(color: Color.pink, title: "Conflict")
        }
        .font(.caption)
    }

    private var rowLabels: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { offset, name in
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    .background(offset % 2 == 0 ? Color.clear : Color.secondary.opacity(0.06))
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedDatabase = model.selectedDatabase == name ? nil : name }
                    .help(model.selectedDatabase == name ? "Show every database" : "Show only \(name)")
            }
        }
    }

    private func rowsCanvas(scale: TimeLineScale, items: [TimeLineItem], plotWidth: CGFloat) -> some View {
        let height: CGFloat = max(CGFloat(rows.count) * rowHeight, rowHeight)
        let now: Date = model.serverNow
        let hoveredID: String? = hovered?.id
        return Canvas { context, size in
            TimeLineRenderer(scale: scale, rowHeight: rowHeight, rowCount: rows.count, now: now, hoveredID: hoveredID)
                .draw(items: items, in: &context, size: size)
        }
        .frame(width: plotWidth, height: height)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location): hovered = hit(items: items, scale: scale, at: location)
            case .ended: hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { location in
            guard let item = hit(items: items, scale: scale, at: location) else { return }
            if let activityID = item.activityID {
                model.selectedActivityID = activityID
                model.tab = .activity
            } else if let jobID = item.jobID {
                model.selectedJobID = jobID
                model.tab = .jobs
            } else if item.style == .running {
                model.tab = .inProgress
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    let base: TimeInterval = dragStartPan ?? pan
                    if dragStartPan == nil { dragStartPan = pan }
                    let seconds: TimeInterval = Double(value.translation.width / max(plotWidth, 1)) * span
                    pan = base - seconds
                }
                .onEnded { _ in dragStartPan = nil }
        )
    }

    private func hit(items: [TimeLineItem], scale: TimeLineScale, at point: CGPoint) -> TimeLineItem? {
        let row: Int = Int(point.y / rowHeight)
        let candidates: [TimeLineItem] = items.filter { $0.row == row }
        return candidates.last { item in
            let left: CGFloat = scale.x(item.start) - 3
            let right: CGFloat = max(scale.x(item.end), scale.x(item.start) + 4) + 3
            return point.x >= left && point.x <= right
        }
    }

    private var hoverLine: some View {
        HStack(spacing: 6) {
            if let hovered {
                Circle().fill(hovered.color).frame(width: 8, height: 8)
                Text(hovered.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(hovered.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(ServerTime.display(windowStart)) – \(ServerTime.display(windowEnd)) (server time). "
                     + "Drag to scroll; click a block to see it below.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

struct LegendSwatch: View {
    let color: Color
    let title: String
    var hollow = false

    var body: some View {
        HStack(spacing: 4) {
            if hollow {
                RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 1.5).frame(width: 10, height: 10)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            }
            Text(title).foregroundStyle(.secondary)
        }
    }
}

struct TimeLineHeader: View {
    let scale: TimeLineScale
    let now: Date

    var body: some View {
        Canvas { context, size in
            for tick in scale.ticks {
                let x: CGFloat = scale.x(tick)
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 5))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                context.draw(Text(scale.label(tick)).font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: x, y: 1), anchor: .top)
            }
            let nowX: CGFloat = scale.x(now)
            if nowX >= 0 && nowX <= size.width {
                context.draw(Text("Now").font(.caption2.weight(.semibold)).foregroundColor(.yellow),
                             at: CGPoint(x: nowX, y: size.height), anchor: .bottom)
            }
        }
    }
}

/// Draws the rows; kept apart from the view so the Canvas closure stays small.
struct TimeLineRenderer {
    let scale: TimeLineScale
    let rowHeight: CGFloat
    let rowCount: Int
    let now: Date
    let hoveredID: String?

    func draw(items: [TimeLineItem], in context: inout GraphicsContext, size: CGSize) {
        for row in 0..<rowCount where row % 2 == 1 {
            let band = CGRect(x: 0, y: CGFloat(row) * rowHeight, width: size.width, height: rowHeight)
            context.fill(Path(band), with: .color(.secondary.opacity(0.06)))
        }
        for tick in scale.ticks {
            let x: CGFloat = scale.x(tick)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
        // Scheduled first, so finished work drawn on top stays readable.
        let ordered: [TimeLineItem] = items.sorted { order($0.style) < order($1.style) }
        for item in ordered { draw(item, in: &context) }
        let nowX: CGFloat = scale.x(now)
        if nowX >= 0 && nowX <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: nowX, y: 0))
            line.addLine(to: CGPoint(x: nowX, y: size.height))
            context.stroke(line, with: .color(.yellow), lineWidth: 2)
        }
    }

    private func order(_ style: TimeLineItem.Style) -> Int {
        switch style {
        case .scheduled, .conflict: return 0
        case .succeeded, .warning: return 1
        case .running: return 2
        case .failed: return 3
        }
    }

    private func draw(_ item: TimeLineItem, in context: inout GraphicsContext) {
        let inner: CGFloat = rowHeight - 6
        let height: CGFloat = max(inner * item.heightFraction, 5)
        let left: CGFloat = scale.x(item.start)
        let width: CGFloat = max(scale.x(item.end) - left, 4)
        let rect = CGRect(x: left, y: CGFloat(item.row) * rowHeight + 3 + (inner - height), width: width, height: height)
        let shape = Path(roundedRect: rect, cornerRadius: 2)
        switch item.style {
        case .scheduled:
            context.stroke(shape, with: .color(item.color), lineWidth: 1.5)
        case .conflict:
            context.fill(shape, with: .color(item.color.opacity(0.35)))
            context.stroke(shape, with: .color(item.color), lineWidth: 1.5)
        case .running:
            context.fill(shape, with: .color(item.color.opacity(0.35)))
            var stripes = Path()
            var x: CGFloat = rect.minX - rect.height
            while x < rect.maxX {
                stripes.move(to: CGPoint(x: x, y: rect.maxY))
                stripes.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 6
            }
            var clipped = context
            clipped.clip(to: shape)
            clipped.stroke(stripes, with: .color(item.color), lineWidth: 2)
        case .warning:
            context.fill(shape, with: .color(item.color))
            context.stroke(shape, with: .color(.orange), lineWidth: 2)
        case .succeeded, .failed:
            context.fill(shape, with: .color(item.color))
        }
        if item.id == hoveredID {
            context.stroke(Path(roundedRect: rect.insetBy(dx: -2, dy: -2), cornerRadius: 3), with: .color(.primary), lineWidth: 1.5)
        }
    }
}
