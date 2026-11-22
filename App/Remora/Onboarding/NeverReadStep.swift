import SwiftUI

/// What capture never reads, and where the user's own exclusions live.
struct NeverReadStep: View {
    let openPrivacySettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What Remora never reads").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                OnboardingBullet("Password fields, private browser windows and password managers.")
                OnboardingBullet("Banking and payment sites, and sign-in pages, from a built-in list.")
                OnboardingBullet("Card numbers, API keys, passwords and other secrets are replaced with [redacted] before anything is saved.")
                OnboardingBullet("Anything you exclude: click the dot next to the menu-bar icon and choose Never capture this app or Never capture this site.")
                OnboardingBullet("Nothing at all while capture is paused from the menu bar.")
            }
            Button("Open Privacy settings", action: openPrivacySettings)
        }
    }
}
