import Foundation
import AgentsKitCore

/// Writes the disk refused (#88): a full disk, or a folder this may not write to.
///
/// Two ways to be told. A write somebody asked for fails their call, in words, and the
/// window keeps what they typed. A write nobody was waiting on — a line of a chat, an
/// agent's record as it streams, the day's spend — goes to every window as
/// `storage/writeFailed`, once in a while per cause, so it is never lost in silence.
extension DaemonCore {
    /// How long one cause stays told. A full disk under a streaming agent fails on
    /// every token; the person needs to hear it once, and again if it is still so later.
    static let writeFailureQuiet: TimeInterval = 10 * 60

    /// The error to throw to the call that asked: the refusal in words when it is one of
    /// the three, and the error as it was otherwise.
    func couldNotSave(_ error: any Error, keeping what: String) -> any Error {
        guard let failure = WriteFailure(error, keeping: what) else { return error }
        DaemonLog.shared.write("store: could not save \(what): \(error)")
        return Self.refusal(failure)
    }

    static func refusal(_ failure: WriteFailure) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.couldNotSave, message: failure.message,
                     data: try? JSONValue.encoding(failure))
    }

    /// git refusing to make a worktree: in words when the disk is why, and in git's
    /// own otherwise. git says "No space left on device", never an errno.
    static func worktreeRefusal(_ gitMessage: String, saying words: String) -> JSONRPCError {
        if let failure = WriteFailure(gitMessage: gitMessage, keeping: "the new worktree") { return refusal(failure) }
        return JSONRPCError(code: DaemonAPI.Failure.worktreeFailed, message: words)
    }

    /// Run a write for a call that is waiting on it.
    func keep(_ what: String, _ write: () throws -> Void) throws {
        do { try write() } catch { throw couldNotSave(error, keeping: what) }
    }

    /// Run a write nobody is waiting on. A refusal is logged and told.
    func keepQuietly(_ what: String, _ write: () throws -> Void) {
        do { try write() } catch { lost(error, keeping: what) }
    }

    /// A write nobody was waiting on was refused. Logged always; told to the windows
    /// when it is one of the three and that cause has not been told lately.
    func lost(_ error: any Error, keeping what: String) {
        let key = "\(what): \(error.localizedDescription)"
        if let notice = failedSaveNotices.note(key, at: now()) {
            switch notice {
            case .first: DaemonLog.shared.write("store: could not save \(what): \(error)")
            case .again(let times, _): DaemonLog.shared.write("store: could not save a line (repeated \(times) times): \(error)")
            }
        }
        guard let failure = WriteFailure(error, keeping: what) else { return }
        let at = now()
        if let told = writeFailuresTold[failure.cause], at.timeIntervalSince(told) < Self.writeFailureQuiet { return }
        writeFailuresTold[failure.cause] = at
        broadcast(DaemonAPI.Notification.writeFailed, failure)
    }
}
