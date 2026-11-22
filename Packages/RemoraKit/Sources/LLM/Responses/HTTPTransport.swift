import Foundation

/// Everything the LLM layer sends over HTTP goes through this, so tests can swap in a fake.
public protocol HTTPTransport: Sendable {
    func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// The body as lines split on `\n`, `\r\n` or a lone `\r`. Empty lines are yielded, since they end
    /// SSE events.
    func lines(for r: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>)
}

public struct URLSessionTransport: HTTPTransport {
    /// A non-200 body is only read for its error object: anything past this is dropped.
    public static let maxErrorBodyBytes = 16 * 1024

    public static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Remora/\(version ?? "0")"
    }()

    private let session: URLSession

    /// Uses its own ephemeral session (never `URLSession.shared`): no cookies, cache or credentials
    /// are kept between requests or shared with anything else in the process.
    public init() {
        self.session = URLSession(configuration: Self.sessionConfiguration())
    }

    public init(session: URLSession) {
        self.session = session
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return c
    }

    private func prepared(_ r: URLRequest) -> URLRequest {
        var r = r
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    public func data(for r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: prepared(r))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func lines(for r: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, any Error>) {
        let (bytes, response) = try await session.bytes(for: prepared(r))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let cap = http.statusCode == 200 ? Int.max : Self.maxErrorBodyBytes
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            let task = Task {
                do {
                    var splitter = LineSplitter()
                    var total = 0
                    // Not `bytes.lines`: it drops empty lines, which delimit SSE events.
                    for try await byte in bytes {
                        total += 1
                        if total > cap { break }
                        if let line = splitter.feed(byte) { continuation.yield(line) }
                        if splitter.overflowed {
                            continuation.finish(throwing: LLMError.badRequest(code: "event_too_large", param: nil))
                            return
                        }
                    }
                    if let rest = splitter.finish() { continuation.yield(rest) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (http, stream)
    }
}

/// Splits a byte stream into SSE lines. `\n`, `\r\n` and a lone `\r` all end a line (the terminator is
/// not part of it), empty lines are kept, and a `\n` right after a `\r` belongs to that `\r\n`, even
/// when the two arrive in different chunks.
struct LineSplitter {
    /// A line may not outgrow an SSE event (8 MB) plus slack for the field name.
    static let maxLineBytes = SSEParser.maxEventBytes + 64 * 1024

    private var buffer: [UInt8] = []
    private var afterCR = false
    /// Set once an unterminated line outgrew `maxLineBytes`. The caller must stop reading.
    private(set) var overflowed = false

    mutating func feed(_ byte: UInt8) -> String? {
        if afterCR {
            afterCR = false
            if byte == UInt8(ascii: "\n") { return nil }
        }
        switch byte {
        case UInt8(ascii: "\n"):
            return take()
        case UInt8(ascii: "\r"):
            afterCR = true
            return take()
        default:
            if buffer.count >= Self.maxLineBytes {
                overflowed = true
                buffer = []
                return nil
            }
            buffer.append(byte)
            return nil
        }
    }

    /// The unterminated last line, if any.
    mutating func finish() -> String? {
        afterCR = false
        guard !overflowed, !buffer.isEmpty else { return nil }
        return take()
    }

    private mutating func take() -> String {
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }
}
