import Memory
import Storage
import SwiftUI

/// Settings › Memory › Chronicles: browse a day without blocking the Settings window.
struct ChronicleBrowserView: View {
    let db: AppDatabase
    let calendar: Calendar

    @State private var date = Date.now
    @State private var result: ChronicleBrowserResult?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var refreshID = 0

    private struct LoadKey: Hashable {
        var date: Date
        var calendar: Calendar
        var refresh: Int
    }
    private var isToday: Bool { calendar.isDate(date, inSameDayAs: .now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { moveDay(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous day").help("Previous day")
                DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .labelsHidden().accessibilityLabel("Chronicle date")
                Button { moveDay(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(isToday).accessibilityLabel("Next day").help("Next day")
                Button("Today") { date = .now }.disabled(isToday)
                Spacer(minLength: 0)
                Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh chronicles").help("Refresh chronicles")
            }
            .buttonStyle(.borderless)
            if loading {
                ProgressView("Loading summaries…").controlSize(.small)
            } else if loadFailed {
                HStack {
                    Text("Chronicles could not be read.").foregroundStyle(.secondary)
                    Button("Retry") { refreshID += 1 }
                }
            } else if let result {
                if result.day == nil, result.hours.isEmpty {
                    Text("Nothing summarized for this day yet.").foregroundStyle(.secondary).padding(.vertical, 8)
                }
                if let day = result.day { entry("Day", day) }
                ForEach(result.hours, id: \.periodKey) { hour in entry(Self.range(hour), hour) }
                if let week = result.week { DisclosureGroup("Week") { entry("Week", week) } }
                if let month = result.month { DisclosureGroup("Month") { entry("Month", month) } }
            }
        }
        .task(id: LoadKey(date: date, calendar: calendar, refresh: refreshID)) { await reload() }
    }

    private func entry(_ label: String, _ chronicle: Chronicle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                if chronicle.isDirty {
                    Text("Needs update").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
            }
            Text(chronicle.summary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private static func range(_ chronicle: Chronicle) -> String {
        "\(chronicle.periodStart.formatted(date: .omitted, time: .shortened))–\(chronicle.periodEnd.formatted(date: .omitted, time: .shortened))"
    }

    private func moveDay(_ offset: Int) {
        // Calendar arithmetic preserves local days through daylight-saving changes.
        if let next = calendar.date(byAdding: .day, value: offset, to: date) { date = min(next, .now) }
    }

    private func reload() async {
        guard !Task.isCancelled else { return }
        loading = true
        result = nil
        loadFailed = false
        defer { if !Task.isCancelled { loading = false } }
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { [db, date, calendar] in
                try ChronicleBrowserResult.load(db, date: date, calendar: calendar)
            }.value
            guard !Task.isCancelled else { return }
            result = loaded
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }
}
