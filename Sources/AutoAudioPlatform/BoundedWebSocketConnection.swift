import Foundation

/// Teardown owns only this connection. Command authority belongs to the caller
/// and must be revoked before beginning a graceful close.
package final class BoundedWebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closing = false
    private var invalidated = false
    private var deadline: DispatchWorkItem?
    private var session: URLSession!
    package private(set) var socket: URLSessionWebSocketTask!
    private let closeTimeout: TimeInterval
    private let failure: (@Sendable (String) -> Void)?
    private let onInvalidation: (@Sendable () -> Void)?

    package init(url: URL, timeout: TimeInterval, closeTimeout: TimeInterval = 0.75,
         failure: (@Sendable (String) -> Void)? = nil,
         onInvalidation: (@Sendable () -> Void)? = nil) {
        self.closeTimeout = max(0.01, min(closeTimeout, 5))
        self.failure = failure; self.onInvalidation = onInvalidation
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // Callers own finite command deadlines and cancel/abort this connection.
        // A resource timer racing that deadline has left Foundation's pending
        // receive and TCP socket alive after abort in controlled peer checks.
        // Keep the request timeout for establishment; do not race the caller
        // with a second WebSocket resource deadline.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: url)
    }

    package func close() {
        lock.lock()
        guard !closing, !invalidated else { lock.unlock(); return }
        closing = true
        let socket = self.socket!
        let deadline = DispatchWorkItem { [weak self] in self?.abort() }
        self.deadline = deadline
        lock.unlock()
        // cancel(with:) can report didClose/completion before the Close frame is
        // delivered. Keep the session for one bounded grace period rather than
        // invalidating on those local cancellation callbacks. The deadline also
        // releases a peer that never acknowledges; it is never extended.
        socket.cancel(with: .normalClosure, reason: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + closeTimeout, execute: deadline)
    }

    package func abort() {
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        closing = true
        let socket = self.socket, session = self.session
        deadline?.cancel(); deadline = nil
        lock.unlock()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    private func report(_ message: String) {
        lock.lock(); let shouldReport = !closing && !invalidated; lock.unlock()
        if shouldReport { failure?(message) }
    }
    package func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        report("CamillaDSP connection closed (\(closeCode.rawValue))")

    }
    package func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        report(error.map { "CamillaDSP connection failed: \($0.localizedDescription)" } ?? "CamillaDSP connection ended")
    }
    package func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        invalidated = true
        deadline?.cancel(); deadline = nil
        self.session = nil; socket = nil
        lock.unlock()
        onInvalidation?()
    }
}
