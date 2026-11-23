import Charts
import LLM
import SwiftUI

/// Stacked bars per hour (Today) or per day, coloured by category. Shows tokens instead of cost
/// when nothing in the range is priced. The legend filters the log by category.
struct UsageChart: View {
    let buckets: [UsageBucket]
    let range: UsageRange
    let domain: DateInterval
    let showsCost: Bool
    @Binding var filter: UsageFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart(buckets) { b in
                BarMark(x: .value("Time", b.start, unit: range.bucket),
                        y: .value(showsCost ? "Est. cost" : "Tokens", showsCost ? b.costUSD : Double(b.tokens)))
                    .foregroundStyle(by: .value("Category", b.category.title))
                    .opacity(filter.category == nil || filter.category == b.category ? 1 : 0.3)
            }
            .chartForegroundStyleScale(domain: UsageCategory.allCases.map(\.title),
                                       range: UsageCategory.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartXScale(domain: domain.start...domain.end)
            .chartXAxis {
                AxisMarks(values: xStride) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: xFormat)
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(showsCost ? UsageDashboard.costText(v, lowerBound: false)
                                           : UsageDashboard.compactTokens(Int(v)))
                        }
                    }
                }
            }
            .frame(height: 160)
            legend
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(UsageCategory.allCases) { c in
                Button { filter = filter.toggling(category: c) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(c.color).frame(width: 8, height: 8)
                        Text(c.title)
                            .fontWeight(filter.category == c ? .semibold : .regular)
                            .foregroundStyle(filter.category == nil || filter.category == c ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show only \(c.title.lowercased()) calls in the log")
            }
            Spacer()
            Text(showsCost ? "Est. cost" : "Tokens (no prices yet)").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private var xStride: AxisMarkValues {
        switch range {
        case .today: .stride(by: .hour, count: 3)
        case .week: .stride(by: .day)
        case .month: .stride(by: .day, count: 5)
        }
    }

    private var xFormat: Date.FormatStyle {
        switch range {
        case .today: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.month(.abbreviated).day()
        }
    }
}

extension UsageCategory {
    /// System colours, so the chart reads in light and dark mode. Orange stays free for usage limits.
    var color: Color {
        switch self {
        case .writing: .blue
        case .chat: .teal
        case .memory: .purple
        case .briefs: .pink
        }
    }
}
