#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import AgentsKitCore
import Foundation

/// What an accept loop does when `accept` fails (#201).
///
/// The daemon's loop used to return on the first failure, so one brief descriptor spike
/// (`EMFILE` while agents, terminals and git children were busy) left daemon.sock taking
/// nobody for the rest of the process's life, at 0 % CPU and with nothing in the log. The
/// relay gate's and the tunnel socket's loops went straight round again instead, and spun
/// a core for as long as the spike lasted.
///
/// So: out of descriptors or memory is waited out, 10 ms doubling to a second, said once
/// and then counted; a connection that went away before it was taken is skipped; and only
/// a listener that is no longer one (`EBADF`, `EINVAL`, `ENOTSOCK`) ends the loop.
///
/// One spare descriptor is held for the case the waiting cannot fix on its own: under
/// `EMFILE` the queue fills with clients that wait for an answer that is not coming. It is
/// let go just long enough to take the oldest of them and close it, so that client hears
/// "closed" at once and can try again, and then held again.
///
/// Used from the loop's own thread only.
final class AcceptFailures {
    enum Next: Equatable {
        /// Go round again: the wait, if any, has been had.
        case retry
        /// The listener is gone or was never one.
        case stop
    }

    static let firstWait: TimeInterval = 0.01
    static let longestWait: TimeInterval = 1

    private let name: String
    private var wait: TimeInterval = 0
    private var notices = RepeatedNotice()
    /// Whether this run of failures has been written down, so its end is too.
    private var said = false
    private var spare: Int32
    private let pause: (TimeInterval) -> Void

    /// `name` starts every line in the log. `pause` is for tests.
    init(name: String, pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.name = name
        self.pause = pause
        spare = Self.openSpare()
    }

    deinit {
        if spare >= 0 { _ = POSIX.close(spare) }
    }

    /// What to do after `accept(listener)` failed with `error`. Waits before answering
    /// when waiting is what it takes.
    func after(_ error: Int32, listener: Int32) -> Next {
        switch error {
        case EINTR, EAGAIN, ECONNABORTED, EPROTO:
            // The connection went before it was taken, or nothing happened at all.
            return .retry
        case EBADF, EINVAL, ENOTSOCK:
            return .stop
        case EMFILE, ENFILE:
            // The spare is let go first, so the line can be written even if the log has
            // to be opened again, and held again once one waiting client is turned away.
            letGoOfSpare()
            say(error)
            refuseOne(listener)
            spare = Self.openSpare()
            backOff()
            return .retry
        default:
            // ENOBUFS, ENOMEM, and whatever else a kernel says: waited out, never a spin and
            // never the end of the listener.
            say(error)
            backOff()
            return .retry
        }
    }

    /// A connection was taken: the next failure starts from the shortest wait.
    func accepted() {
        guard wait > 0 else { return }
        wait = 0
        if said {
            said = false
            DaemonLog.shared.write("\(name): accepting again")
        }
    }

    /// Once, then counted. Nothing here may need a descriptor of its own: a new date
    /// formatter, for one, loads ICU's data from disk and crashes without one.
    private func say(_ error: Int32) {
        let line = "\(name): accept failed (\(String(cString: strerror(error)))); waiting and trying again"
        switch notices.note(line, at: Date()) {
        case .first?:
            said = true
            DaemonLog.shared.write(line + " (again within the hour is counted, not logged)")
        case .again(let times, let since)?:
            said = true
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            DaemonLog.shared.write(line + ": \(times) more time\(times == 1 ? "" : "s") in the last \(minutes) minutes")
        case nil:
            break
        }
    }

    private func backOff() {
        wait = wait == 0 ? Self.firstWait : min(wait * 2, Self.longestWait)
        pause(wait)
    }

    private func letGoOfSpare() {
        if spare >= 0 { _ = POSIX.close(spare) }
        spare = -1
    }

    /// Out of descriptors: the oldest waiting client is taken and closed, on the slot the
    /// spare left.
    private func refuseOne(_ listener: Int32) {
        guard listener >= 0 else { return }
        // Only when one is there now: a blocking accept would wait for the next client
        // and turn that one away instead.
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&ready, 1, 0) == 1, ready.revents & Int16(POLLIN) != 0 else { return }
        let client = accept(listener, nil, nil)
        if client >= 0 { _ = POSIX.close(client) }
    }

    private static func openSpare() -> Int32 {
        open("/dev/null", O_RDONLY | O_CLOEXEC)
    }
}
