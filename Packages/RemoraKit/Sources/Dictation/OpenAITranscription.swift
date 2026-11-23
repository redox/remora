import Capture
import Foundation
import LLM

/// Optional final transcription of a completed dictation. The app decides whether the audio may be sent.
public struct OpenAITranscription: Sendable {
    public enum Failure: Error, Equatable {
        case invalidKey, invalidAudio, httpStatus(Int), emptyTranscript
    }

    private struct Response: Decodable { let text: String }

    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let maximumAudioBytes = 24 * 1024 * 1024
    private let transport: any HTTPTransport

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 15
        transport = URLSessionTransport(session: URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil))
    }

    init(transport: any HTTPTransport) { self.transport = transport }

    public static func normalizedKey(_ input: String) -> String? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 3,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return key
    }

    /// An actual, permitted window and field of the same app are required. The caller compares
    /// this identity before and after recording and invalidates it on observed context switches.
    public static func eligibleContext(_ context: WindowContext, identity: ContextIdentity, fieldPID: Int32?,
                                       policy: CapturePolicy, paused: Bool, secureInput: Bool) -> ContextIdentity? {
        guard !paused, !secureInput, identity.pid == fieldPID, identity.window != nil,
              policy.shouldCapture(context) else { return nil }
        return identity
    }

    public func transcribe(_ wav: Data, key: String) async throws -> String {
        guard let key = Self.normalizedKey(key) else { throw Failure.invalidKey }
        guard !wav.isEmpty, wav.count <= Self.maximumAudioBytes else { throw Failure.invalidAudio }
        try Task.checkCancellation()
        let boundary = UUID().uuidString
        var body = Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n" +
                         "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n" +
                         "Content-Type: audio/wav\r\n\r\n").utf8)
        body.append(wav)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try Task.checkCancellation()
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else { throw Failure.httpStatus(response.statusCode) }
        let text = try JSONDecoder().decode(Response.self, from: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyTranscript }
        return text
    }

    /// Never forward audio or the bearer key to another endpoint.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
