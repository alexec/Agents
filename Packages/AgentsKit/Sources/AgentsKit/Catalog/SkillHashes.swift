#if canImport(CryptoKit)
import CryptoKit
import Foundation

/// The three hashes a skill is known by (059, research R5 and R6).
///
/// - `blobSHA`: git's SHA-1 of one file, which GitHub's tree lists for every file, so a
///   file from anywhere can be checked against the commit.
/// - `treeSHA`: git's SHA-1 of a folder, which the `skills` CLI records for a personal skill
///   (`skillFolderHash`).
/// - `computedHash`: the CLI's own SHA-256 of a folder, which it records for a project skill.
///
/// Each is checked against values made by the tools that define them (`git`, and the CLI's
/// function run under `node`), in `Fixtures/catalog/golden.json`.
///
/// Mac only, like everything in 059: CryptoKit is the Mac's, and the Linux daemon offers no
/// catalogue.
enum SkillHashes {
    /// git's blob id: SHA-1 of `blob <length>\0` and the bytes.
    static func blobSHA(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hex(hasher.finalize())
    }

    /// A folder hashed as git would hash it: files `100644` or `100755`, folders `40000`,
    /// entries in git's order, where a folder's name is compared as if it ended in `/`.
    /// A folder with no files in it is left out, as git has no way to hold one. A symbolic
    /// link is refused rather than hashed: a skill the app writes never has one.
    static func treeSHA(folder: URL) throws -> String {
        guard let sha = try treeID(folder) else { return emptyTree }
        return hex(sha)
    }

    /// The `skills` CLI's `computeSkillFolderHash`: SHA-256 over each file's path relative to
    /// the folder (with `/`), then its bytes, in JavaScript's `localeCompare` order of the
    /// paths. `.git` and `node_modules` are skipped, and so is anything not a plain file.
    static func computedHash(folder: URL) throws -> String {
        var files: [(path: String, url: URL)] = []
        try collect(folder, prefix: "", into: &files)
        files.sort { localeLess($0.path, $1.path) }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: try Data(contentsOf: file.url))
        }
        return hex(hasher.finalize())
    }

    /// The same, over files held in memory: what a preview stages, before it is on disk.
    static func computedHash(files: [(path: String, data: Data)]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { localeLess($0.path, $1.path) }) {
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: file.data)
        }
        return hex(hasher.finalize())
    }

    /// `a.localeCompare(b) < 0` as node computes it by default. Foundation's comparison
    /// under the `en` locale is ICU's too, and gave node's order on every name tried, down to
    /// `_` before `-` and lower case before upper.
    static func localeLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], range: nil, locale: english) == .orderedAscending
    }

    private static let english = Locale(identifier: "en")
    private static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    enum HashError: Error { case symbolicLink(String) }

    private static func treeID(_ folder: URL) throws -> Data? {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        var entries: [(sortKey: [UInt8], line: Data)] = []
        for name in names where name != ".git" {
            let url = folder.appending(path: name)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true { throw HashError.symbolicLink(url.path) }
            let mode: String
            let id: Data
            if values.isDirectory == true {
                guard let sub = try treeID(url) else { continue }
                mode = "40000"
                id = sub
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: url)
                mode = FileManager.default.isExecutableFile(atPath: url.path) ? "100755" : "100644"
                id = Data(rawSHA1(Data("blob \(data.count)\0".utf8) + data))
            } else {
                continue
            }
            var line = Data("\(mode) \(name)\0".utf8)
            line.append(id)
            let key = Array(name.utf8) + (mode == "40000" ? [UInt8(ascii: "/")] : [])
            entries.append((key, line))
        }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
        let body = entries.reduce(into: Data()) { $0.append($1.line) }
        return Data(rawSHA1(Data("tree \(body.count)\0".utf8) + body))
    }

    private static func collect(_ folder: URL, prefix: String, into files: inout [(path: String, url: URL)]) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let url = folder.appending(path: name)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            if values.isSymbolicLink == true { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if values.isDirectory == true {
                if name == ".git" || name == "node_modules" { continue }
                try collect(url, prefix: path, into: &files)
            } else if values.isRegularFile == true {
                files.append((path, url))
            }
        }
    }

    private static func rawSHA1(_ data: Data) -> [UInt8] { Array(Insecure.SHA1.hash(data: data)) }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
