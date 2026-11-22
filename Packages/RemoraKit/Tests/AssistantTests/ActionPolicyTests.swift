import Testing
@testable import Assistant

@Suite struct ActionPolicyTests {
    @Test(arguments: [(ActionRisk.reversible, false, false), (.reversible, true, true), (.confirm, false, true),
                      (.confirm, true, true)])
    func policy(risk: ActionRisk, tainted: Bool, expected: Bool) {
        #expect(ActionPolicy.needsConfirmation(risk, turnTainted: tainted) == expected)
    }
}
