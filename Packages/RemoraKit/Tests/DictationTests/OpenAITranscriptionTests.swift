import Capture
import Foundation
import LLMTestSupport
import Testing
@testable import Dictation

struct OpenAITranscriptionTests {
    private let path = "/v1/audio/transcriptions"

    @Test func sendsAudioWithoutALanguageHint() async throws {
        let transport = FakeHTTPTransport()
        transport.enqueue(path, .json(200, ["text": " Bonjour ! "]))
        let client = OpenAITranscription(transport: transport)
        let audio = Data([1, 2, 3, 4])

        #expect(try await client.transcribe(audio, key: "sk-test") == "Bonjour !")

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try #require(request.httpBody)
        #expect(body.range(of: audio) != nil)
        #expect(body.range(of: Data("name=\"model\"\r\n\r\ngpt-transcribe".utf8)) != nil)
        #expect(body.range(of: Data("name=\"language".utf8)) == nil)
    }

    @Test(arguments: [401, 429, 503]) func requestFailuresAreNotRetried(_ status: Int) async {
        let transport = FakeHTTPTransport()
        transport.enqueue(path, .init(status: status))
        let client = OpenAITranscription(transport: transport)

        await #expect(throws: OpenAITranscription.Failure.httpStatus(status)) {
            try await client.transcribe(Data([0]), key: "sk-test")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func missingOrInvalidKeyCannotReachTheTransport() async {
        let transport = FakeHTTPTransport()
        let client = OpenAITranscription(transport: transport)

        await #expect(throws: OpenAITranscription.Failure.invalidKey) {
            try await client.transcribe(Data([0]), key: "sk-test\nheader")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func securePausedAndUnverifiableContextsCannotUseCloudTranscription() {
        let identity = ContextIdentity(pid: 42, window: 1, windowTitle: "Draft", url: nil, isPrivateBrowsing: false)
        let context = WindowContext(app: "Notes", bundleID: "com.apple.Notes")
        let policy = CapturePolicy(userRules: [])

        #expect(OpenAITranscription.eligibleContext(context, identity: identity, fieldPID: 42,
                                                    policy: policy, paused: false, secureInput: false) == identity)
        #expect(OpenAITranscription.eligibleContext(context, identity: identity, fieldPID: 42,
                                                    policy: policy, paused: true, secureInput: false) == nil)
        #expect(OpenAITranscription.eligibleContext(context, identity: identity, fieldPID: 42,
                                                    policy: policy, paused: false, secureInput: true) == nil)
        #expect(OpenAITranscription.eligibleContext(context, identity: identity, fieldPID: 43,
                                                    policy: policy, paused: false, secureInput: false) == nil)
        #expect(OpenAITranscription.eligibleContext(context, identity: identity, fieldPID: 42,
                                                    policy: .denyAll, paused: false, secureInput: false) == nil)
        var privateWindow = context
        privateWindow.isPrivateBrowsing = true
        #expect(OpenAITranscription.eligibleContext(privateWindow, identity: identity, fieldPID: 42,
                                                    policy: policy, paused: false, secureInput: false) == nil)
    }
}
