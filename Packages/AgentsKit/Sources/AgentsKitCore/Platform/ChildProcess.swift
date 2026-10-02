#if os(macOS) || os(Linux)
import Foundation

/// A short-lived command run to its end, with what it wrote kept (#92).
///
/// Both pipes are read as they fill, so a child that writes more than a pipe holds
/// (64 KB) is never left blocked on a write it cannot finish. It is done when it has
/// exited and both pipes are at their end, whichever comes last. Ended on the
/// termination handler, never `waitUntilExit`, which hangs off the main thread.
///
/// A child still going at the deadline is stopped (SIGTERM, then SIGKILL two seconds on)
/// and the run comes back at once with `timedOut` set and what was read so far.
public enum ChildProcess {
    public struct Outcome: Sendable, Equatable {
        /// The exit status, or -1 when it could not start or ran out of time.
        public var status: Int32
        public var output: Data
        public var errors: Data
        public var timedOut = false
        /// Why it did not run, when it could not start.
        public var failure: String?

        public var text: String { String(decoding: output, as: UTF8.self) }
        public var errorText: String { String(decoding: errors, as: UTF8.self) }
    }

    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String]? = nil,
                           deadline: Duration = .seconds(30)) async -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let run = Run()

        return await withCheckedContinuation { continuation in
            run.continuation = continuation
            for (pipe, path) in [(output, \Run.output), (errors, \Run.errors)] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        run.update { $0.open -= 1 }
                    } else {
                        run.update { $0[keyPath: path].append(data) }
                    }
                }
            }
            process.terminationHandler = { finished in
                let status = finished.terminationStatus
                run.update { $0.status = status; $0.exited = true }
            }
            do {
                try process.run()
            } catch {
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                run.finish(failure: error.localizedDescription)
                return
            }
            let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard run.finish(timedOut: true) else { return }
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                guard process.isRunning else { return }
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    /// What one run has gathered, behind a lock; resumes its caller exactly once.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Outcome, Never>?
        var output = Data(), errors = Data()
        var status: Int32 = -1
        var exited = false
        var open = 2

        func update(_ change: (Run) -> Void) {
            lock.lock()
            change(self)
            let done = exited && open == 0
            lock.unlock()
            if done { finish() }
        }

        @discardableResult
        func finish(timedOut: Bool = false, failure: String? = nil) -> Bool {
            lock.lock()
            guard let continuation else { lock.unlock(); return false }
            self.continuation = nil
            let outcome = Outcome(status: timedOut ? -1 : status, output: output, errors: errors,
                                  timedOut: timedOut, failure: failure)
            lock.unlock()
            continuation.resume(returning: outcome)
            return true
        }
    }
}
#endif
