import Foundation

/// A repository somebody pasted, understood well enough to clone it and name it (027).
///
/// Three spellings are accepted, the three a person copies from a forge: `https://`,
/// `ssh://`, and the scp-like `git@host:owner/repo`. Everything else is refused before
/// anything is run — `http://` and `git://` send the code in the clear, and a local path
/// is a folder, which New project already has a picker for.
///
/// In Core so the window can say "that is not a URL" as it is typed, and the daemon can
/// say it again without trusting the window.
public struct GitRemote: Sendable, Hashable {
    /// Exactly what was given, trimmed. This is what is handed to git.
    public let url: String
    /// Lowercased, without a user or a port.
    public let host: String
    /// As written, without leading or trailing slashes.
    public let path: String

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing git would read as an option, and nothing that needs quoting.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"),
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        let host: String
        let path: String
        if trimmed.contains("://") {
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "ssh",
                  let named = components.host, !named.isEmpty else { return nil }
            host = named
            path = components.path
        } else if let colon = trimmed.firstIndex(of: ":") {
            // `[user@]host:path`. Git reads it this way only when no slash comes before
            // the colon, which is also what keeps `./a:b` a path.
            let before = trimmed[..<colon]
            guard !before.contains("/") else { return nil }
            let named = before.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            guard !named.isEmpty else { return nil }
            host = named
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil
        }

        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty else { return nil }
        self.url = trimmed
        self.host = host.lowercased()
        self.path = cleanPath
        guard !folderName.isEmpty, folderName != ".", folderName != ".." else { return nil }
    }

    /// The folder it becomes: the last part of the path without `.git`, case kept.
    public var folderName: String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    /// What two spellings of the same repository have in common: the HTTPS and SSH
    /// forms of it, with or without `.git`, in any case. Forges treat owner and name
    /// case-insensitively, and a false match here only ever adopts a checkout the
    /// person already has.
    public var identity: String {
        var trimmed = path
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        return "\(host)/\(trimmed)".lowercased()
    }
}
