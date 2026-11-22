import Foundation
import Network
import os
import Synchronization

/// The sign-in redirect target: a one-shot HTTP listener on `127.0.0.1` (never `localhost`, never
/// another interface). It tries each preferred port, then an ephemeral one.
///
/// Requests other than `GET /auth/callback` are answered 404 (400 if unparseable) and do not end the
/// wait. The first callback wins; later ones get 404. The browser's request for the callback is held
/// open until the flow reports the outcome with `finish(signedIn:)`, so the page it shows reflects the
/// real result of the exchange and validation. `stop()` answers a still-pending callback with the
/// failure page, ends any wait with `CancellationError` and closes everything.
public final class LoopbackServer: Sendable {
    private struct State {
        var listener: NWListener?
        var connections: [ObjectIdentifier: NWConnection] = [:]
        /// The callback's connection, waiting for the result page.
        var pending: NWConnection?
        var callback: [String: String]?
        var waiter: CheckedContinuation<[String: String], any Error>?
        /// Why the attempt ended (timeout, cancellation, listener failure), kept for a wait that
        /// registers afterwards.
        var terminal: (any Error)?
        var accepted = false
        var stopped = false
    }

    static let maxHeadBytes = 16 * 1024
    private static let log = Logger(subsystem: "dev.remora", category: "auth")

    private let ports: [UInt16]
    private let queue = DispatchQueue(label: "dev.remora.auth.loopback")
    private let state = Mutex(State())

    public init(ports: [UInt16] = SIWC.ports) {
        self.ports = ports
    }

    // MARK: - Listening

    /// Binds the first free port among `ports`, then an ephemeral one; returns the bound port.
    public func start() async throws -> UInt16 {
        for candidate in ports.filter({ $0 != 0 }) + [0] {
            if let port = try? await listen(on: candidate) { return port }
        }
        Self.log.error("loopback listener: no port available")
        throw AuthError.listenerFailed
    }

    private func listen(on port: UInt16) async throws -> UInt16 {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw AuthError.listenerFailed }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = false
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = Mutex<CheckedContinuation<UInt16, any Error>?>(nil)
        let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
            ready.withLock { $0 = continuation }
            listener.stateUpdateHandler = { [weak self] newState in
                switch newState {
                case .ready:
                    ready.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? port)
                case .failed, .waiting:
                    // `.waiting` is how an address in use can show up: treat it as a failure.
                    if let c = ready.withLock({ $0.take() }) {
                        listener.cancel()
                        c.resume(throwing: AuthError.listenerFailed)
                    } else {
                        self?.end(with: AuthError.listenerFailed)
                    }
                case .cancelled:
                    ready.withLock { $0.take() }?.resume(throwing: AuthError.listenerFailed)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        let stopped = state.withLock { s -> Bool in
            if !s.stopped { s.listener = listener }
            return s.stopped
        }
        if stopped {
            listener.cancel()
            throw CancellationError()
        }
        return bound
    }

    // MARK: - Waiting

    /// The first callback's query. Throws `AuthError.timedOut`, `CancellationError` (task cancelled or
    /// `stop()`), or `AuthError.listenerFailed`.
    public func waitForCallback(timeout: Duration) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.end(with: AuthError.timedOut)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], any Error>) in
                let immediate: Result<[String: String], any Error>? = state.withLock { s in
                    if let q = s.callback { return .success(q) }
                    if let e = s.terminal { return .failure(e) }
                    if s.stopped || Task.isCancelled { return .failure(CancellationError()) }
                    if s.waiter != nil { return .failure(AuthError.listenerFailed) }
                    s.waiter = c
                    return nil
                }
                if let immediate { c.resume(with: immediate) }
            }
        } onCancel: { [weak self] in
            self?.end(with: CancellationError())
        }
    }

    /// Ends the attempt: fails the current wait, or a later one if none is registered yet (a timer can
    /// fire before the wait installs itself). Later callbacks are refused.
    func end(with error: any Error) {
        let waiter = state.withLock { s -> CheckedContinuation<[String: String], any Error>? in
            s.accepted = true
            if s.terminal == nil { s.terminal = error }
            return s.waiter.take()
        }
        waiter?.resume(throwing: error)
    }

    // MARK: - Finishing

    /// Answers the held callback request with the success or failure page.
    public func finish(signedIn: Bool) {
        guard let connection = state.withLock({ $0.pending.take() }) else { return }
        respondPage(connection, signedIn: signedIn)
    }

    public func stop() {
        let (listener, connections, pending, waiter) = state.withLock { s in
            s.stopped = true
            s.accepted = true
            defer { s.connections = [:] }
            return (s.listener.take(), s.connections, s.pending.take(), s.waiter.take())
        }
        listener?.cancel()
        if let pending { respondPage(pending, signedIn: false) }
        for (_, c) in connections where c !== pending { c.cancel() }
        waiter?.resume(throwing: CancellationError())
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let refused = state.withLock { s -> Bool in
            if s.stopped { return true }
            s.connections[id] = connection
            return false
        }
        if refused {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled: self?.forget(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        state.withLock { s in
            s.connections[ObjectIdentifier(connection)] = nil
            if s.pending === connection { s.pending = nil }
        }
    }

    /// Reads until the end of the request head (or the size cap), then handles it.
    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeadBytes) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8)) {
                self.handle(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if buffer.count > Self.maxHeadBytes {
                self.respond(connection, status: "431 Request Header Fields Too Large", body: "Too large")
            } else if error != nil || isComplete {
                if buffer.isEmpty { connection.cancel() } else { self.handle(connection, head: String(decoding: buffer, as: UTF8.self)) }
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ connection: NWConnection, head: String) {
        switch CallbackRequest.parse(requestHead: head) {
        case .failure(.notFound):
            respond(connection, status: "404 Not Found", body: "Not found")
        case .failure(.malformed):
            respond(connection, status: "400 Bad Request", body: "Bad request")
        case .success(let query):
            let outcome = state.withLock { s -> (won: Bool, waiter: CheckedContinuation<[String: String], any Error>?) in
                guard !s.accepted, !s.stopped else { return (false, nil) }
                s.accepted = true
                s.pending = connection
                guard let w = s.waiter.take() else {
                    s.callback = query
                    return (true, nil)
                }
                return (true, w)
            }
            guard outcome.won else {
                respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            Self.log.info("loopback listener: callback received")
            outcome.waiter?.resume(returning: query)
        }
    }

    private func respondPage(_ connection: NWConnection, signedIn: Bool) {
        let message = signedIn ? "Signed in to Remora. You can close this tab." : "Sign-in failed. Return to Remora."
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Remora</title></head>\
        <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;margin-top:20vh">\
        <h2>\(message)</h2></body></html>
        """
        respond(connection, status: "200 OK", body: html, contentType: "text/html")
    }

    private func respond(_ connection: NWConnection, status: String, body: String, contentType: String = "text/plain") {
        // Answered connections close themselves once the response is written; `stop()` must not cut them off.
        forget(connection)
        let head = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType); charset=utf-8",
            "Content-Length: \(body.utf8.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "Connection: close",
        ].joined(separator: "\r\n")
        connection.send(content: Data((head + "\r\n\r\n" + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
