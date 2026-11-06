import Foundation

/// Hands a fresh daemon connection to a device before the device is heard on it
/// (security review, Phase 3).
///
/// The bridge is signed as the app is, so the daemon gives every connection it opens a
/// window's rights. Carrying a phone's lines on one of those made the phone a window:
/// anything it could send, the Mac would do. `bind` says `connection/bindDevice` first
/// and waits for the answer, because the daemon handles a connection's requests side by
/// side — a device line sent before the answer could still be handled as a window's.
///
/// The answer is the bridge's, not the device's, so it is kept off the stream the
/// device reads. Everything else the daemon says in the meantime goes through in order.
public enum DeviceBinder {
    /// The request id the answer is recognised by. A string, where the Remote's own
    /// ids are numbers, so the two can never be taken for each other.
    static let requestID = "agents-bridge-bind-device"

    public enum Failure: Error, Sendable {
        /// The daemon went before it answered.
        case closed
        /// The daemon refused: this connection was not a window's to give away.
        case refused(JSONRPCError)
    }

    /// `transport` as a device's: returns once the daemon has agreed, with a transport
    /// whose lines carry on from where the binding left off.
    public static func bind(_ transport: any LineTransport, device: UUID?) async throws -> any LineTransport {
        let bound = BoundTransport(inner: transport)
        let request = JSONRPCMessage.request(id: .string(requestID), method: DaemonAPI.Method.connectionBindDevice,
                                             params: try JSONValue.encoding(DaemonAPI.DeviceBinding(id: device)))
        try transport.write(line: try JSONRPCCodec.encode(request))
        try await bound.waitForBinding()
        return bound
    }
}

/// The daemon's lines, less the one answer that was the bridge's own.
final class BoundTransport: LineTransport, @unchecked Sendable {
    private let inner: any LineTransport
    private let stream: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let lock = NSLock()
    private var outcome: Result<Void, DeviceBinder.Failure>?
    private var waiting: CheckedContinuation<Void, any Error>?
    private var pump: Task<Void, Never>?

    init(inner: any LineTransport) {
        self.inner = inner
        var c: AsyncThrowingStream<String, any Error>.Continuation!
        stream = AsyncThrowingStream { c = $0 }
        continuation = c
        pump = Task { [weak self, inner] in
            do {
                for try await line in inner.lines() {
                    guard let self else { return }
                    if self.isTheAnswer(line) { continue }
                    self.continuation.yield(line)
                }
                self?.continuation.finish()
            } catch {
                self?.continuation.finish(throwing: error)
            }
            self?.settle(.failure(.closed))
        }
    }

    /// Only a line that mentions the id is decoded, so the rest go by unread, as the
    /// bridge has always carried them.
    private func isTheAnswer(_ line: String) -> Bool {
        guard line.contains(DeviceBinder.requestID),
              let message = try? JSONRPCCodec.decode(line: line),
              message.id == .string(DeviceBinder.requestID)
        else { return false }
        switch message {
        case .failure(_, let error): settle(.failure(.refused(error)))
        default: settle(.success(()))
        }
        return true
    }

    private func settle(_ result: Result<Void, DeviceBinder.Failure>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiter = waiting
        waiting = nil
        lock.unlock()
        waiter?.resume(with: result.mapError { $0 as any Error })
    }

    func waitForBinding() async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let outcome {
                lock.unlock()
                waiter.resume(with: outcome.mapError { $0 as any Error })
            } else {
                waiting = waiter
                lock.unlock()
            }
        }
    }

    func write(line: String) throws { try inner.write(line: line) }
    func lines() -> AsyncThrowingStream<String, any Error> { stream }

    func close() {
        pump?.cancel()
        inner.close()
    }
}
