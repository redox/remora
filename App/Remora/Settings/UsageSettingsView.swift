import AppKit
import LLM
import Memory
import os
import Storage
import SwiftUI

/// Settings › Usage: a dashboard over the selected range above a live log of model calls.
/// `llm_calls` holds accounting only, so nothing here can show prompt or output text. The pane
/// reads stored costs; unpriced rows are backfilled off the main actor when it appears.
struct UsageSettingsView: View {
    let env: AppEnvironment
    @State private var range: UsageRange = .today
    @State private var dayStart = PeriodKey.localCalendar.startOfDay(for: .now)
    @State private var calls: [LLMCall] = []
    @State private var snapshotAt = Date.now
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var lastLimitAt: Date?
    @State private var filter = UsageFilter()
    @State private var breakdownKind: UsageBreakdownKind = .job
    @State private var selection: Int64?
    @State private var priceError: String?

    private nonisolated static let logger = Logger(subsystem: "dev.remora", category: "usage")
    private var calendar: Calendar { PeriodKey.localCalendar }

    /// The observation restarts when either changes: a new range, or midnight while the pane is open.
    private struct ObservationKey: Equatable { var range: UsageRange; var dayStart: Date }

    var body: some View {
        ScrollView {
            content.padding()
        }
        .task(id: ObservationKey(range: range, dayStart: dayStart)) { await observeCalls() }
        .task { await watchMidnight() }
        .onAppear {
            dayStart = calendar.startOfDay(for: .now)
            env.memory.refreshStatus()
            backfillUnpricedCalls()
        }
        .onChange(of: range) { selection = nil }
    }

    private var content: some View {
        let summary = UsageDashboard.summarize(calls)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(UsageRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button("Manage usage") { NSWorkspace.shared.open(SIWC.usageSettingsURL) }
            }
            if let notice = UsagePresentation.notice(backoffUntil: env.memory.backoffUntil, lastLimitAt: lastLimitAt,
                                                     now: snapshotAt) {
                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if loadFailed {
                Text(UsagePresentation.unreadable).foregroundStyle(.secondary)
            } else if loaded && calls.isEmpty {
                Text(UsagePresentation.emptyRange).foregroundStyle(.secondary)
            } else if !calls.isEmpty {
                dashboard(summary)
            }
            footer(summary)
        }
    }

    @ViewBuilder private func dashboard(_ summary: UsageSummary) -> some View {
        UsageSummaryTiles(summary: summary)
        UsageChart(buckets: UsageDashboard.buckets(calls, range: range, now: snapshotAt, calendar: calendar),
                   range: range, domain: range.chartDomain(now: snapshotAt, calendar: calendar),
                   showsCost: summary.costUSD > 0, filter: $filter)
        UsageBreakdownList(rows: UsageDashboard.breakdown(calls, by: breakdownKind), kind: $breakdownKind,
                           filter: $filter)
        UsageCallTable(calls: calls, range: range, filter: $filter, selection: $selection)
        if let selection, let call = calls.first(where: { $0.id == selection }) {
            UsageCallDetail(call: call, prices: env.prices.table())
        }
    }

    private func footer(_ summary: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(UsagePresentation.footnotes(summary, loadedCalls: calls.count), id: \.self) { Text($0) }
                }
                .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Edit price table…") { editPriceTable() }
            }
            if let priceError { Text(priceError).font(.footnote).foregroundStyle(.orange) }
        }
    }

    /// Bridges the store's background-queue observation to the main actor. Cancelling the task
    /// (range or day change, pane closed) ends the stream, which cancels the observation.
    private func observeCalls() async {
        let since = range.interval(now: .now, calendar: calendar).start
        let store = LLMCallStore(env.db)
        let snapshots = AsyncStream<[LLMCall]?> { continuation in
            let observation = store.observeCalls(
                since: since, limit: UsagePresentation.callLimit,
                onChange: { continuation.yield($0) },
                onError: { _ in continuation.yield(nil) })
            continuation.onTermination = { _ in observation.cancel() }
        }
        for await snapshot in snapshots {
            if let snapshot {
                calls = snapshot
                loadFailed = false
            } else {
                Self.logger.error("usage observation failed")
                loadFailed = true
            }
            loaded = true
            snapshotAt = .now
            lastLimitAt = await env.llm.lastLimitAt()
        }
    }

    /// "Today" and the day buckets roll over at local midnight while the pane stays open.
    private func watchMidnight() async {
        while !Task.isCancelled {
            let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))
                ?? .now.addingTimeInterval(3_600)
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            if Task.isCancelled { return }
            dayStart = calendar.startOfDay(for: .now)
        }
    }

    /// Prices calls recorded before their model had a price (for example after the price table was
    /// edited). The live observation shows the new costs; a stored cost is never rewritten.
    private func backfillUnpricedCalls() {
        let db = env.db, prices = env.prices
        Task.detached(priority: .utility) {
            do { _ = try UsageRepricer.backfill(store: LLMCallStore(db), prices: prices.table()) } catch {
                Self.logger.error("usage backfill failed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
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
                Self.logger.error("price table template not written")
                priceError = "Could not create the price table."
                return
            }
        }
        priceError = nil
        NSWorkspace.shared.open(url)
    }
}
