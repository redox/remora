import Foundation
import Testing
@testable import LLM

@Test(arguments: [#"{"access_token":"a","expires_in":3600,"earliest_refresh_at":"1700003240"}"#, #"{"access_token":"a","expires_in":3600,"earliest_refresh_at":1700003240}"#])
func parsesEarliestRefreshAt(_ body: String) throws {
    #expect(try TokenResponse.parse(status: 200, body: Data(body.utf8)).earliestRefreshAt == Date(timeIntervalSince1970: 1_700_003_240))
}

@Test func parsesFullResponse() throws {
    let body = #"{"access_token":"a","refresh_token":"r","id_token":"i","token_type":"Bearer","expires_in":1800,"scope":"openid email"}"#
    let t = try TokenResponse.parse(status: 200, body: Data(body.utf8))
    #expect(t == TokenResponse(accessToken: "a", refreshToken: "r", idToken: "i", expiresIn: 1800, scope: "openid email", earliestRefreshAt: nil))
}

@Test func missingExpiresInMeans3600() throws {
    let t = try TokenResponse.parse(status: 200, body: Data(#"{"access_token":"a"}"#.utf8))
    #expect(t.expiresIn == 3600 && t.refreshToken == nil && t.idToken == nil && t.scope == nil && t.earliestRefreshAt == nil)
}

@Test func unparseableEarliestRefreshAtIsNil() throws {
    let t = try TokenResponse.parse(status: 200, body: Data(#"{"access_token":"a","earliest_refresh_at":"soon"}"#.utf8))
    #expect(t.earliestRefreshAt == nil)
}

@Test(arguments: ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"])
func terminalRefreshCodes(_ code: String) {
    #expect(throws: AuthError.terminalRefresh(code)) { try TokenResponse.parse(status: 400, body: Data(#"{"error":"\#(code)"}"#.utf8)) }
}

@Test func terminalCodeInsideErrorObject() {
    #expect(throws: AuthError.terminalRefresh("refresh_token_reused")) {
        try TokenResponse.parse(status: 401, body: Data(#"{"error":{"code":"refresh_token_reused","message":"x"}}"#.utf8))
    }
}

@Test func invalidClient() {
    #expect(throws: AuthError.invalidClient) { try TokenResponse.parse(status: 401, body: Data(#"{"error":"invalid_client"}"#.utf8)) }
}

@Test func otherErrorsAreTokenEndpointErrors() {
    #expect(throws: AuthError.tokenEndpoint(status: 400, code: "invalid_request")) {
        try TokenResponse.parse(status: 400, body: Data(#"{"error":"invalid_request","error_description":"x"}"#.utf8))
    }
    #expect(throws: AuthError.tokenEndpoint(status: 500, code: nil)) { try TokenResponse.parse(status: 500, body: Data("<html>".utf8)) }
    #expect(throws: AuthError.tokenEndpoint(status: 200, code: nil)) { try TokenResponse.parse(status: 200, body: Data(#"{"token_type":"Bearer"}"#.utf8)) }
    #expect(throws: AuthError.tokenEndpoint(status: 200, code: nil)) { try TokenResponse.parse(status: 200, body: Data(#"{"access_token":""}"#.utf8)) }
}

@Test(arguments: ["1e300", "-5", "0", #""abc""#, "true", "2592001", "-1e300"])
func outOfRangeExpiresInFallsBackTo3600(_ raw: String) throws {
    let t = try TokenResponse.parse(status: 200, body: Data(#"{"access_token":"a","expires_in":\#(raw)}"#.utf8))
    #expect(t.expiresIn == 3600)
}

@Test func expiresInEdgesAndStrings() throws {
    func parse(_ raw: String) throws -> Int {
        try TokenResponse.parse(status: 200, body: Data(#"{"access_token":"a","expires_in":\#(raw)}"#.utf8)).expiresIn
    }
    #expect(try parse("1") == 1)
    #expect(try parse("2592000") == 2_592_000)
    #expect(try parse(#""1800""#) == 1800)
    #expect(try parse("1800.9") == 1800)
}

@Test func tokenResponseDescriptionsRedactSecrets() throws {
    let t = TokenResponse(accessToken: "SECRET_ACCESS", refreshToken: "SECRET_REFRESH", idToken: "SECRET_ID", expiresIn: 3600, scope: "openid", earliestRefreshAt: nil)
    for s in [String(describing: t), String(reflecting: t), "\(t)", dumped(t)] {
        #expect(!s.contains("SECRET"))
    }
    #expect(String(describing: t).contains("3600"))
}

func dumped(_ value: Any) -> String {
    var out = ""
    dump(value, to: &out)
    return out
}
