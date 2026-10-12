import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// Who is on the other end of a Unix socket, as the kernel says rather than as the
/// caller does.
///
/// The daemon's socket is the whole of the daemon: whatever reaches it can start
/// agents, answer their questions and type into their terminals. A file's mode is
/// what normally keeps other people out, and it still does, but only because the
/// folder happens to be private; this says it on purpose, on every connection, on
/// the Mac and on a Linux server alike.
enum PeerCredentials {
    /// The effective uid of the process that connected, or nil if the kernel would
    /// not say.
    static func uid(of fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        #else
        return linuxCredentials(of: fd)?.uid
        #endif
    }

    /// The pid of the process that connected, taken when it connected. A process that
    /// has since exited leaves a number that means nothing, which the lineage walk
    /// treats as a stranger.
    static func pid(of fd: Int32) -> pid_t? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
        #else
        return linuxCredentials(of: fd).flatMap { $0.pid > 0 ? $0.pid : nil }
        #endif
    }

    #if !canImport(Darwin)
    private static func linuxCredentials(of fd: Int32) -> ucred? {
        var credentials = ucred()
        var size = socklen_t(MemoryLayout<ucred>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 else { return nil }
        return credentials
    }
    #endif

    /// The parent of a process, or nil once there is none worth naming.
    static func parent(of pid: pid_t) -> pid_t? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
        #else
        // `/proc/<pid>/stat` is "pid (name) state ppid …", and the name may itself hold
        // spaces or parentheses, so the fields are counted from the last ")".
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 1, let parent = pid_t(fields[1]) else { return nil }
        return parent > 1 ? parent : nil
        #endif
    }

    /// What `/proc/<pid>/status` says of a process: its name, its real uid and its parent.
    /// Readable for every process, whoever owns it, unless /proc is mounted `hidepid`.
    struct ProcessStatus: Equatable {
        var name: String
        var uid: uid_t
        var parent: pid_t

        /// Nil for anything without all three lines.
        init?(status: String) {
            var fields: [Substring: Substring] = [:]
            for line in status.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon]] = line[line.index(after: colon)...]
            }
            guard let name = fields["Name"]?.trimmingCharacters(in: .whitespaces),
                  let uid = fields["Uid"]?.split(whereSeparator: \.isWhitespace).first.flatMap({ uid_t($0) }),
                  let parent = fields["PPid"].flatMap({ pid_t($0.trimmingCharacters(in: .whitespaces)) })
            else { return nil }
            self.init(name: name, uid: uid, parent: parent)
        }

        init(name: String, uid: uid_t, parent: pid_t) {
            self.name = name
            self.uid = uid
            self.parent = parent
        }

        static func of(_ pid: pid_t) -> ProcessStatus? {
            (try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8)).flatMap(ProcessStatus.init(status:))
        }
    }

    /// The names OpenSSH's session processes go by: `sshd` before 9.8, `sshd-session` after.
    static let sshdNames: Set<String> = ["sshd", "sshd-session"]

    /// Whether `peer`, of this account, is an ssh login's own session process: the one that
    /// carries a `-L` forward to the socket, which is how a Mac reaches a server's daemon.
    /// Only the privileged sshd, as root, makes one, so its parent is a root sshd that is not
    /// pid 1 (in a container sshd may be pid 1, and every orphan is handed to pid 1). Nothing
    /// an agent starts has a root parent: it descends from the daemon, or, orphaned, from
    /// pid 1 or a `systemd --user` of this account. A name can be set by anyone, but not on
    /// a root process.
    static func isSSHSession(_ peer: ProcessStatus, parent: ProcessStatus?) -> Bool {
        guard sshdNames.contains(peer.name), peer.parent > 1, let parent, parent.uid == 0 else { return false }
        return sshdNames.contains(parent.name)
    }

    /// `isSSHSession`, read from /proc for `pid`.
    static func isSSHSession(_ pid: pid_t) -> Bool {
        guard let peer = ProcessStatus.of(pid) else { return false }
        return isSSHSession(peer, parent: ProcessStatus.of(peer.parent))
    }

    /// Whether `ancestor` is `pid` or one of its forebears, looking no further than
    /// `depth` generations. A runtime starts its MCP servers itself or through a
    /// wrapper or two (`npx`, a login shell), never through many.
    static func descends(_ pid: pid_t, from ancestor: pid_t, depth: Int = 8) -> Bool {
        var current: pid_t? = pid
        for _ in 0...depth {
            guard let here = current else { return false }
            if here == ancestor { return true }
            current = parent(of: here)
        }
        return false
    }
}
