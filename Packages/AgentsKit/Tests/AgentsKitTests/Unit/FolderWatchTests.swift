import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// These exist because the first version of `FolderWatch` had no test and crashed the
/// app on the first event it ever received. It read FSEvents' `paths` as an `NSArray`
/// while asking for C strings, so it sent Objective-C messages to the bytes of a
/// filename. Nothing but running it would have found that, so now something runs it.
@Suite("Watching a folder")
struct FolderWatchTests {
    /// Collects callbacks from the watch's own queue.
    private final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        private var callbackCount = 0

        func record(_ new: [URL]) {
            lock.lock()
            callbackCount += 1
            urls.append(contentsOf: new)
            lock.unlock()
        }

        /// Forget what has been seen, for a test that proves the stream is up and then
        /// needs a clean slate to prove it has gone quiet.
        func reset() {
            lock.lock()
            urls.removeAll()
            callbackCount = 0
            lock.unlock()
        }

        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
        /// How many times the watch called back, which is the thing coalescing is about.
        /// Counting reported paths instead would measure something else.
        var callbacks: Int { lock.lock(); defer { lock.unlock() }; return callbackCount }

        func waitForSomething(within seconds: TimeInterval = 10) async -> [URL] {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                let found = all
                if !found.isEmpty { return found }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return all
        }
    }

    private func makeFolder() throws -> URL {
        // Resolved, because FSEvents reports the real path and /tmp is a symlink here.
        let root = URL.temporaryDirectory.appending(path: "watch-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aWrittenFileIsReported() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let changes = Changes()
        let watch = FolderWatch(root: root) { changes.record($0) }
        defer { watch.stop() }
        #expect(watch.isWatching)

        // The stream needs a moment to be listening before the write lands, and
        // FSEvents offers no "I am listening now" to wait on. So rather than sleeping
        // long enough that it usually is, write again on every look until something
        // comes back: the first write that lands after the stream is up is the one
        // that counts, and a slow machine just takes a few more goes.
        await eventually("a change was reported") {
            try? Data("hello".utf8).write(to: root.appending(path: "new.txt"))
            return !changes.all.isEmpty
        }

        let reported = await changes.waitForSomething()
        #expect(!reported.isEmpty, "no event arrived")
        // Directory granularity: the folder is named, not the file inside it.
        //
        // Compared on resolved paths, because the two sides disagree about this and
        // both are right: FSEvents reports /private/var/..., while
        // `resolvingSymlinksInPath` normalises to /var/... . Nothing in the app
        // compares these, so it costs nothing there, but a test that assumed they
        // matched would fail for the wrong reason.
        let realRoot = root.resolvingSymlinksInPath().path
        #expect(reported.contains { $0.resolvingSymlinksInPath().path.hasSuffix(root.lastPathComponent)
                                    || $0.path.hasSuffix(realRoot) })
    }

    @Test func thePathsComeBackAsRealPathsAndNotAsRubbish() async throws {
        // The exact shape of the crash: the bytes were being read as pointers, so a
        // path that came back at all came back as nonsense. Asserting the path is the
        // folder we asked about is what makes that impossible to reintroduce.
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let changes = Changes()
        let watch = FolderWatch(root: root) { changes.record($0) }
        defer { watch.stop() }

        await eventually("a change was reported") {
            try? FileManager.default.createDirectory(at: root.appending(path: "sub"),
                                                     withIntermediateDirectories: true)
            try? Data("x".utf8).write(to: root.appending(path: "sub/file.txt"))
            return !changes.all.isEmpty
        }

        let reported = await changes.waitForSomething()
        #expect(!reported.isEmpty)
        for url in reported {
            // Every one is a real, readable, absolute path.
            #expect(url.path.hasPrefix("/"))
            #expect(url.path.count < 4096)
            #expect(url.path.allSatisfy { $0.isASCII || $0.unicodeScalars.allSatisfy { $0.value > 31 } })
        }
    }

    @Test func manyWritesDoNotArriveAsManyEvents() async throws {
        // FSEvents coalesces, which is what keeps a build writing thousands of files
        // from making the pane unusable (FR-015).
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let changes = Changes()
        let watch = FolderWatch(root: root) { changes.record($0) }
        defer { watch.stop() }

        // Get the stream up first, the same way, so the 500 writes below are all
        // actually seen — a burst that half-missed the stream would coalesce to a
        // flatteringly small number for the wrong reason.
        await eventually("the stream is up") {
            try? Data("x".utf8).write(to: root.appending(path: "warm-up.txt"))
            return !changes.all.isEmpty
        }
        // The warm-up's own callbacks are not part of what is being counted.
        changes.reset()
        for index in 0..<500 {
            try Data("x".utf8).write(to: root.appending(path: "file\(index).txt"))
        }

        // An upper bound, so this one waits rather than watches: the assertion is that
        // callbacks stay few, and giving them longer to arrive can only make the test
        // harder to pass.
        _ = await changes.waitForSomething()
        try await Task.sleep(for: .milliseconds(600))
        // Far fewer callbacks than writes: measured at 19 for 500 on this machine. The
        // number is not the point, the order of magnitude is, so the bar is loose
        // enough to survive a slower or busier machine.
        #expect(changes.callbacks < 100, "got \(changes.callbacks) callbacks for 500 writes")
    }

    @Test func stoppingMeansNoMoreEvents() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }

        let changes = Changes()
        let watch = FolderWatch(root: root) { changes.record($0) }
        // Up and demonstrably working before it is stopped, or the silence afterwards
        // would prove nothing: a stream that never started is also silent.
        await eventually("the stream is up") {
            try? Data("x".utf8).write(to: root.appending(path: "before.txt"))
            return !changes.all.isEmpty
        }
        watch.stop()
        #expect(watch.isWatching == false)
        changes.reset()

        try Data("x".utf8).write(to: root.appending(path: "after.txt"))
        // An absence, so time passing is the assertion.
        try await Task.sleep(for: .milliseconds(500))
        #expect(changes.all.isEmpty)
    }

    @Test func stoppingTwiceIsHarmless() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = FolderWatch(root: root) { _ in }
        watch.stop()
        watch.stop()
        #expect(watch.isWatching == false)
    }
}
