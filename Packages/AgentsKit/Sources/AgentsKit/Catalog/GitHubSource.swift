#if canImport(CryptoKit)
import Foundation

/// A skill's repository on GitHub, read without `git` and, where it can be, without the API
/// (059, research R3 and R4).
///
/// - The commit comes from git's own ref list over HTTPS, which needs no key and has no limit.
/// - The file list is the API's tree at that commit: one request. Through the person's `gh`
///   when it is signed in (5,000 an hour, and the app never holds their token), anonymously
///   otherwise (60 an hour).
/// - A file's bytes come from `raw.githubusercontent.com` at the commit, which has no limit.
/// - When the API says the limit is spent, the whole commit comes as a tarball instead, and
///   only the skill's folder is kept.
struct GitHubSource: Sendable {
    let session: URLSession
    let endpoints: CatalogEndpoints
    /// The person's `gh`, or nil where it must not be used (a walk pointed at a fixture).
    let gh: GitHubCLI?

    static let timeout: TimeInterval = 10
    static let tarballLimit = 50 * 1024 * 1024

    struct Head: Equatable, Sendable {
        var commit: String
        var branch: String?
    }

    struct TreeEntry: Decodable, Equatable, Sendable {
        var path: String
        var mode: String
        var type: String
        var sha: String
        var size: Int?
    }

    /// The default branch's commit, from `info/refs?service=git-upload-pack`.
    func head(owner: String, repo: String) async throws -> Head {
        var components = URLComponents(url: endpoints.web.appending(path: "\(owner)/\(repo).git/info/refs"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "service", value: "git-upload-pack")]
        let data = try await get(components.url!)
        guard let head = Self.parseRefs(data) else { throw DaemonAPI.CatalogError.unreachable(host: host(endpoints.web)) }
        return head
    }

    /// `pkt-line` text: the first ref line is `<sha> HEAD\0<capabilities>`, and the
    /// capabilities name the branch as `symref=HEAD:refs/heads/<branch>`.
    static func parseRefs(_ data: Data) -> Head? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: { $0 == "\n" }) {
            guard let range = line.range(of: " HEAD") else { continue }
            let before = line[..<range.lowerBound]
            guard before.count >= 40 else { continue }
            let sha = String(before.suffix(40))
            guard sha.allSatisfy(\.isHexDigit) else { continue }
            var branch: String?
            if let symref = line.range(of: "symref=HEAD:refs/heads/") {
                branch = String(line[symref.upperBound...].prefix { $0 != " " && $0 != "\0" && $0 != "\n" })
            }
            return Head(commit: sha.lowercased(), branch: branch)
        }
        return nil
    }

    /// Every blob and folder in the repository at `commit`.
    func tree(owner: String, repo: String, commit: String) async throws -> [TreeEntry] {
        struct Answer: Decodable { var tree: [TreeEntry]; var truncated: Bool? }
        let path = "repos/\(owner)/\(repo)/git/trees/\(commit)"
        if let gh, endpoints.isLive, let data = try? await gh.api(method: "GET", path: path + "?recursive=1", host: "github.com"),
           let answer = try? JSONDecoder().decode(Answer.self, from: data) {
            return answer.tree
        }
        var components = URLComponents(url: endpoints.api.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let data = try await get(components.url!, api: true)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw DaemonAPI.CatalogError.unreachable(host: host(endpoints.api))
        }
        return answer.tree
    }

    /// One file at `commit`.
    func raw(owner: String, repo: String, commit: String, path: String) async throws -> Data {
        try await get(endpoints.raw.appending(path: "\(owner)/\(repo)/\(commit)/\(path)"))
    }

    /// When the skill's folder last changed, for "Taken at". Only through a signed-in `gh`:
    /// anonymously it would spend a second request of sixty (research R4).
    func commitDate(owner: String, repo: String, commit: String, folder: String) async -> Date? {
        guard let gh, endpoints.isLive else { return nil }
        let path = "repos/\(owner)/\(repo)/commits?path=\(folder)&sha=\(commit)&per_page=1"
        guard let data = try? await gh.api(method: "GET", path: path, host: "github.com"),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let commitInfo = list.first?["commit"] as? [String: Any],
              let committer = commitInfo["committer"] as? [String: Any],
              let date = committer["date"] as? String else { return nil }
        return try? Date(date, strategy: .iso8601)
    }

    /// The rate-limit fallback: the commit's tarball, unpacked into `work`, and the tree
    /// read back off the unpacked files in the API's shape, so the rest of a preview is the
    /// same either way. Refused over 50 MB. Symbolic links are listed with git's `120000`
    /// so they are skipped in the same place as from the API.
    func tarballTree(owner: String, repo: String, commit: String, into work: URL) async throws -> (root: URL, tree: [TreeEntry]) {
        let data = try await get(endpoints.codeload.appending(path: "\(owner)/\(repo)/tar.gz/\(commit)"))
        guard data.count <= Self.tarballLimit else {
            throw DaemonAPI.CatalogError.cannotAdd([.tooLarge(bytes: data.count, files: 0)])
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appending(path: "archive.tar.gz")
        try data.write(to: archive)
        let unpacked = work.appending(path: "unpacked")
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let outcome = try await GitProcess(executable: URL(filePath: "/usr/bin/tar"),
                                           arguments: ["-xzf", archive.path, "-C", unpacked.path]).run()
        guard outcome.succeeded else { throw DaemonAPI.CatalogError.unreachable(host: host(endpoints.codeload)) }
        let root = unpacked.appending(path: "\(repo)-\(commit)")
        var tree: [TreeEntry] = []
        let base = root.standardizedFileURL.path
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey])
            let path = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            if values.isSymbolicLink == true {
                tree.append(TreeEntry(path: path, mode: "120000", type: "blob", sha: "", size: 0))
            } else if values.isDirectory == true {
                tree.append(TreeEntry(path: path, mode: "040000", type: "tree", sha: "", size: nil))
            } else if values.isRegularFile == true {
                let bytes = try Data(contentsOf: url)
                let mode = FileManager.default.isExecutableFile(atPath: url.path) ? "100755" : "100644"
                tree.append(TreeEntry(path: path, mode: mode, type: "blob", sha: SkillHashes.blobSHA(bytes), size: bytes.count))
            }
        }
        return (root, tree)
    }

    // MARK: HTTP

    struct RateLimited: Error {}

    private func get(_ url: URL, api: Bool = false) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.setValue("agents-app", forHTTPHeaderField: "User-Agent")
        if api { request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DaemonAPI.CatalogError.unreachable(host: host(url))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if api, status == 403 || status == 429,
           (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || status == 429 {
            throw RateLimited()
        }
        guard (200..<300).contains(status) else { throw DaemonAPI.CatalogError.unreachable(host: host(url)) }
        return data
    }

    private func host(_ url: URL) -> String { url.host ?? url.absoluteString }
}
#endif
