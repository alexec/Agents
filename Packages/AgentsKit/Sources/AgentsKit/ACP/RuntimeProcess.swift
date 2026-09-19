import Foundation

/// A launched runtime, and the pipes to it.
///
/// The descriptors handed to the transport are duplicates, so closing the transport
/// cannot close a descriptor that `Process` still believes it owns.
public final class RuntimeProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    public let transport: FDTransport

    public init(executable: URL,
                arguments: [String],
                cwd: URL,
                environment: [String: String],
                onStandardError: (@Sendable (String) -> Void)? = nil,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        transport = FDTransport(readFD: dup(outPipe.fileHandleForReading.fileDescriptor),
                                writeFD: dup(inPipe.fileHandleForWriting.fileDescriptor))

        // Nobody reads a runtime's stderr but the log. Draining it matters anyway: a
        // full pipe stops the process writing, and a stopped process looks like a hung
        // agent.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let onStandardError else { return }
            onStandardError(String(decoding: data, as: UTF8.self))
        }

        process.terminationHandler = { process in
            onExit(process.terminationStatus)
        }

        try process.run()
    }

    public var isRunning: Bool { process.isRunning }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    /// Let go of the pipes. Called once the process is gone.
    public func cleanUp() {
        errPipe.fileHandleForReading.readabilityHandler = nil
        transport.close()
        try? inPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
    }
}
