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
