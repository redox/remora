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
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Time", value: \.startedAt) { Text($0.startedAt, format: timeFormat).monospacedDigit() }
                    .width(min: 48, ideal: range == .today ? 56 : 96)
                TableColumn("Job") { Text(UsageLabels.job($0.call.jobType)) }
                    .width(min: 80, ideal: 120)
                TableColumn("Model") { Text(UsageLabels.model($0.call)) }
                    .width(min: 80, ideal: 130)
                TableColumn("Tokens in → out") { Text(UsageLabels.tokens($0.call)).monospacedDigit() }
                    .width(min: 70, ideal: 100)
                TableColumn("Duration") { Text(UsageLabels.duration(ms: $0.call.durationMs)).monospacedDigit() }
                    .width(min: 44, ideal: 56)
                TableColumn("Cost", value: \.costSortKey) { Text(cost($0.call)).monospacedDigit() }
                    .width(min: 48, ideal: 64)
                TableColumn("Status") { StatusCell(call: $0.call) }
                    .width(min: 48, ideal: 80)
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

    private var timeFormat: Date.FormatStyle {
        range == .today ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
    }

    private func cost(_ c: LLMCall) -> String {
        UsageCost.effective(c).map { UsageDashboard.costText($0, lowerBound: false) } ?? "—"
    }
}

private struct StatusCell: View {
    let call: LLMCall

    var body: some View {
        if UsagePresentation.isUsageLimit(call) {
            Text(UsageLabels.status(call)).foregroundStyle(.orange)
        } else if call.status == .completed {
            Image(systemName: "checkmark").foregroundStyle(.secondary)
                .accessibilityLabel(UsageLabels.status(call))
        } else if call.status == .failed {
            Text(UsageLabels.status(call)).foregroundStyle(.red)
        } else {
            Text(UsageLabels.status(call)).foregroundStyle(.secondary)
        }
    }
}
