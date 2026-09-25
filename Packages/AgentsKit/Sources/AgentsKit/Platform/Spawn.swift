#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// What `posix_spawn`'s two handles are called here, which differs by platform (037).
///
/// Darwin makes them opaque pointers, imported as optionals that start out nil; Linux
/// makes them structs that start out zeroed. Code that spawns declares one of these,
/// hands it to `posix_spawnattr_init` like it always did, and does not care which.
#if canImport(Darwin)
public typealias SpawnAttributes = posix_spawnattr_t?
public typealias SpawnActions = posix_spawn_file_actions_t?
#else
public typealias SpawnAttributes = posix_spawnattr_t
public typealias SpawnActions = posix_spawn_file_actions_t
#endif

public enum Spawn {
    public static var noAttributes: SpawnAttributes {
        #if canImport(Darwin)
        nil
        #else
        posix_spawnattr_t()
        #endif
    }

    public static var noActions: SpawnActions {
        #if canImport(Darwin)
        nil
        #else
        posix_spawn_file_actions_t()
        #endif
    }

    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` on the Mac, which closes every descriptor the child
    /// was not handed explicitly. Linux has no such flag, so there it is nothing, and a
    /// child inherits whatever was not marked close-on-exec. Everything the daemon opens
    /// itself is marked (see `CloseOnExec.swift`), which is what stands in for it.
    public static var closeOnExecByDefault: Int32 {
        #if canImport(Darwin)
        POSIX_SPAWN_CLOEXEC_DEFAULT
        #else
        0
        #endif
    }
}

import Foundation

extension Spawn {
    public struct Failed: Error, Sendable, CustomStringConvertible {
        public var executable: String
        public var reason: String
        public var description: String { "\(executable): \(reason)" }
    }

    /// Start `executable` in a session of its own, with stdin from `/dev/null` and
    /// stdout and stderr appended to `log`, and do not wait for it.
    ///
    /// `POSIX_SPAWN_SETSID` is the whole trick: the child is not in the caller's process
    /// group, so the caller quitting, crashing or being force quit leaves it alone. This
    /// is how the window starts the Mac's daemon, and how `agentsd --detach` starts a
    /// server's (037), so the two are started the same way.
    @discardableResult
    public static func detached(executable: URL, arguments: [String], environment: [String: String],
                                log: URL) throws -> pid_t {
        var attributes: SpawnAttributes = noAttributes
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT (on the Mac) so the child starts with nothing of the caller's
        // but the three descriptors named below. It outlives the caller on purpose;
        // what it inherits would outlive it too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | closeOnExecByDefault))

        var actions: SpawnActions = noActions
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        guard status == 0 else {
            throw Failed(executable: executable.path, reason: String(cString: strerror(status)))
        }
        return pid
    }
}
