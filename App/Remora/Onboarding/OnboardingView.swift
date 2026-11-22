import AppKit
import Input
import Lifecycle
import SwiftUI

/// The onboarding window's content: the current step, a step dot row, Back (hidden on welcome) and
/// the step's forward buttons. Steps with a choice keep their own buttons (sign-in "Later",
/// notifications, Done); the others share Continue, disabled while `canContinue` is false.
struct OnboardingView: View {
    let env: AppEnvironment
    let model: OnboardingModel
    let onDone: () -> Void

    private var step: OnboardingStep { model.flow.step }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 360)
        .onChange(of: env.account.presentation.isSignedInWithPlanUsage) { _, _ in model.refresh() }
        .onChange(of: env.permissions.accessibilityGranted) { _, _ in model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .accessibility: AccessibilityStep(permissions: env.permissions)
        case .neverRead: NeverReadStep(openPrivacySettings: { env.openSettings(tab: .privacy) })
        case .signIn: SignInStep(account: env.account)
        case .tryKey: TryKeyStep()
        case .dictation: DictationStep(env: env)
        case .notifications: NotificationsStep()
        case .done: DoneStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { model.back() }
            }
            Spacer()
            StepDots(steps: model.flow.visibleSteps(model.facts), current: step)
            Spacer()
            forwardButtons
        }
    }

    @ViewBuilder private var forwardButtons: some View {
        switch step {
        case .welcome:
            Button("Get started") { model.next() }.keyboardShortcut(.defaultAction)
        case .signIn:
            Button("Later") { env.account.cancelSignIn(); model.skipSignIn() }
        case .notifications:
            Button("Not now") {
                env.proactive.declineNotifications()
                model.next()
            }
            Button("Allow notifications") {
                Task {
                    // An explicit click: prompts even if onboarding is shown again later.
                    await env.proactive.requestNotifications()
                    model.next()
                }
            }
            .keyboardShortcut(.defaultAction)
        case .done:
            Button("Done") { onDone() }.keyboardShortcut(.defaultAction)
        case .accessibility:
            // "Grant Accessibility" stays the default action until access is granted.
            Button("Continue") { model.next() }.disabled(!model.flow.canContinue(model.facts))
        case .neverRead, .tryKey, .dictation:
            Button("Continue") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.flow.canContinue(model.facts))
        }
    }
}

private struct StepDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps, id: \.self) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \((steps.firstIndex(of: current) ?? 0) + 1) of \(steps.count)")
    }
}

/// A bullet row shared by the new steps.
struct OnboardingBullet: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steps carried over from the earlier onboarding (copy unchanged)

private struct AccessibilityStep: View {
    let permissions: PermissionsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remora needs Accessibility access").font(.title2.bold())
            Text("Remora reads the text of the window you are using so you can search your own work history later. Everything stays on this Mac, in a local database. Accessibility access is the only way macOS lets an app read window text.")
                .fixedSize(horizontal: false, vertical: true)
            Label("Accessibility not granted", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
            HStack {
                Button("Grant Accessibility") { permissions.requestAccessibility() }
                    .keyboardShortcut(.defaultAction)
                Button("Open System Settings") { permissions.openAccessibilitySettings() }
            }
            Text("Capture starts automatically once access is granted.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct SignInStep: View {
    let account: AccountModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Accessibility granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Sign in to use AI features").font(.title2.bold())
            ChatGPTSignInSection(account: account)
        }
    }
}

private struct TryKeyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try the key").font(.title2.bold())
            Text("Select the text in the box, then tap right ⌥. Type “Make it clearer” in the popover and press Return.")
                .fixedSize(horizontal: false, vertical: true)
            PracticeTextView(initialText: "can u send me the deck by friday? thx")
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Text("Remora keeps the practice field out of memory. It sends the text and your instruction for the edit.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct NotificationsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stay in the loop").font(.title2.bold())
            Text(NotificationsSettingsView.proactiveCaption)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can change this any time in Settings › Notifications.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The practice box: an AppKit text view, so its AX identifier is on the focused element itself
/// (the only element of Remora's UI the rewrite key reads).
private struct PracticeTextView: NSViewRepresentable {
    let initialText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        if let text = scroll.documentView as? NSTextView {
            text.string = initialText
            text.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
            text.isRichText = false
            text.allowsUndo = true
            text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false
            text.textContainerInset = NSSize(width: 4, height: 6)
            text.setAccessibilityIdentifier(FieldRefusal.practiceFieldIdentifier)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
