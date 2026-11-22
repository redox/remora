import Foundation
import Testing
@testable import LLM

@Test func parsesCallback() throws {
    #expect(try CallbackRequest.parse(requestHead: "GET /auth/callback?code=c&state=s&client_id=oaiapp_1 HTTP/1.1\r\nHost: x").get()
        == ["code": "c", "state": "s", "client_id": "oaiapp_1"])
}

@Test func parsesPercentEncodingAndEmptyValues() throws {
    #expect(try CallbackRequest.parse(requestHead: "GET /auth/callback?iss=https%3A%2F%2Fauth.openai.com&state=a%2Bb&x= HTTP/1.1\r\n\r\n").get()
        == ["iss": "https://auth.openai.com", "state": "a+b", "x": ""])
    #expect(try CallbackRequest.parse(requestHead: "GET /auth/callback HTTP/1.1\n").get() == [:])
}

@Test(arguments: [
    "GET /favicon.ico", "GET /callback?code=x", "POST /auth/callback", "POST /auth/callback?code=c&state=s HTTP/1.1",
    "GET /auth/callback/extra?code=c HTTP/1.1", "GET /auth%2Fcallback?code=c HTTP/1.1", "GET / HTTP/1.1", "HEAD /auth/callback HTTP/1.1",
])
func rejectsOtherPaths(_ head: String) {
    #expect(CallbackRequest.parse(requestHead: head) == .failure(.notFound))
}

@Test(arguments: [
    "", "garbage", "GET", "GET auth/callback?code=c HTTP/1.1", "GET /auth/callback?code=c FTP/1.0",
    "GET /auth/callback?state=a&state=b HTTP/1.1", "GET /auth/callback?code=c HTTP/1.1 extra",
    "GET http://evil/auth/callback?code=c HTTP/1.1",
])
func rejectsMalformed(_ head: String) {
    #expect(CallbackRequest.parse(requestHead: head) == .failure(.malformed))
}
