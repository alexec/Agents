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
///
/// A child that has exited while something it started still holds its pipes (an ssh
/// ControlPersist master, a credential helper) is done two seconds after it exited, with
/// its own status: nothing it wrote is waited on for ever (#207).
///
/// Output past `outputLimit` bytes is read and dropped, with `truncated` set, so a chatty
/// child is never stalled and never held in memory whole (#207).
public enum ChildProcess {
    public struct Outcome: Sendable, Equatable {
        /// The exit status, or -1 when it could not start or ran out of time.
        public var status: Int32
        public var output: Data
        public var errors: Data
        public var timedOut = false
        /// Why it did not run, when it could not start.
        public var failure: String?
        /// Output went past the limit asked for; `output` is its first part.
        public var truncated = false

        public var text: String { String(decoding: output, as: UTF8.self) }
        public var errorText: String { String(decoding: errors, as: UTF8.self) }
    }

    /// What is kept of standard error, whatever the output limit: enough for any message.
    public static let errorLimit = 256 * 1024

    public static func run(_ executable: URL, _ arguments: [String],
                           environment: [String: String]? = nil,
                           in folder: URL? = nil,
                           input: Data? = nil,
                           deadline: Duration = .seconds(30),
                           outputLimit: Int? = nil) async -> Outcome {
        await run(process(executable, arguments, environment: environment, in: folder),
                  input: input, deadline: deadline, outputLimit: outputLimit)
    }

    /// The same, for a caller that is not async and has to wait where it is (the login
    /// shell's PATH, the Keychain). Waits on a semaphore: the run itself is finished on
    /// dispatch queues, never on the thread that waits.
    public static func runBlocking(_ executable: URL, _ arguments: [String],
                                   environment: [String: String]? = nil,
                                   in folder: URL? = nil,
                                   deadline: Duration = .seconds(30),
                                   outputLimit: Int? = nil) -> Outcome {
        let done = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        start(process(executable, arguments, environment: environment, in: folder),
              input: nil, deadline: deadline, outputLimit: outputLimit) { outcome in
            box.value = outcome
            done.signal()
        }
        done.wait()
        return box.value!
    }

    /// A process its caller set up (and may stop early), run the same way.
    public static func run(_ process: Process, input: Data? = nil, deadline: Duration = .seconds(30),
                           outputLimit: Int? = nil) async -> Outcome {
        await withCheckedContinuation { continuation in
            start(process, input: input, deadline: deadline, outputLimit: outputLimit) {
                continuation.resume(returning: $0)
            }
        }
    }

    private static func process(_ executable: URL, _ arguments: [String],
                                environment: [String: String]?, in folder: URL?) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let folder { process.currentDirectoryURL = folder }
        return process
    }

    private static func start(_ process: Process, input: Data?, deadline: Duration, outputLimit: Int?,
                              finished: @escaping @Sendable (Outcome) -> Void) {
        let stdin = input == nil ? nil : Pipe()
        process.standardInput = stdin ?? FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // The run holds the process and its pipes only until it is finished, so the
        // timers below, which only hold the run, never keep a finished child's
        // descriptors open until they fire.
        let run = Run(finished: finished, outputLimit: outputLimit ?? .max,
                      process: process, pipes: [output, errors])

        for (pipe, isOutput) in [(output, true), (errors, false)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    run.update { $0.open -= 1 }
                } else {
                    run.update { $0.append(data, toOutput: isOutput) }
                }
            }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            run.update { $0.status = status; $0.exited = true }
            // Whatever still holds a pipe is not this child: two seconds, then done.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { run.finish() }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            run.finish(failure: error.localizedDescription)
            return
        }
        if let input, let stdin {
            // Written off this thread and closed, so input longer than the pipe's buffer
            // cannot stall the child and its caller waiting on each other.
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { run.finish(timedOut: true) }
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: Outcome?
    }

    /// What one run has gathered, behind a lock; hands its outcome on exactly once.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var finished: (@Sendable (Outcome) -> Void)?
        private let outputLimit: Int
        private var process: Process?
        private var pipes: [Pipe]
        var output = Data(), errors = Data()
        var truncated = false
        var status: Int32 = -1
        var exited = false
        var open = 2

        init(finished: @escaping @Sendable (Outcome) -> Void, outputLimit: Int, process: Process, pipes: [Pipe]) {
            self.finished = finished
            self.outputLimit = outputLimit
            self.process = process
            self.pipes = pipes
        }

        func append(_ data: Data, toOutput: Bool) {
            let limit = toOutput ? outputLimit : ChildProcess.errorLimit
            let held = toOutput ? output.count : errors.count
            let room = max(0, limit - held)
            if data.count > room, toOutput { truncated = true }
            guard room > 0 else { return }
            if toOutput { output.append(data.prefix(room)) } else { errors.append(data.prefix(room)) }
        }

        func update(_ change: (Run) -> Void) {
            lock.lock()
            change(self)
            let done = exited && open == 0
            lock.unlock()
            if done { finish() }
        }

        /// Hands the outcome on, lets go of the process and its pipes, and stops a child
        /// that ran out of time (SIGTERM, then SIGKILL two seconds on). Once only.
        func finish(timedOut: Bool = false, failure: String? = nil) {
            lock.lock()
            guard let finished else { lock.unlock(); return }
            self.finished = nil
            let outcome = Outcome(status: timedOut ? -1 : status, output: output, errors: errors,
                                  timedOut: timedOut, failure: failure, truncated: truncated)
            let process = self.process, pipes = self.pipes
            self.process = nil
            self.pipes = []
            lock.unlock()
            // The pipes close when the last of them goes: nothing more is read.
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            if timedOut, let process, process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
            finished(outcome)
        }
    }
}
#endif
