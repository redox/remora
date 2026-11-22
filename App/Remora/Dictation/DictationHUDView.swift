import Dictation
import SwiftUI

/// Transient dictation notices. Live speech is previewed in the writing popover.
struct DictationHUDView: View {
    let controller: DictationController

    var body: some View {
        Group {
            if case .message(let notice) = controller.phase { noticeRow(notice) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: DictationHUDPanel.width, height: DictationHUDPanel.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func noticeRow(_ notice: DictationNotice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "fish").foregroundStyle(.orange)
            Text(notice.text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(Self.title(action)) { controller.perform(action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { controller.dismissMessage() }
    }

    private static func title(_ action: NoticeAction) -> String {
        switch action {
        case .openMicrophoneSettings: "Open System Settings"
        case .openDictationSettings: "Settings…"
        }
    }
}
