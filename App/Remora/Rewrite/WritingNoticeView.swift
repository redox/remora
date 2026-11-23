import Rewrite
import SwiftUI

struct WritingNoticeView: View {
    let notice: RewriteNotice
    let onAction: @MainActor (RewriteNotice.Action) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.text)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                if let detail = notice.detail {
                    Text(detail).foregroundStyle(.secondary)
                }
                if let action = notice.action, let title = notice.actionTitle {
                    Button(title) { onAction(action) }
                        .buttonStyle(.link)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
    }
}
