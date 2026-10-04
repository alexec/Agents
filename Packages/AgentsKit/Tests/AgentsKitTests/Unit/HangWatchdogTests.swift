import Darwin
import Foundation
import Testing
@testable import AgentsKitCore

/// A thread that sits in a function with a name the stack must show, until told to go.
private final class Stuck: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private(set) var port: thread_act_t = 0

    func start() {
        Thread { [self] in
            port = ThreadSampler.currentThread()
            ready.signal()
            hangWatchdogTestMarker(release)
        }.start()
        ready.wait()
    }

    func finish() { release.signal() }
}

@inline(never)
func hangWatchdogTestMarker(_ release: DispatchSemaphore) {
    release.wait()
}

/// The watchdog that writes up a hung main thread (#237).
@Suite("Hang watchdog")
struct HangWatchdogTests {
    private func folder() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "HangWatchdogTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("a stuck thread's stack names the function it is stuck in")
    func samplesAStuckThread() throws {
        let stuck = Stuck()
        stuck.start()
        defer { stuck.finish() }
        let stack = try #require(ThreadSampler.sample(stuck.port))
        let text = ThreadSampler.describe([stack])
        #expect(text.contains("hangWatchdogTestMarker"))
        #expect(text.contains("Binary images:"))
    }

    @Test("every thread is sampled, the one asked for first")
    func sampleAllPutsTheWatchedThreadFirst() {
        let stuck = Stuck()
        stuck.start()
        defer { stuck.finish() }
        let stacks = ThreadSampler.sampleAll(first: stuck.port)
        #expect(stacks.count > 1)
        let first = ThreadSampler.describe(Array(stacks.prefix(1)), firstLabel: "watched")
        #expect(first.contains("Thread 0 (watched)"))
        #expect(first.contains("hangWatchdogTestMarker"))
    }

    @Test("a hang is written once, with the stack, the last actions and how long it took")
    func writesOneFilePerHang() async throws {
        let queue = DispatchQueue(label: "HangWatchdogTests.watched")
        let ports = Ports()
        queue.sync { ports.port = ThreadSampler.currentThread() }
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = HangWatchdog.Settings()
        settings.threshold = 0.3
        settings.secondSample = 100
        settings.interval = 0.05
        // The queue's worker thread is not fixed, so the stuck one is found among all.
        let watchdog = HangWatchdog(folder: folder, settings: settings, watched: ports.port, label: "watched") {
            queue.async(execute: $0)
        }
        HangWatchdog.note("click Send")
        HangWatchdog.note("typing")
        HangWatchdog.note("typing")
        watchdog.start()
        defer { watchdog.stop() }

        let release = DispatchSemaphore(value: 0)
        queue.async { hangWatchdogTestMarker(release) }
        try await Task.sleep(for: .seconds(1.2))
        release.signal()
        try await Task.sleep(for: .seconds(0.6))

        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(text.contains("stopped answering"))
        #expect(text.contains("hangWatchdogTestMarker"))
        #expect(text.contains("click Send"))
        #expect(text.contains("typing ×2"))
        #expect(text.contains("thread answered after"))
    }

    @Test("a queue that keeps answering writes nothing")
    func quietQueueWritesNothing() async throws {
        let queue = DispatchQueue(label: "HangWatchdogTests.quiet")
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = HangWatchdog.Settings()
        settings.threshold = 0.3
        settings.interval = 0.05
        let watchdog = HangWatchdog(folder: folder, settings: settings, watched: 0, label: "quiet") {
            queue.async(execute: $0)
        }
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .seconds(0.8))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("only the newest write-ups are kept")
    func keepsTheNewest() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (0..<25).map { String(format: "2026-10-04T12-00-%02d.000.txt", $0) }
        for name in names { try "hang".write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }
        try "not ours".write(to: folder.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        var settings = HangWatchdog.Settings()
        settings.keep = 20
        HangWatchdog(folder: folder, settings: settings, watched: 0, label: "main") { $0() }.prune()

        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == Array(names.suffix(20)) + ["notes.md"])
    }
}

private final class Ports: @unchecked Sendable {
    var port: thread_act_t = 0
}
