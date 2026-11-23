import LLM
import Storage
import SwiftUI

/// The live call log: filters above a sortable table, newest first. Accounting only, no content.
struct UsageCallTable: View {
    /// The filtered rows, already capped (`UsagePresentation.tableCalls`).
    let table: (calls: [LLMCall], truncated: Bool)
    /// Every call in the range, for the job and model menus.
    let calls: [LLMCall]
    let range: UsageRange
    /// The pane's calendar and snapshot time, so "today" in the Time column matches the range.
    let calendar: Calendar
    let now: Date
    @Binding var filter: UsageFilter
    @Binding var selection: Int64?
    @State private var sortOrder = [KeyPathComparator(\Row.startedAt, order: .reverse)]

    struct Row: Identifiable {
        let call: LLMCall
        let id: Int64
        var startedAt: Date { call.startedAt }
        /// Unpriced calls sort below free ones.
        var costSortKey: Double { UsageCost.effective(call) ?? -1 }
    }

    var body: some View {
        let rows = table.calls.compactMap { c in c.id.map { Row(call: c, id: $0) } }
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 6) {
            Text("Calls").font(.headline)
            filterBar(shown: rows.count)
            // Six columns fit the narrowest Settings pane without truncating. Effort and duration
            // live in the detail block below; a completed call needs no status mark.
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.startedAt) {
                    Text(UsageLabels.time($0.startedAt, range: range, now: now, calendar: calendar)).monospacedDigit()
                }
                .width(min: 44, ideal: range == .month ? 96 : (range == .week ? 76 : 48))
                TableColumn("Job") { Text(UsageLabels.job($0.call.jobType)) }
                    .width(min: 90, ideal: 130)
                TableColumn("Model") { Text($0.call.model) }
                    .width(min: 80, ideal: 100)
                TableColumn("Tokens in → out") { Text(UsageLabels.tokens($0.call)).monospacedDigit() }
                    .width(min: 80, ideal: 96)
                TableColumn("Cost", value: \.costSortKey) { Text(cost($0.call)).monospacedDigit() }
                    .width(min: 64, ideal: 72)
                TableColumn("") { StatusCell(call: $0.call) }
                    .width(22)
            }
            .frame(height: 300)
            if table.truncated {
                Text(UsagePresentation.cappedNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func filterBar(shown: Int) -> some View {
        HStack(spacing: 8) {
            Menu(jobMenuTitle) {
                Button("All jobs") { filter = filter.selecting(category: nil) }
                Section("Categories") {
                    ForEach(UsageCategory.allCases) { c in Button(c.title) { filter = filter.selecting(category: c) } }
                }
                Section("Jobs") {
                    ForEach(jobs, id: \.self) { j in Button(UsageLabels.job(j)) { filter = filter.selecting(job: j) } }
                }
            }
            .fixedSize()
            Menu(filter.model ?? "All models") {
                Button("All models") { filter.model = nil }
                ForEach(models, id: \.self) { m in Button(m) { filter.model = m } }
            }
            .fixedSize()
            Picker("Status", selection: $filter.problemsOnly) {
                Text("All").tag(false)
                Text("Problems").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
            Text("Showing \(shown.formatted())").foregroundStyle(.secondary).monospacedDigit()
        }
        .controlSize(.small)
    }

    private var jobMenuTitle: String {
        if let job = filter.job { return UsageLabels.job(job) }
        return filter.category?.title ?? "All jobs"
    }

    private var jobs: [String] {
        Set(calls.map(\.jobType)).sorted { UsageLabels.job($0) < UsageLabels.job($1) }
    }

    private var models: [String] { Set(calls.map(\.model)).sorted() }

    private func cost(_ c: LLMCall) -> String {
        UsageCost.effective(c).map { UsageDashboard.costText($0, lowerBound: false) } ?? "—"
    }
}

/// A mark for calls that did not complete; the full status is in its tooltip and the detail block.
private struct StatusCell: View {
    let call: LLMCall

    var body: some View {
        if let (symbol, color) = mark {
            Image(systemName: symbol).foregroundStyle(color)
                .help(UsageLabels.status(call))
                .accessibilityLabel(UsageLabels.status(call))
        }
    }

    private var mark: (String, Color)? {
        if UsagePresentation.isUsageLimit(call) { return ("exclamationmark.triangle.fill", .orange) }
        switch call.status {
        case .completed: return nil
        case .failed: return ("xmark.circle.fill", .red)
        case .limit: return ("exclamationmark.triangle.fill", .orange)
        case .cancelled: return ("minus.circle", .secondary)
        }
    }
}
