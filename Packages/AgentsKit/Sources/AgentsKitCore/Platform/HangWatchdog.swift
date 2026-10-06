#if canImport(Darwin)
import Darwin
import Foundation
import os

/// Writes up the main thread when it stops answering (#237).
///
/// A thread of its own sends the watched queue an empty block every half second. When
/// one has not run within `threshold`, the main thread is hung: every thread's stack goes
/// to a file in `folder` (the watched thread first), with the wall time, the load on the
/// machine and the last few things the person did (`note`). One file per hang: a second
/// sample is added to the same file if the hang is still on at `secondSample`, and the
/// time it took is added when the queue answers again. At most `keep` files are kept.
///
/// Cheap by construction: one block on the queue and one wake of this thread every half
/// second while all is well, and nothing sampled until something is wrong.
public final class HangWatchdog: Sendable {
    public struct Settings: Sendable {
        public var threshold: Double = 2
        public var secondSample: Double = 10
        public var interval: Double = 0.5
        public var keep = 20

        public init() {}
    }

    private static let log = Logger(subsystem: "com.alexecollins.agents", category: "hang")

    /// The folder hangs are written to: `~/Library/Logs/Agents/hangs`, which for a
    /// sandboxed app is the one in its container.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/Agents/hangs", directoryHint: .isDirectory)
    }

    // MARK: Breadcrumbs

    private struct Crumb { var time: Date; let what: String; var times = 1 }
    private static let crumbs = OSAllocatedUnfairLock(initialState: [Crumb]())
    static let crumbLimit = 12

    /// Remembers something the person just did, for the next hang's file. Repeats of the
    /// last one are counted rather than kept twice.
    public static func note(_ what: String) {
        let now = Date()
        crumbs.withLock { crumbs in
            if crumbs.last?.what == what {
                crumbs[crumbs.count - 1].time = now
                crumbs[crumbs.count - 1].times += 1
                return
            }
            crumbs.append(Crumb(time: now, what: what))
            if crumbs.count > crumbLimit { crumbs.removeFirst(crumbs.count - crumbLimit) }
        }
    }

    static func recentCrumbs() -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return crumbs.withLock { $0 }.map {
            "\(formatter.string(from: $0.time))  \($0.what)" + ($0.times > 1 ? " ×\($0.times)" : "")
        }
    }

    // MARK: Watching

    private let folder: URL
    private let settings: Settings
    private let watched: thread_act_t
    private let label: String
    private let ping: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let started = OSAllocatedUnfairLock(initialState: false)
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    /// Watches `watched`, which must be the thread `ping` runs its block on.
    public init(folder: URL = HangWatchdog.defaultFolder, settings: Settings = Settings(),
                watched: thread_act_t, label: String,
                ping: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.folder = folder
        self.settings = settings
        self.watched = watched
        self.label = label
        self.ping = ping
    }

    /// Watches the main thread. Call it on the main thread.
    public static func watchingMain(folder: URL = HangWatchdog.defaultFolder,
                                    settings: Settings = Settings()) -> HangWatchdog {
        precondition(Thread.isMainThread)
        return HangWatchdog(folder: folder, settings: settings, watched: ThreadSampler.currentThread(),
                            label: "main") { DispatchQueue.main.async(execute: $0) }
    }

    public func start() {
        guard started.withLock({ was in defer { was = true }; return !was }) else { return }
        let thread = Thread { [self] in run() }
        thread.name = "Agents hang watchdog"
        // Under a load average in the hundreds a lower class is not run for seconds,
        // and every hang would be this thread's own.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops watching, within one `interval` or as soon as a hang being written up ends.
    public func stop() {
        stopped.withLock { $0 = true }
    }

    private final class Answer: Sendable {
        let answered = OSAllocatedUnfairLock(initialState: false)
    }

    private func run() {
        while !stopped.withLock({ $0 }) {
            let answer = Answer()
            let sent = now()
            ping { answer.answered.withLock { $0 = true } }
            while !answer.answered.withLock({ $0 }), now() - sent < settings.threshold {
                pause(0.1)
            }
            guard !answer.answered.withLock({ $0 }) else {
                pause(settings.interval)
                continue
            }

            let file = record(hungFor: now() - sent)
            var sampledAgain = false
            while !answer.answered.withLock({ $0 }) {
                pause(0.25)
                if !sampledAgain, now() - sent >= settings.secondSample {
                    sampledAgain = true
                    append(to: file, sample(heading: "Still hung after \(seconds(now() - sent)):"))
                }
            }
            let took = now() - sent
            append(to: file, "The \(label) thread answered after \(seconds(took)).\n")
            Self.log.error("the \(self.label, privacy: .public) thread hung for \(self.seconds(took), privacy: .public); see \(file?.path ?? "(not written)", privacy: .public)")
        }
    }

    private func record(hungFor waited: Double) -> URL? {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let crumbs = Self.recentCrumbs()
        var text = """
            Agents: the \(label) thread stopped answering (#237)
            When: \(ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]))
            Unanswered for: \(seconds(waited)) (sampled at the \(seconds(settings.threshold)) threshold)
            Process: \(ProcessInfo.processInfo.processName) \(getpid()), version \(version), \(Bundle.main.bundlePath)
            Load average: \(loads.map { String(format: "%.2f", $0) }.joined(separator: " ")) on \(ProcessInfo.processInfo.activeProcessorCount) cores
            Last actions (oldest first):
            \(crumbs.isEmpty ? "  (none)" : crumbs.map { "  " + $0 }.joined(separator: "\n"))


            """
        text += sample(heading: "Threads (\(label) first):")

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
            let file = folder.appending(path: formatter.string(from: Date()) + ".txt")
            try text.write(to: file, atomically: true, encoding: .utf8)
            prune()
            Self.log.fault("the \(self.label, privacy: .public) thread is hung; stacks in \(file.path, privacy: .public)")
            return file
        } catch {
            Self.log.fault("the \(self.label, privacy: .public) thread is hung; could not write it up: \(error.localizedDescription, privacy: .public)\n\(text, privacy: .public)")
            return nil
        }
    }

    private func sample(heading: String) -> String {
        heading + "\n" + ThreadSampler.describe(ThreadSampler.sampleAll(first: watched), firstLabel: label) + "\n"
    }

    private func append(to file: URL?, _ text: String) {
        guard let file, let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Keeps the newest `keep` write-ups. Their names are timestamps, so they sort by age.
    func prune() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in files.dropLast(settings.keep) { try? FileManager.default.removeItem(at: old) }
    }

    /// Seconds of uptime, which stands still while the Mac sleeps: a sleep is no hang.
    private func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private func pause(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.1f s", value)
    }
}
#endif
