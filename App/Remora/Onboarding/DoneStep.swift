import SwiftUI

struct DoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You're all set").font(.title2.bold())
            Text("Remora lives in the menu bar. Its memory starts empty and fills in as you work, so give it a day before asking about your week.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Tap right ⌥ in a text field to open the writing popover, or move the pointer under the notch to chat.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
