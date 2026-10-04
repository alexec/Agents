import Foundation
import ObjectiveC
import os

/// Names the exception that takes the window down (#76, #178).
///
/// An exception thrown while AppKit lays out a view never reaches
/// `NSSetUncaughtExceptionHandler` or `reportException:`: AppKit catches it itself and
/// traps in `+[NSApplication _crashOnException:]`, and the crash report has no reason
/// in it. So every exception is written up as it is thrown (name, reason and the stack,
/// which still has the view that threw on it), and kept in memory. If the window then
/// dies of SIGTRAP or SIGABRT, the last one goes to a crash note in the container,
/// `Application Support/Agents/crashes/`. One that reaches the uncaught handler (thrown
/// from a display-link or Core Animation callback, say, which ends in `abort`) is
/// written there, and logged at `.fault`, before the process aborts.
///
/// What runs as the process dies is only `open`, `write` and `close` of buffers made when
/// the exception was thrown: no allocation, no lock it has to wait for, no Swift runtime
/// that could take one, so the note is on disk before the signal is raised again.
enum CrashHook {
    private static let log = Logger(subsystem: "com.alexecollins.agents", category: "crash")

    /// An exception older than this when the window dies is written with a warning first:
    /// a Swift trap long after some caught exception was not caused by it.
    static let freshSeconds = 5

    private struct Pending {
        let path: UnsafeMutablePointer<CChar>
        let note: UnsafeMutablePointer<CChar>
        let length: Int
        let thrown: Int
    }

    // Read by a signal handler, which may not lock or allocate before it has written.
    private nonisolated(unsafe) static var pending: Pending?
    private nonisolated(unsafe) static var lock = os_unfair_lock()
    private nonisolated(unsafe) static var preprocessor: objc_exception_preprocessor?
    private nonisolated(unsafe) static var stale: (text: UnsafeMutablePointer<CChar>, length: Int)?

    private nonisolated(unsafe) static var folder: URL?

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents/crashes", isDirectory: true)
    }

    static func install(in crashes: URL = defaultFolder) {
        try? FileManager.default.createDirectory(at: crashes, withIntermediateDirectories: true) // store-ok: the window's own container
        folder = crashes
        let warning = """
            This exception was thrown more than \(freshSeconds) seconds before the window died, \
            so it may not be what killed it; the crash report has the stack it died on.


            """
        stale = (strdup(warning)!, strlen(warning))
        // Touched once here, so the first read in a signal handler is not a lazy initialiser.
        _ = uptime()

        preprocessor = objc_setExceptionPreprocessor { thrown in
            let thrown = CrashHook.preprocessor.map { $0(thrown) } ?? thrown
            if let exception = thrown as? NSException { CrashHook.keep(exception) }
            return thrown
        }
        NSSetUncaughtExceptionHandler { exception in
            // Not a signal handler yet: the process aborts when this returns.
            CrashHook.keep(exception)
            if CrashHook.writePending() {
                CrashHook.log.fault("uncaught \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "", privacy: .public)")
            }
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

    /// Seconds since boot: `clock_gettime` is safe in a signal handler, `Date` is not.
    private static func uptime() -> Int {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC_RAW, &now)
        return now.tv_sec
    }

    private static func keep(_ exception: NSException) {
        guard let folder else { return }
        let date = Date.now
        let stamp = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let path = strdup(folder.appendingPathComponent("crash-\(stamp).txt").path)!
        let note = strdup(note(for: exception, at: date))!
        let kept = Pending(path: path, note: note, length: strlen(note), thrown: uptime())
        os_unfair_lock_lock(&lock)
        let old = pending
        pending = kept
        os_unfair_lock_unlock(&lock)
        if let old { free(old.path); free(old.note) }
    }

    /// Writes the last exception kept, once, and says whether it did. Safe in a signal
    /// handler: it takes the lock only if it is free (the thread that died may hold it),
    /// and the buffers it writes were made when the exception was thrown.
    @discardableResult
    private static func writePending() -> Bool {
        let locked = os_unfair_lock_trylock(&lock)
        let kept = pending
        pending = nil
        if locked { os_unfair_lock_unlock(&lock) }
        guard let kept else { return false }
        let file = open(kept.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard file >= 0 else { return false }
        if uptime() - kept.thrown > freshSeconds, let stale {
            _ = write(file, stale.text, stale.length)
        }
        var written = 0
        while written < kept.length {
            let wrote = write(file, kept.note + written, kept.length - written)
            if wrote <= 0 { break }
            written += wrote
        }
        close(file)
        return written == kept.length
    }
}
