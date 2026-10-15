import Foundation

/// A view's first read, with a deadline (#978). A `views/read` with no answer — a link that
/// dropped while it was in flight — left a view loading for good: a blank box, no words, and
/// no way to read it again but leaving the chat. Now every wait ends, and how it ended says
/// whether reading again could help.
public enum AppViewLoad {
    /// How long a view's resource may take to read: a person's own server may be started for it.
    public static let readDeadline: Duration = .seconds(30)
    /// How long a pinned view's own feeding call may take: it runs the tool.
    public static let feedDeadline: Duration = .seconds(60)
    /// How long the view's network rules may take to compile.
    public static let rulesDeadline: Duration = .seconds(10)

    public enum Outcome: Sendable, Equatable {
        case resource(DaemonAPI.ViewResource)
        /// A person's own server's view, waiting on Show or Don't Show (#191).
        case asking(DaemonAPI.ViewAsk)
        /// Why it was not read. Every one of these may be read again (Try Again).
        case failed(String)
    }

    /// A wait that ran out.
    public struct Late: Error, Sendable, LocalizedError {
        public let deadline: Duration
        public var errorDescription: String? { "no answer in \(deadline.components.seconds) seconds" }
    }

    /// The view's resource, read through `call` (one of `views/*`) within `deadline`.
    public static func read(_ request: DaemonAPI.ViewReadRequest, within deadline: Duration = readDeadline,
                            call: @escaping @Sendable (String, JSONValue) async throws -> JSONValue) async -> Outcome {
        do {
            let params = try JSONValue.encoding(request)
            let value = try await answered(within: deadline) { try await call(DaemonAPI.Method.viewsRead, params) }
            return .resource(try value.decode(DaemonAPI.ViewResource.self))
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.viewNeedsShow {
            // Nothing of it is drawn until the person says Show.
            if let ask = try? error.data?.decode(DaemonAPI.ViewAsk.self) { return .asking(ask) }
            return .failed(error.message)
        } catch {
            return .failed("This view could not be read from the server: \(words(error))")
        }
    }

    /// `work`'s answer, or `Late` once `deadline` is up, whichever comes first.
    ///
    /// Not a task group: a call waiting on a reply does not hear cancellation, and a group
    /// waits for every child, so it would wait for the lost reply too (as `RemoteFiles`).
    public static func answered<T: Sendable>(within deadline: Duration,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let settled = ManagedAtomicFlag()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: deadline)
                if settled.set() { continuation.resume(throwing: Late(deadline: deadline)) }
            }
            Task {
                let result: Result<T, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if settled.set() {
                    timer.cancel()
                    continuation.resume(with: result)
                }
            }
        }
    }

    public static func words(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }
}
