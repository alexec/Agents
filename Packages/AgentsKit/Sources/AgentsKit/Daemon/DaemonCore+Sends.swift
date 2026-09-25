import AgentsKitCore
import Foundation

/// Doing a send once, however many times it arrives (037, FR-020).
///
/// Over ssh a connection can drop after the daemon acted and before its reply got back.
/// The window cannot tell that from a send that never arrived, so it sends again with the
/// same `sendID`. Seen before, the second is answered with the first's result, and a
/// second arriving while the first is still in hand waits for it rather than running
/// alongside.
///
/// Held in memory only, and only the last `sendMemory`. The window gives up retrying after
/// 30 seconds, and a daemon that restarted in between lost the runtime the first try went
/// to anyway, so doing the retry is then the right thing.
extension DaemonCore {
    static let sendMemory = 512

    func once(_ sendID: UUID?, _ work: @escaping @Sendable () async throws -> JSONValue) async throws -> JSONValue {
        guard let sendID else { return try await work() }
        if let earlier = recentSends[sendID] { return try await earlier.value }
        let task = Task { try await work() }
        recentSends[sendID] = task
        recentSendOrder.append(sendID)
        while recentSendOrder.count > Self.sendMemory {
            recentSends[recentSendOrder.removeFirst()] = nil
        }
        return try await task.value
    }
}
