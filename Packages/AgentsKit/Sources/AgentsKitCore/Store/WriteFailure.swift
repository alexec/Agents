import Foundation

/// A write the disk refused, in words for the person (#88): what could not be kept, why,
/// and what to do about it.
///
/// Only the three causes a person can do something about are recognised: a full disk,
/// a folder they may not write to, and a disk that cannot be written at all. Anything
/// else is not one of these and is left to whoever caught it, so a bug is never dressed
/// up as advice to free some space.
///
/// The daemon writes the sentence, because it knows which machine it is on. The window
/// and the phone show it as it is: in the alert a refused call raises, and in the one a
/// write nobody was waiting on raises through `storage/writeFailed`.
public struct WriteFailure: Codable, Sendable, Equatable {
    public enum Cause: String, Codable, Sendable {
        case diskFull
        case notAllowed
        case readOnly
    }

    public var cause: Cause
    /// The file or folder that refused, when the error named one.
    public var path: String?
    /// What could not be kept, as a phrase that fits "so … could not be saved".
    public var what: String
    /// The sentence to show.
    public var message: String

    public init(cause: Cause, path: String?, what: String, machine: String = WriteFailure.thisMachine) {
        self.cause = cause
        self.path = path
        self.what = what
        self.message = Self.sentence(cause, path: path, what: what, machine: machine)
    }

    /// Nil when the error is none of the three.
    public init?(_ error: any Error, keeping what: String, machine: String = WriteFailure.thisMachine) {
        guard let (cause, path) = Self.cause(of: error) else { return nil }
        self.init(cause: cause, path: path, what: what, machine: machine)
    }

    /// Nil when git's own words name none of the three. For the commands whose stderr is
    /// all there is: `git worktree add` says "No space left on device", not an errno.
    public init?(gitMessage: String, keeping what: String, machine: String = WriteFailure.thisMachine) {
        guard let cause = Self.cause(ofMessage: gitMessage) else { return nil }
        self.init(cause: cause, path: nil, what: what, machine: machine)
    }

    /// How the daemon names the machine it runs on, as the person would.
    public static var thisMachine: String {
        #if os(macOS)
        "Your Mac"
        #else
        "The server"
        #endif
    }

    static func sentence(_ cause: Cause, path: String?, what: String, machine: String) -> String {
        let folder = path.map { "“\(Self.shown($0))”" }
        switch cause {
        case .diskFull:
            return "\(machine) is out of disk space, so \(what) could not be saved. Free some space, then try again."
        case .notAllowed:
            #if os(macOS)
            let fix = "Check its permissions in the Finder (Get Info, then Sharing & Permissions), then try again."
            #else
            let fix = "Check who owns it and its permissions, then try again."
            #endif
            return "Agents is not allowed to write to \(folder ?? "that folder"), so \(what) could not be saved. \(fix)"
        case .readOnly:
            return "\(folder ?? "That folder") is on a disk that cannot be written to, so \(what) could not be saved. Use a folder on another disk."
        }
    }

    /// The home folder as `~`, which is how the person knows it.
    static func shown(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmed.isEmpty, path == trimmed || path.hasPrefix(trimmed + "/") else { return path }
        return "~" + path.dropFirst(trimmed.count)
    }

    /// The cause and the path, from the error or any error under it.
    public static func cause(of error: any Error) -> (Cause, String?)? {
        var current: NSError? = error as NSError
        var path: String?
        while let error = current {
            path = path ?? (error.userInfo[NSFilePathErrorKey] as? String)
                ?? (error.userInfo[NSURLErrorKey] as? URL)?.path(percentEncoded: false)
            if let cause = cause(domain: error.domain, code: error.code) { return (cause, path) }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static func cause(domain: String, code: Int) -> Cause? {
        switch domain {
        case NSCocoaErrorDomain:
            switch code {
            case CocoaError.fileWriteOutOfSpace.rawValue: return .diskFull
            case CocoaError.fileWriteNoPermission.rawValue: return .notAllowed
            case CocoaError.fileWriteVolumeReadOnly.rawValue: return .readOnly
            default: return nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case ENOSPC, EDQUOT: return .diskFull
            case EACCES, EPERM: return .notAllowed
            case EROFS: return .readOnly
            default: return nil
            }
        default:
            return nil
        }
    }

    static func cause(ofMessage message: String) -> Cause? {
        if message.contains("No space left on device") || message.contains("Disk quota exceeded") { return .diskFull }
        if message.contains("Read-only file system") { return .readOnly }
        if message.contains("Permission denied") || message.contains("Operation not permitted") { return .notAllowed }
        return nil
    }
}
