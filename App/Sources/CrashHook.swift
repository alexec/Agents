import Foundation
import ObjectiveC
import os

/// Names the exception that takes the window down (#76).
///
/// An exception thrown while AppKit lays out a view never reaches
/// `NSSetUncaughtExceptionHandler` or `reportException:`: AppKit catches it itself and
/// traps in `+[NSApplication _crashOnException:]`, and the crash report has no reason
/// in it. So every exception is written up as it is thrown (name, reason and the stack,
/// which still has the view that threw on it), and kept in memory. If the window then
/// dies of SIGTRAP or SIGABRT, the last one goes to a crash note in the container,
/// `Application Support/Agents/crashes/`, and to the log at `.fault`. One that does
/// reach the uncaught handler is written there instead.
enum CrashHook {
    private static let log = Logger(subsystem: "com.alexecollins.agents", category: "crash")

    // Read by a signal handler, which may not lock or allocate before it has written.
    private nonisolated(unsafe) static var pending: (path: UnsafeMutablePointer<CChar>, note: UnsafeMutablePointer<CChar>)?
    private nonisolated(unsafe) static var lock = os_unfair_lock()
    private nonisolated(unsafe) static var preprocessor: objc_exception_preprocessor?

    private nonisolated(unsafe) static var folder: URL?

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents/crashes", isDirectory: true)
    }

    static func install(in crashes: URL = defaultFolder) {
        try? FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true) // store-ok: the window's own container
        folder = crashes

        preprocessor = objc_setExceptionPreprocessor { thrown in
            let thrown = CrashHook.preprocessor.map { $0(thrown) } ?? thrown
            if let exception = thrown as? NSException { CrashHook.keep(exception) }
            return thrown
        }
        NSSetUncaughtExceptionHandler { exception in
            CrashHook.keep(exception)
            CrashHook.writePending()
        }
        for caught in [SIGTRAP, SIGABRT] {
            signal(caught) { caught in
                CrashHook.writePending()
                // Die of the same signal, so the crash report is the one it would have been.
                signal(caught, SIG_DFL)
                raise(caught)
            }
        }
        log.info("crash notes go to \(crashes.path, privacy: .public)")
    }

    /// The note for an exception, as it will be written if it is the one that crashes.
    static func note(for exception: NSException, at date: Date = .now, onMain: Bool = Thread.isMainThread) -> String {
        """
        The window crashed on an exception it did not catch.
        Thrown: \(date.formatted(.iso8601)) on \(onMain ? "the main thread" : "a background thread")
        Name: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "(none given)")

        \(exception.callStackSymbols.joined(separator: "\n"))

        """
    }

    private static func keep(_ exception: NSException) {
        guard let folder else { return }
        let date = Date.now
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let path = strdup(folder.appendingPathComponent("crash-\(stamp).txt").path)!
        let text = strdup(note(for: exception, at: date))!
        os_unfair_lock_lock(&lock)
        let old = pending
        pending = (path, text)
        os_unfair_lock_unlock(&lock)
        if let old { free(old.path); free(old.note) }
    }

    /// Writes the last exception kept, once. Safe in a signal handler up to the write;
    /// the log line after it is a last try, as the process is going anyway.
    private static func writePending() {
        guard let (path, note) = pending else { return }
        pending = nil
        let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if file >= 0 {
            _ = write(file, note, strlen(note))
            close(file)
        }
        log.fault("\(String(cString: note), privacy: .public)")
    }
}
