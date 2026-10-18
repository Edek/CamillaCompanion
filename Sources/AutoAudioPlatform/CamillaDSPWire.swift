import Foundation
import AutoAudioCore

/// Raw exchange only. Callers own authority checks, reply validation and socket lifetime.
@MainActor enum CamillaDSPWire {
    static func request(_ command: String, socket: URLSessionWebSocketTask,
                        invalidResponse: String) async throws -> Data {
        try await socket.send(.string(command))
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw SwitcherError.message(invalidResponse)
        }
    }
}

/// A one-shot deadline, cancelled by the owning exchange. It never extends a budget.
@MainActor enum DSPConnectionDeadline {
    static func schedule(nanoseconds: UInt64,
                         onTimeout: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            onTimeout()
        }
    }
}

/// Only the callers with the same local-endpoint contract use this validator.
enum LocalCamillaDSPEndpoint {
    static func url(_ value: String, invalidEndpoint: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "ws",
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? ""),
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, ["", "/"].contains(url.path) else {
            throw SwitcherError.message(invalidEndpoint)
        }
        return url
    }
}

/// Exactly one outcome releases an exchange, even when socket cancellation is slow.
@MainActor final class DSPReplyGate<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Parent cancellation can arrive off actor, including before a worker is registered.
final class DSPExchangeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var worker: Task<Void, Never>?

    func install(_ worker: Task<Void, Never>) {
        lock.lock()
        self.worker = worker
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { worker.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let worker = worker
        lock.unlock()
        worker?.cancel()
    }
}
