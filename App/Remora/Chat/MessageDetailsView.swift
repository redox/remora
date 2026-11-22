import Assistant
import Storage
import SwiftUI

/// Per call: model, backend, tokens, estimated cost ("—" when unpriced) and time; then the tools
/// the turn used and the totals. Costs are API-equivalent estimates, not a bill.
struct MessageDetailsView: View {
    let model: ChatModel
    let turn: ChatTurn
    /// Read once when the popover opens (not on every body evaluation).
    @State private var loaded: [GeneratedBy]?

    private var calls: [GeneratedBy] { loaded ?? [] }
    private var tools: [ToolTrace] { turn.tools }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.headline)
            if loaded == nil {
                ProgressView().controlSize(.small)
            } else if calls.isEmpty {
                Text("No model calls recorded.").foregroundStyle(.secondary)
            }
            ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.model) · \(call.backend)").font(.callout.weight(.medium))
                    Text("\(call.inputTokens.formatted()) in · \(call.outputTokens.formatted()) out · "
                         + "\(ChatPresentation.cost(call.estCostUSD)) · \(call.at.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !tools.isEmpty {
                Divider()
                Text("Tools").font(.callout.weight(.medium))
                ForEach(Array(tools.enumerated()), id: \.offset) { _, t in
                    Text("\(t.ok ? "✓" : "✗") \(t.name)").font(.caption.monospaced())
                }
            }
            if calls.count > 1 {
                Divider()
                let total = ChatPresentation.totals(calls)
                Text("Total: \(total.inputTokens.formatted()) in · \(total.outputTokens.formatted()) out · "
                     + ChatPresentation.cost(total.estCostUSD) + (total.someUnpriced && total.estCostUSD != nil ? " (some calls unpriced)" : ""))
                    .font(.caption)
            }
            Text("Costs are estimates at API list prices, not a bill.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
        .task(id: turn.id) {
            loaded = nil
            let details = await model.details(for: turn)
            guard !Task.isCancelled else { return }
            loaded = details
        }
        .onAppear { model.detailsAppeared() }
        .onDisappear { model.detailsDisappeared() }
    }
}
