import Testing
@testable import Input

private func refusal(bundleID: String? = "com.apple.TextEdit", pid: Int32 = 10, frontmost: String? = "com.apple.TextEdit",
                     role: String? = "AXTextArea", subrole: String? = nil) -> FieldRefusal? {
    FieldRefusal.check(fieldBundleID: bundleID, fieldPID: pid, frontmostBundleID: frontmost,
                       ownPID: 99, ownBundleID: "dev.remora.Remora", role: role, subrole: subrole)
}

@Test func plainFieldIsAllowed() { #expect(refusal() == nil) }

@Test func secureFieldsAreRefused() {
    #expect(refusal(role: "AXTextField", subrole: "AXSecureTextField") == .secureField)
    #expect(refusal(role: "AXSecureTextField") == .secureField)
}

@Test func passwordManagersAreRefused() {
    #expect(refusal(bundleID: "com.1password.1password") == .passwordManager)
    #expect(refusal(frontmost: "com.bitwarden.desktop") == .passwordManager)
}

@Test func ownAppIsRefused() {
    #expect(refusal(pid: 99) == .ownApp)
    #expect(refusal(frontmost: "dev.remora.Remora") == .ownApp)
}

@Test func practiceFieldIsReadableInOwnApp() {
    #expect(FocusedFieldReader.allowsOwnApp(identifier: "dev.remora.practice"))
    #expect(!FocusedFieldReader.allowsOwnApp(identifier: nil))
    #expect(!FocusedFieldReader.allowsOwnApp(identifier: "other"))
}

@Test func onlyThePracticeFieldLiftsTheOwnAppRefusal() {
    func own(_ identifier: String?, role: String? = "AXTextArea", pid: Int32 = 99) -> FieldRefusal? {
        FieldRefusal.check(fieldBundleID: "dev.remora.Remora", fieldPID: pid, frontmostBundleID: "dev.remora.Remora",
                           ownPID: 99, ownBundleID: "dev.remora.Remora", role: role, subrole: nil,
                           identifier: identifier)
    }
    #expect(own("dev.remora.practice") == nil)
    #expect(own(nil) == .ownApp)
    #expect(own("dev.remora.chat") == .ownApp)
    // The identifier only helps a field that really lives in Remora's process.
    #expect(own("dev.remora.practice", pid: 10) == .ownApp)
    // A secure field stays refused even with the practice identifier.
    #expect(own("dev.remora.practice", role: "AXSecureTextField") == .secureField)
}
