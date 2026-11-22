import Foundation
import Testing
@testable import LLM

@Test func pkceMatchesRFC7636Vector() {
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func pkceMakeIsBase64URLOf48BytesAndConsistent() {
    let p = PKCE.make()
    #expect(p.verifier.count == 64)  // 48 bytes, base64url, no padding
    #expect(p.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    #expect(p.challenge == PKCE.challenge(for: p.verifier))
    #expect(PKCE.make().verifier != p.verifier)
}

@Test func randomTokenLengthAndAlphabet() {
    let t = RandomToken.make()
    #expect(t.count == 32)  // 24 bytes
    #expect(!t.contains("=") && !t.contains("+") && !t.contains("/"))
    #expect(RandomToken.make(bytes: 3).count == 4)
    #expect(RandomToken.make() != t)
}
