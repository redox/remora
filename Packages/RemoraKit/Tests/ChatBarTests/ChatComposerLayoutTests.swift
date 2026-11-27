import ChatBar
import SwiftUI
import Testing

@MainActor
@Test func composerMovesControlsBelowHardBreaksAndWrappedText() {
    func height(_ draft: String, width: CGFloat, fontSize: CGFloat = 15) -> CGFloat {
        let view = ChatComposerLayout {
            TextField("Ask Remora", text: .constant(draft), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .lineLimit(1...6)
            Color.clear.frame(width: 76, height: 36)
        }
        .frame(width: width)
        return NSHostingView(rootView: view).fittingSize.height
    }

    let sentence = "Give me a short summary of the changes we discussed."
    #expect(height("", width: 320) == 36)
    #expect(height(sentence, width: 720) == 36)
    #expect(height("First line\nSecond line", width: 720) > 36 + 30)
    #expect(height(sentence, width: 320) > 36 + 16)
    #expect(height("Hi", width: 320, fontSize: 21.5) == 36)
    #expect(height("Hi\n", width: 320, fontSize: 21.5) > 36 + 40)
    let sixLines = Array(repeating: "Line", count: 6).joined(separator: "\n")
    #expect(height(sixLines + "\nOne more", width: 320) == height(sixLines, width: 320))
}
