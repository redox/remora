import LLM
import SwiftUI

/// Cost by job or by model for the range. Clicking a row filters the log; clicking it again clears it.
struct UsageBreakdownList: View {
    let rows: [UsageBreakdownRow]
    @Binding var kind: UsageBreakdownKind
    @Binding var filter: UsageFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("Breakdown", selection: $kind) {
                    Text("By job").tag(UsageBreakdownKind.job)
                    Text("By model").tag(UsageBreakdownKind.model)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Text("Click a row to filter the log.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            ForEach(rows) { row in
                Button { filter = filter.toggling(kind, key: row.key) } label: { line(row) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func line(_ row: UsageBreakdownRow) -> some View {
        let selected = (kind == .job ? filter.job : filter.model) == row.key
        return HStack(spacing: 10) {
            Text(row.label).lineLimit(1).truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: 180, alignment: .leading)
            Text(UsageDashboard.costText(row.costUSD, lowerBound: row.unpricedCalls > 0))
                .monospacedDigit().frame(width: 72, alignment: .trailing)
            ShareBar(share: row.share).frame(height: 6)
            Text("^[\(row.calls) call](inflect: true)").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(Color.accentColor).frame(width: geo.size.width * min(1, max(0, share)))
            }
        }
        .accessibilityHidden(true)
    }
}
