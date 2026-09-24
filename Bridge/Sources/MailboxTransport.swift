import AgentsKit
import AgentsKitCore
import CloudKit
import Foundation

/// The third carrier, beside the socket and the LAN relay: what takes a need to a
/// device that is not here.
///
/// Not a `LineTransport`, because nothing comes back down it — a mailbox is written to
/// and a device is told. It is an ordinary client of the daemon: it connects over the
/// Unix socket like any window, hears `mailbox/post`, and does with CloudKit what it says. The daemon is handed nothing about CloudKit and the bridge
/// reads nothing from the device store; what to send, and to whom, arrives sealed.
///
/// It stays connected for as long as the bridge runs and comes back when the daemon
/// does. Nothing here is retried across a restart: a post that was lost while the
/// bridge was down is posted again by the daemon's next decision, and a device that
/// missed a banner finds the need in `attention/pending` when it next connects.
///
/// Withdrawals are the exception, and the daemon keeps them rather than this: a
/// withdrawal is about a need being over, so there is no next decision to repeat it.
/// The daemon holds each one in `attention.json` until a connection has said
/// `mailbox/carry`, which is the first thing this does on connecting (025).
@MainActor
final class MailboxTransport {
    private let mailbox = CloudKitMailbox()
    private let client = DaemonClient(link: SocketLink())
    private var prepared = false

    func start() {
        Task { await run() }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await client.connect(startIfNeeded: false)
                // Say what this connection is for. The daemon cannot otherwise tell it
                // from a window, and a withdrawal broadcast while nothing carries mail is
                // lost for good — the need it withdraws is over, so nothing will post it
                // again. It waits in the daemon until this has been said (025 US2).
                _ = try await client.call(DaemonAPI.Method.mailboxCarry)
                log("mailbox: connected to the daemon")
                for await notification in client.notifications() {
                    await carry(notification.method, notification.params)
                }
                log("mailbox: the daemon went away")
            } catch {
                // No daemon yet. Back in a while; nothing is lost by waiting.
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func carry(_ method: String, _ params: JSONValue?) async {
        do {
            switch method {
            case DaemonAPI.Notification.mailboxPost:
                guard let item = try params?.decode(MailboxItem.self) else { return }
                try await prepareOnce()
                try await mailbox.post(item)
                log("mailbox: posted \(item.envelope == nil ? "a withdrawal" : "a need") for \(item.device)")
            default:
                break
            }
        } catch {
            log("mailbox: \(method) failed: \(error)")
        }
    }

    private func prepareOnce() async throws {
        guard !prepared else { return }
        try await mailbox.prepare()
        prepared = true
    }
}
