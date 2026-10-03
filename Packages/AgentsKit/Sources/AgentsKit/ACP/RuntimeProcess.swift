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
    /// This side's descriptors, as numbered at launch: what `cleanUp` must give back.
    /// For a test to look for afterwards (#163).
    let heldDescriptors: [Int32]

    public init(executable: URL,
                arguments: [String],
                cwd: URL,
                environment: [String: String],
                onStandardError: (@Sendable (String) -> Void)? = nil,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        process.executableURL = executable
        process.arguments = arguments
        // Always a file URL: a folder sent as a bare path decodes to a URL with no scheme,
        // and `Process` raises an Objective-C exception for that, which takes the whole
        // daemon down with every agent in it.
        process.currentDirectoryURL = RuntimeProcess.folderURL(cwd)
        process.environment = environment
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let readFD = dup(outPipe.fileHandleForReading.fileDescriptor)
        let writeFD = dup(inPipe.fileHandleForWriting.fileDescriptor)
        transport = FDTransport(readFD: readFD, writeFD: writeFD)
        heldDescriptors = [readFD, writeFD,
                           inPipe.fileHandleForWriting.fileDescriptor,
                           outPipe.fileHandleForReading.fileDescriptor,
                           errPipe.fileHandleForReading.fileDescriptor]

        // Nobody reads a runtime's stderr but the log. Draining it matters anyway: a
        // full pipe stops the process writing, and a stopped process looks like a hung
        // agent.
        //
        // Empty is the end of the pipe, and it is reported again and again until the
        // handler goes: left in place, it is a core spinning for the daemon's life
        // (#163). So it takes itself away there, whether or not `cleanUp` ever runs.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onStandardError?(String(decoding: data, as: UTF8.self))
        }

        process.terminationHandler = { process in
            onExit(process.terminationStatus)
        }

        try process.run()
    }

    /// `url` as a file URL to a folder, whatever scheme it came with.
    static func folderURL(_ url: URL) -> URL {
        url.isFileURL ? url : URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
    }

    public var isRunning: Bool { process.isRunning }
    /// Whether stderr still has a handler on it. One left on a pipe at its end is a
    /// core spinning (#163).
    var watchesStandardError: Bool { errPipe.fileHandleForReading.readabilityHandler != nil }
    public var processIdentifier: Int32 { process.processIdentifier }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public func kill() {
        guard process.isRunning else { return }
        POSIX.kill(process.processIdentifier, SIGKILL)
    }

    private let cleanedUp = ManagedAtomicFlag()

    /// Let go of the pipes. Called once the process is gone, by whichever comes first:
    /// a stop (`ACPSession.end`) or the process dying by itself (`ACPSession.noteExit`).
    /// The second call does nothing.
    public func cleanUp() {
        guard cleanedUp.set() else { return }
        errPipe.fileHandleForReading.readabilityHandler = nil
        transport.close()
        try? inPipe.fileHandleForWriting.close()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
    }
}
