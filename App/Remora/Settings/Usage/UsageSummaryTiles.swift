import LLM
import SwiftUI

/// Est. cost, calls, tokens and problems for the selected range.
struct UsageSummaryTiles: View {
    let summary: UsageSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            UsageTile(title: "Est. cost",
                      value: UsageDashboard.costText(summary.costUSD, lowerBound: summary.unpricedCalls > 0))
            UsageTile(title: "Calls", value: summary.calls.formatted())
            UsageTile(title: "Tokens", value: UsageDashboard.compactTokens(summary.tokens))
                .help("\(summary.tokens.formatted()) tokens (input and output)")
            UsageTile(title: "Problems", value: UsageDashboard.problemsText(summary),
                      tint: summary.usageLimits + summary.failures > 0 ? .orange : .primary)
        }
    }
}

private struct UsageTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .combine)
    }
}
