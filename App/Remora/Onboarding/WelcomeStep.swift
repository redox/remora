import Lifecycle
import SwiftUI

/// What Remora is and what leaves the Mac. The privacy link is hidden until the repository is configured.
struct WelcomeStep: View {
    private let privacyURL = OnboardingFlow.privacyStatementURL(
        repository: Bundle.main.object(forInfoDictionaryKey: "RemoraRepositoryURL") as? String)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Welcome to Remora").font(.title2.bold())
            Text("Remora remembers what you read and write on this Mac and uses it to write in your voice, answer questions about your work, and give your AI tools context.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                OnboardingBullet("What Remora captures stays on this Mac, in a local database. There is no Remora server or account.")
                OnboardingBullet("AI requests go to OpenAI with your own ChatGPT account. Update checks go to GitHub; nothing else leaves your Mac.")
                OnboardingBullet("Dictation runs on this Mac by default. OpenAI transcription is optional.")
                OnboardingBullet("No analytics and no crash reports. Update checks go to GitHub.")
            }
            if let privacyURL {
                Link("Read the privacy statement", destination: privacyURL)
            }
        }
    }
}
