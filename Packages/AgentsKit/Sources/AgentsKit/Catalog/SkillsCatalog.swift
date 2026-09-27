#if canImport(CryptoKit)
import Foundation

/// skills.sh, the catalogue (059, research R1 and R3): its search, and its copy of a skill's
/// text files, which is checked file by file against GitHub before any of it is used.
struct SkillsCatalog: Sendable {
    let session: URLSession
    let endpoints: CatalogEndpoints

    /// Results in the catalogue's own order, which is most installed first. Only skills that
    /// live on GitHub (`owner/repo`): the rest are left out of this slice. A query shorter
    /// than two characters is not sent.
    func search(_ query: String) async throws -> [DaemonAPI.CatalogResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var components = URLComponents(url: endpoints.catalog.appending(path: "api/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        struct Answer: Decodable {
            struct Row: Decodable { var id: String; var source: String; var skillId: String; var name: String; var installs: Int? }
            var skills: [Row]
        }
        let data = try await get(components.url!)
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw DaemonAPI.CatalogError.unreachable(host: host)
        }
        return answer.skills.compactMap { row in
            guard let (owner, repo) = Self.gitHubSource(row.source) else { return nil }
            return DaemonAPI.CatalogResult(id: row.id, name: row.name, owner: owner, repo: repo, skillID: row.skillId,
                                           installs: row.installs ?? 0, known: KnownOwners.isKnown(owner))
        }
    }

    /// `owner/repo` and nothing else: no scheme, no host, two plain parts, neither of them
    /// `.` or `..`. It goes into URL paths, so a catalogue row must not be able to steer one.
    static func gitHubSource(_ source: String) -> (String, String)? {
        let parts = source.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !source.contains(":"),
              parts.allSatisfy({ $0 != "." && $0 != ".." }),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    struct Snapshot: Decodable {
        struct File: Decodable { var path: String; var contents: String }
        var files: [File]
    }

    /// skills.sh's copy of the skill's text files, or nil if it has none or cannot be
    /// reached: GitHub alone is enough, only slower.
    func snapshot(owner: String, repo: String, skillID: String) async -> Snapshot? {
        let url = endpoints.catalog.appending(path: "api/download/\(owner)/\(repo)/\(skillID)")
        guard let data = try? await get(url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private var host: String { endpoints.catalog.host ?? "skills.sh" }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: GitHubSource.timeout)
        request.setValue("agents-app", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DaemonAPI.CatalogError.unreachable(host: host)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DaemonAPI.CatalogError.unreachable(host: host)
        }
        return data
    }
}
#endif
