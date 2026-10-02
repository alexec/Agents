import Foundation

/// Pairing a window or a device, with an end a person can count on (#84): an answer,
/// a refusal in words, or "no answer" once the deadline is up, never a spinner for good.
public enum PairingAttempt {
    /// How long a person is asked to watch a spinner. The dial, the proof and the
    /// announce each have limits of their own, but together they come to most of a
    /// minute.
    public static let patience: Duration = .seconds(30)

    /// The control plane said nothing before the deadline.
    public struct NoAnswer: Error, Sendable, CustomStringConvertible {
        public var description: String { "the control plane did not answer in time" }
    }

    /// `work`'s answer, or `NoAnswer` once `within` is up, at which point `work` is
    /// cancelled. Not a task group: a dial waiting on the network does not hear
    /// cancellation, and a group would wait for it anyway.
    public static func run<T: Sendable>(within: Duration = patience,
                                        _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let settled = ManagedAtomicFlag()
        let job = Task { try await work() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task {
                    try? await Task.sleep(for: within)
                    guard !Task.isCancelled else { return }
                    job.cancel()
                    if settled.set() { continuation.resume(throwing: NoAnswer()) }
                }
                Task {
                    let result = await job.result
                    timer.cancel()
                    if settled.set() { continuation.resume(with: result) }
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// What to tell a person about a pairing that failed, the same on the Mac and the
    /// phone. `device` is what is pairing: "this Mac", "this iPhone".
    public static func sentence(for error: any Error, device: String) -> String {
        let unanswered = error is NoAnswer || (error as? ControlCodeUse.Failure) == .noAnswer
        switch error {
        case _ where unanswered:
            return "The control plane didn’t answer. Check it’s running and \(device) can reach it, then try again."
        case let error as JSONRPCError:
            // The control plane's own words: it wrote them for a person.
            return error.message
        case is URLError:
            return "Couldn’t reach the control plane. Check it’s running and \(device) can reach it, then try again."
        case is CancellationError:
            return "Stopped before it finished. Try again when you’re ready."
        default:
            return "The control plane didn’t take that code. It may have run out: show a new one and try again."
        }
    }
}
