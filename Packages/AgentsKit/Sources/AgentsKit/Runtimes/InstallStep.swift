import Foundation

/// One command an installer runs (048): stdin closed, both outputs in a log file, ended on
/// `terminationHandler` and never `waitUntilExit`, and stopped at a deadline.
///
/// A log file rather than pipes, so a chatty installer can never fill a pipe nobody is
/// reading and stall; the tail is what a failure is explained with.
struct InstallStep: Sendable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    var timeout: Duration = .seconds(300)

    struct Outcome: Sendable {
        var status: Int32
        var timedOut: Bool
        var output: String

        /// The last few non-empty lines, for a sentence about what went wrong.
        func tail(_ lines: Int = 5) -> String {
            output.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(lines)
                .joined(separator: "\n")
        }

        var lastLine: String { tail(1) }
    }

    func run() async throws -> Outcome {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-install-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle

        let timedOut = Flag()
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(throwing: error)
                return
            }
            let deadline = timeout
            Task.detached {
                try? await Task.sleep(for: deadline)
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
            }
        }
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return Outcome(status: status, timedOut: timedOut.isSet, output: output)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
