import AppKit
import LLM
import os
import Storage
import SwiftUI

struct UsageSettingsView: View {
    let env: AppEnvironment
    @State private var grouping: UsagePresentation.Grouping = .day
    @State private var rows: [Row] = []
    @State private var recent: [LLMCall] = []
    @State private var filter: UsagePresentation.CallFilter = .all
    @State private var lastLimitAt: Date?
    @State private var loadFailed = false
    @State private var priceError: String?

    private struct Row: Identifiable {
        let totals: UsageTotals
        var id: String { totals.key }
    }

    var body: some View {
        ScrollView {
            usageContent.padding()
        }
        .task { await reload() }
        .onChange(of: grouping) { Task { await reload() } }
    }

    private var usageContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let banner = UsagePresentation.limitBanner(lastLimitAt: lastLimitAt, now: .now) {
                Label(banner, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Picker("Group", selection: $grouping) {
                ForEach(UsagePresentation.Grouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            if loadFailed {
                Text("Usage could not be read.").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No calls yet.").foregroundStyle(.secondary)
            }
            Table(rows) {
                TableColumn(grouping.title.replacingOccurrences(of: "By ", with: "").capitalized) {
                    Text(UsagePresentation.label($0.totals.key, grouping: grouping))
                }
                TableColumn("Calls") { Text("\($0.totals.calls)").monospacedDigit() }.width(40)
                TableColumn("Input (cached)") { Text(UsagePresentation.input($0.totals)).monospacedDigit() }
                TableColumn("Output (reasoning)") { Text(UsagePresentation.output($0.totals)).monospacedDigit() }
                TableColumn("Est. cost") { Text(UsagePresentation.cost($0.totals)).monospacedDigit() }.width(80)
            }
            .frame(height: 240)
            Text(UsagePresentation.caption).font(.footnote).foregroundStyle(.secondary)
            Text(UsagePresentation.priceNote).font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Manage usage") { NSWorkspace.shared.open(SIWC.usageSettingsURL) }
                Button("Edit price table…") { editPriceTable() }
                Spacer()
                Button("Refresh") { Task { await reload() } }
            }
            if let priceError { Text(priceError).font(.footnote).foregroundStyle(.orange) }
            backgroundSection
            recentSection
        }
    }

    private var backgroundSection: some View {
        let memory = env.memory
        let pct = memory.budget > 0 ? Int((Double(memory.budgetUsed) / Double(memory.budget) * 100).rounded()) : 0
        return GroupBox("Background memory") {
            VStack(alignment: .leading, spacing: 6) {
                if let until = memory.backoffUntil {
                    Label("Background memory paused until \(until.formatted(date: Calendar.current.isDateInToday(until) ? .omitted : .abbreviated, time: .shortened)) (ChatGPT usage limit)",
                          systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Today: \(memory.budgetUsed.formatted()) of \(memory.budget.formatted()) tokens (\(pct) %)")
                    .monospacedDigit()
                ProgressView(value: Double(min(memory.budgetUsed, memory.budget)), total: Double(max(memory.budget, 1)))
                Stepper(value: Binding(get: { memory.budget }, set: { memory.setDailyBudget($0) }),
                        in: 100_000...5_000_000, step: 50_000) {
                    Text("Daily budget: \(memory.budget.formatted()) tokens").monospacedDigit()
                }
                Text("Background work stays within this daily budget so ChatGPT keeps working for you. Set Remora's app cap in ChatGPT › Settings › Usage.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { memory.refreshStatus(full: true) }
    }

    private var recentSection: some View {
        DisclosureGroup("Recent calls") {
            Picker("Show", selection: $filter) {
                ForEach(UsagePresentation.CallFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            let shown = recent.filter { UsagePresentation.matches($0, filter) }.prefix(20)
            ForEach(Array(shown), id: \.id) { call in
                HStack {
                    Text(call.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(UsagePresentation.label(call.jobType, grouping: .job))
                    Spacer()
                    Text(UsagePresentation.statusLabel(call))
                        .foregroundStyle(UsagePresentation.isUsageLimit(call) ? .orange : .secondary)
                }
                .font(.footnote)
            }
            if shown.isEmpty { Text("Nothing to show.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func reload() async {
        let store = LLMCallStore(env.db)
        let g = grouping
        let since = UsagePresentation.since(g, now: .now)
        let result = await Task.detached { () -> ([UsageTotals], [LLMCall])? in
            let grouped: UsageGrouping = switch g {
            case .day: .day(Calendar.current)
            case .job: .jobType
            case .model: .model
            }
            guard let totals = try? store.totals(grouped, since: since),
                  let recent = try? store.recent(limit: 100) else { return nil }
            return (totals, recent)
        }.value
        if let result {
            rows = result.0.map(Row.init)
            recent = result.1
            loadFailed = false
        } else {
            loadFailed = true
        }
        lastLimitAt = await env.llm.lastLimitAt()
    }

    /// Writes the template if the file is missing, then opens it in the default editor.
    private func editPriceTable() {
        let url = PriceTable.defaultURL
        if !FileManager.default.fileExists(atPath: url.path) {
            let slugs = env.account.catalog.map(\.slug)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PriceTable.template(slugs: slugs.isEmpty ? [ModelResolver.defaultLarge, "gpt-6-luna"] : slugs).write(to: url)
            } catch {
                Logger(subsystem: "dev.remora", category: "usage").error("price table template not written")
                priceError = "Could not create the price table."
                return
            }
        }
        priceError = nil
        NSWorkspace.shared.open(url)
    }
}
