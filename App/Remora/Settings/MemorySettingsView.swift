import Memory
import Storage
import SwiftUI

struct MemorySettingsView: View {
    let env: AppEnvironment

    private enum Browser: String, CaseIterable, Identifiable {
        case wiki = "Wiki", chronicles = "Chronicles", timeRules = "Time rules", notes = "Notes"
        var id: String { rawValue }
    }

    @State private var browser: Browser = .wiki

    static let retentionChoices: [(String, RetentionSetting)] = [
        ("7 days", .days(7)), ("14 days", .days(14)), ("30 days", .days(30)), ("60 days", .days(60)),
        ("90 days", .days(90)), ("180 days", .days(180)), ("1 year", .days(365)), ("Forever", .forever),
    ]

    var body: some View {
        let memory = env.memory
        Form {
            Section {
                Toggle("Build memory in the background", isOn: Binding(
                    get: { memory.enabled }, set: { memory.setEnabled($0) }))
                Picker("Memory language", selection: Binding(
                    get: { memory.language }, set: { memory.setLanguage($0) })) {
                    Text("English").tag(MemoryLanguage.en)
                    Text("Français").tag(MemoryLanguage.fr)
                }
            }
            statusSection(memory)
            Section {
                Picker("Keep raw captures for", selection: Binding(
                    get: { Self.retentionChoices.first { $0.1 == memory.retention }?.0 ?? "" },
                    set: { label in
                        if let choice = Self.retentionChoices.first(where: { $0.0 == label }) { memory.setRetention(choice.1) }
                    })) {
                    ForEach(Self.retentionChoices, id: \.0) { Text($0.0).tag($0.0) }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Older captures are deleted once they're summarized, unless a wiki fact or open item cites them.")
                    if !memory.enabled || memory.awaitingSummary > 0 {
                        Text("Raw captures are kept until memory summarizes them.")
                    }
                }
            }
            Section {
                Picker("Browse", selection: $browser) {
                    ForEach(Browser.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                if env.isDeletingAll {
                    ProgressView("Deleting memory…")
                } else {
                    switch browser {
                    case .wiki: WikiBrowserView(db: env.db)
                    case .chronicles: ChronicleBrowserView(db: env.db, calendar: memory.calendar)
                    case .timeRules: TimeRulesView(db: env.db)
                    case .notes: SavedNotesView(db: env.db)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { memory.refreshStatus(full: true) }
    }

    private func statusSection(_ memory: MemoryController) -> some View {
        Section("Status") {
            if let report = memory.lastCompaction {
                Text("Last compaction: \(report.finishedAt.formatted(.relative(presentation: .named))) · \(report.snapshotsDeleted) captures removed · \(report.pagesPruned) pages pruned")
            } else {
                Text("Compaction hasn't run yet")
            }
            Text("Database: \(Self.bytes(memory.dbSize.main)) (log \(Self.bytes(memory.dbSize.wal)))")
            let waiting = memory.counts[.pending, default: 0] + memory.counts[.running, default: 0]
            let failed = memory.counts[.failed, default: 0]
            Text("\(waiting) background jobs waiting" + (failed > 0 ? " · \(failed) failed" : ""))
            if memory.statusUnreadable {
                Text("Memory status could not be read.").font(.footnote).foregroundStyle(.orange)
            }
            LabeledContent("Semantic search") {
                switch memory.embeddingModelReady {
                case true?: Text("Ready")
                case false?:
                    HStack {
                        Text("Language model not downloaded").foregroundStyle(.secondary)
                        Button(memory.isDownloadingModel ? "Downloading…" : "Download") {
                            memory.downloadEmbeddingModel()
                        }
                        .disabled(memory.isDownloadingModel)
                    }
                case nil: Text("Checking…").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Run compaction now") { memory.runCompactionNow() }
                    .disabled(memory.runningNow.contains(.compaction) || env.isDeletingAll)
                if memory.runningNow.contains(.compaction) { ProgressView().controlSize(.small) }
            }
            if let message = memory.message { Text(message).font(.footnote).foregroundStyle(.orange) }
        }
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}
