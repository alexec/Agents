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
    /// What has already been sealed, so a host saying the same need again does not buzz twice.
    private struct Posted {
        var device: UUID
        var alert: Bool
        var at: Date
    }
    private var postedTo: [NeedID: Posted] = [:]
    private var plane: ControlPlane?

    func start() {
        Task { await run() }
    }

    /// Notices come from hosts, unsealed, rather than from this Mac's daemon already sealed.
    func follow(_ plane: ControlPlane) {
        self.plane = plane
    }

    /// A host's `attention/need`. Picks the device from every client's presence and seals
    /// to it (058, R6). A withdrawal, or a person at a screen, takes the banner down.
    func heard(_ params: JSONValue?) async {
        guard let plane, let message = try? params?.decode(DaemonAPI.AttentionNeed.self) else { return }
        if let id = message.withdraw {
            await withdraw(id)
            return
        }
        guard let need = message.need else { return }
        let presences = await plane.router.foldedPresences()
        let devices = await plane.devicesForNotices()
        let now = Date()
        guard let chosen = ControlNotices.device(for: need, presences: presences, devices: devices,
                                                 delivery: delivery(of: need.id), now: now),
              let device = devices.first(where: { $0.id == chosen.id }),
              let envelope = try? Envelope.seal(need.headline, to: device.publicKey) else {
            await withdraw(need.id)
            return
        }
        if let previous = postedTo[need.id], previous.device == chosen.id {
            // Same device: a later decision that would show it quietly must not replace
            // the banner, and one that would buzz again is the ladder saying the interval passed.
            if previous.alert || !chosen.alert { return }
        }
        if let previous = postedTo[need.id], previous.device != chosen.id {
            await post(MailboxItem(needID: need.id, device: previous.device, envelope: nil,
                                   alert: false, postedAt: now))
        }
        postedTo[need.id] = Posted(device: chosen.id, alert: chosen.alert, at: now)
        await post(MailboxItem(needID: need.id, device: chosen.id, envelope: envelope,
                               alert: chosen.alert, postedAt: now))
    }

    private func delivery(of id: NeedID) -> Delivery? {
        guard let posted = postedTo[id] else { return nil }
        return Delivery(needID: id, to: .device(posted.device), alertedAt: posted.at,
                        alertCount: posted.alert ? 1 : 0)
    }

    private func withdraw(_ id: NeedID) async {
        guard let previous = postedTo.removeValue(forKey: id) else { return }
        await post(MailboxItem(needID: id, device: previous.device, envelope: nil, alert: false, postedAt: Date()))
    }

    private func post(_ item: MailboxItem) async {
        do {
            try await prepareOnce()
            try await mailbox.post(item)
            log("mailbox: posted \(item.envelope == nil ? "a withdrawal" : "a need") for \(item.device)")
        } catch {
            log("mailbox: posting failed: \(error)")
        }
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
