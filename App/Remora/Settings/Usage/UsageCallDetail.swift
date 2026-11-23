import LLM
import Storage
import SwiftUI

/// The selected call: tokens, effort, backend, duration, cost calculation, what it produced (by kind
/// only) and its error code. `llm_calls` holds no prompt or output, so none can appear here.
struct UsageCallDetail: View {
    let call: LLMCall
    /// The current table: the calculation shows today's rates, while the log shows the stored cost.
    let prices: PriceTable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(UsageLabels.job(call.jobType)) · \(call.model) · \(call.startedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.headline)
            Text(UsageLabels.tokenBreakdown(call))
            Text(UsageLabels.facts(call))
            Text(UsageCost.detailLine(call, prices: prices))
            if let table = call.artifactTable {
                Text("Produced: \(UsageLabels.artifact(table: table, job: call.jobType))")
            }
            Text("Error code: \(call.errorCode ?? "—")")
        }
        .font(.callout)
        .monospacedDigit()
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
