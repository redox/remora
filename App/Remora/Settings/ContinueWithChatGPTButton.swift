import LLM
import SwiftUI

/// "Continue with ChatGPT": a black capsule with white text, per OpenAI's sign-in guidelines.
/// Text only for now.
// TODO(user): add OpenAI's approved ChatGPT logo asset
struct ContinueWithChatGPTButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Continue with ChatGPT")
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(.black))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue with ChatGPT")
    }
}

/// The signed-out sign-in block shared by Settings › Account and onboarding.
struct ChatGPTSignInSection: View {
    let account: AccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch account.presentation.section {
            case .unavailable:
                Text(AccountPresentation.unavailableMessage).foregroundStyle(.orange)
                Button("Retry") { account.retry() }
            case .needsSignIn:
                Text(AccountPresentation.needsSignInMessage)
                button
            case .planUsageMissing:
                Text(AccountPresentation.planUsageMissingMessage).foregroundStyle(.orange)
                button
            case .signedOut, .signedIn:
                Text(AccountPresentation.signedOutExplainer).fixedSize(horizontal: false, vertical: true)
                button
            }
            if account.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for your browser…")
                    Button("Cancel") { account.cancelSignIn() }
                }
            }
            if let error = account.lastError { Text(error).foregroundStyle(.orange).font(.callout) }
        }
    }

    @ViewBuilder private var button: some View {
        if account.presentation.offersContinue, !account.isSigningIn {
            ContinueWithChatGPTButton { Task { await account.signIn() } }
        }
    }
}
