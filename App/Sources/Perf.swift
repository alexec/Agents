import AgentsKitCore
import Foundation
import os

/// How long the window takes over what a person waits for (073): the first list after
/// launch, a project switch, opening a chat.
///
/// Each is an `os_signpost` interval, for Instruments, and a `perf` log line with the
/// milliseconds, for `scripts/perf-window.sh`. An interval ends when the main thread has
/// nothing left to do for it: the first moment the run loop is about to wait, after
/// SwiftUI has updated and Core Animation has committed, which is when the person sees it.
@MainActor
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.alexecollins.Agents", category: "perf")
    nonisolated static let log = Logger(subsystem: "com.alexecollins.Agents", category: "perf")

    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
        let started: ContinuousClock.Instant
    }

    static func begin(_ name: StaticString) -> Interval {
        HangWatchdog.note("\(name)")
        return Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
                        started: .now)
    }

    /// Ends `interval` once what it changed is on screen.
    static func endWhenDrawn(_ interval: Interval, _ detail: String = "") {
        whenIdle {
            signposter.endInterval(interval.name, interval.state)
            let took = ContinuousClock.now - interval.started
            log.notice("perf \(interval.name, privacy: .public) \(milliseconds(took), privacy: .public) ms \(detail, privacy: .public)")
        }
    }

    /// A cost measured where it ran, logged as it is: for work that is not a wait for
    /// the screen, such as a sweep (#176).
    nonisolated static func measured(_ name: StaticString, _ took: Duration, _ detail: String = "") {
        log.notice("perf \(name, privacy: .public) \(milliseconds(took), privacy: .public) ms \(detail, privacy: .public)")
    }

    /// How long `interval` has run so far, for a line that splits it: the data in hand
    /// against the drawing after it (#90).
    static func elapsed(_ interval: Interval) -> Int {
        milliseconds(ContinuousClock.now - interval.started)
    }

    /// Logs, once per name, the time from this process starting to the moment what is
    /// asked for is on screen.
    static func sinceLaunch(_ name: StaticString) {
        let key = "\(name)"
        guard !marked.contains(key) else { return }
        marked.insert(key)
        whenIdle {
            signposter.emitEvent(name)
            let took = Date().timeIntervalSince(processStarted)
            log.notice("perf \(name, privacy: .public) \(Int(took * 1000), privacy: .public) ms since launch")
        }
    }

    private static var marked: Set<String> = []

    nonisolated private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    /// Runs `body` the next time the main run loop is about to wait, after every other
    /// observer (SwiftUI's update, Core Animation's commit) has run.
    private static func whenIdle(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                          false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// When the kernel started this process.
    private static let processStarted: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()
}
