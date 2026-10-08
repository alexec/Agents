import Foundation

/// The servers named in an ssh config (#429).
///
/// Only the names are read here: every `Host` line's concrete patterns, following
/// `Include` (globs, `~`, and paths relative to `~/.ssh`) wherever it appears. What each
/// name means — `HostName`, `User`, `Port`, `ProxyJump`, `Match` blocks, wildcard
/// defaults — is asked of `ssh -G`, which is OpenSSH's own reading of the same files. No
/// Swift library reads `Match` and `Include` as ssh does, so ssh is the library.
public enum SSHConfigHosts {
    /// The concrete `Host` names in `file` and everything it includes, each once, in the
    /// order they appear. Wildcard and negated patterns are defaults, not servers.
    public static func aliases(in file: URL, sshFolder: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folder = sshFolder ?? file.deletingLastPathComponent()
        var seen: Set<String> = []
        var visited: Set<String> = []
        var names: [String] = []
        read(file, folder: folder, home: home, depth: 0, visited: &visited) { name in
            if seen.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names
    }

    private static func read(_ file: URL, folder: URL, home: URL, depth: Int, visited: inout Set<String>,
                             _ found: (String) -> Void) {
        // ssh gives up at 16 levels of Include; so does this, and never reads a file twice.
        guard depth < 16, visited.insert(file.standardizedFileURL.path).inserted,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let words = self.words(String(line))
            guard let keyword = words.first?.lowercased() else { continue }
            switch keyword {
            case "host":
                for pattern in words.dropFirst() where isConcrete(pattern) { found(pattern) }
            case "include":
                for pattern in words.dropFirst() {
                    for included in expand(pattern, folder: folder, home: home) {
                        read(included, folder: folder, home: home, depth: depth + 1, visited: &visited, found)
                    }
                }
            default:
                continue
            }
        }
    }

    /// A name a person would ssh to: no `*` or `?`, not negated.
    static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
    }

    /// A config line's keyword and arguments: `#` starts a comment, `=` may follow the
    /// keyword, and double quotes hold spaces.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quoted = false
        var inWord = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                inWord = true
                continue
            }
            if !quoted, character == "#" { break }
            // `Keyword=value` and `Keyword = value`: the one `=` after the keyword is a space.
            let equals = character == "=" && (words.isEmpty || (words.count == 1 && !inWord))
            if !quoted, character.isWhitespace || equals {
                if inWord { words.append(current) }
                current = ""
                inWord = false
                continue
            }
            current.append(character)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }

    /// An `Include` argument as files: `~` is the home folder, a relative path is in
    /// `~/.ssh`, and a glob matches what is there, in order.
    static func expand(_ pattern: String, folder: URL, home: URL) -> [URL] {
        var path = pattern
        if path == "~" { path = home.path } else if path.hasPrefix("~/") { path = home.path + "/" + path.dropFirst(2) }
        if !path.hasPrefix("/") { path = folder.path + "/" + path }
        var matched = glob_t()
        defer { globfree(&matched) }
        guard glob(path, 0, nil, &matched) == 0 else { return [] }
        return (0..<Int(matched.gl_pathc)).compactMap { index in
            matched.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    // MARK: What ssh -G said

    /// One name as `ssh -G` resolved it: lowercase keywords to their first value.
    public struct Resolved: Sendable, Hashable {
        public var alias: String
        public var options: [String: String]

        public init(alias: String, options: [String: String]) {
            self.alias = alias
            self.options = options
        }

        /// `ssh -G` output, a `keyword value` per line.
        public init(alias: String, output: String) {
            var options: [String: String] = [:]
            for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let key = parts.first?.lowercased(), options[key] == nil else { continue }
                options[key] = parts.count > 1 ? String(parts[1]) : ""
            }
            self.init(alias: alias, options: options)
        }

        public var hostName: String { options["hostname"] ?? alias }

        /// `user@hostname:port`, the port left out when it is 22.
        public var display: String {
            let user = options["user"].map { $0 + "@" } ?? ""
            let port = options["port"].flatMap { $0 == "22" ? nil : ":" + $0 } ?? ""
            return user + hostName + port
        }

        /// The hosts this one is reached through: each hop of `ProxyJump`, and the host
        /// an `ssh … bastion` `ProxyCommand` goes to.
        public var jumpHosts: [String] {
            var hosts: [String] = []
            if let jump = options["proxyjump"], jump.lowercased() != "none" {
                hosts += jump.split(separator: ",").map { SSHConfigHosts.hostPart(String($0)) }
            }
            if let command = options["proxycommand"], command.lowercased() != "none" {
                hosts += SSHConfigHosts.proxyCommandHosts(command)
            }
            return hosts.filter { !$0.isEmpty }
        }
    }

    /// The names that are a way in for another: never servers themselves, even when
    /// they answer.
    public static func bastions(_ resolved: [Resolved]) -> Set<String> {
        Set(resolved.flatMap(\.jumpHosts).map { $0.lowercased() })
    }

    public static func isBastion(_ host: Resolved, among bastions: Set<String>) -> Bool {
        bastions.contains(host.alias.lowercased()) || bastions.contains(host.hostName.lowercased())
    }

    /// `ssh://user@host:port` → `host`.
    static func hostPart(_ hop: String) -> String {
        var host = hop.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("[") , let close = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<close])
        }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    /// ssh's options that take a value, so the value is not read as the destination.
    private static let valued: Set<Character> = ["B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
                                                 "m", "O", "o", "p", "Q", "R", "S", "W", "w"]

    /// The host a `ProxyCommand` of the `ssh [options] bastion [command]` kind goes to,
    /// and any `-J` hop it names. Another program (`nc`, `cloudflared`) names none.
    static func proxyCommandHosts(_ command: String) -> [String] {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let start = words.firstIndex(where: { ($0 as NSString).lastPathComponent == "ssh" }) else { return [] }
        var hosts: [String] = []
        var index = start + 1
        while index < words.count {
            let word = words[index]
            if word == "--" {
                if index + 1 < words.count { hosts.append(hostPart(words[index + 1])) }
                break
            }
            if word.hasPrefix("-"), word.count >= 2 {
                let flag = word[word.index(after: word.startIndex)]
                if valued.contains(flag) {
                    // `-J hop` or `-Jhop`; any other value is skipped.
                    let value = word.count > 2 ? String(word.dropFirst(2)) : (index + 1 < words.count ? words[index + 1] : "")
                    if flag == "J" { hosts += value.split(separator: ",").map { hostPart(String($0)) } }
                    index += word.count > 2 ? 1 : 2
                } else {
                    index += 1
                }
                continue
            }
            if !word.contains("%h") { hosts.append(hostPart(word)) }
            break
        }
        return hosts
    }
}
