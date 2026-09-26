import Foundation

/// Run a blocking call — a socket read with a timeout, say — on a GCD thread, and wait
/// for it without holding a thread of the Swift concurrency pool.
///
/// A test that blocks a pool thread takes it from every other test in the process,
/// and from the daemon it is talking to. On a runner with three cores the pool has
/// about three threads, so two such reads waiting out their timeouts froze the whole
/// suite for minutes and failed a hundred tests at once (2026-09-26).
func offThePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: body()) }
    }
}
