import Assistant
import SwiftUI

/// "Remora wants to:" with the action's full text. The warning and summary share a bounded
/// scroll area so larger text cannot push the decision buttons or composer off the panel.
struct ConfirmationCard: View {
    let proposal: ActionProposal
    let resolve: (Bool) -> Void
    /// Past this the content scrolls (`ChatPresentation.cardSummaryMaxHeight`), so the buttons and
    /// the composer stay visible at the minimum size and the largest text.
    let summaryMaxHeight: CGFloat
    @Environment(\.chatFontSize) private var fontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remora wants to:")
                .font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    // Put the caution first: it must not start below a long action summary.
                    if proposal.afterUntrustedRead {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text("Asked after reading captured content. Check it's what you want.")
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: fontSize - 2))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(proposal.summary)
                        .font(.system(size: fontSize, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: summaryMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't allow") { resolve(false) }
                // No default-action shortcut: Return must never approve an action.
                Button("Allow") { resolve(true) }
                    .buttonStyle(.borderedProminent)
                    // Native prominent buttons use white text, so keep a sufficiently dark fill.
                    .tint(RemoraBrand.accent(.light))
            }
        }
        .padding(12)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
    }
}
