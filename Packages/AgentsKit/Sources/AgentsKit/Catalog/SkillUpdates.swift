#if canImport(CryptoKit)
import Foundation

/// Whether a skill's source has moved on since it was added (059, FR-018, research R4).
///
/// Per source repository, at most once an hour: its HEAD from git's ref list, which costs
/// nothing; and only when HEAD has moved past what was recorded, the tree at the new HEAD,
/// which is one API request. A skill whose folder is the same at the new HEAD is current,
/// and its recorded commit moves forward so the next check needs no request at all.
struct SkillUpdates: Sendable {
    let github: GitHubSource
    let sidecar: URL

    static let interval: TimeInterval = 60 * 60

    /// What a source said the last time it was asked: its HEAD, and each folder's tree SHA
    /// there (empty when HEAD had not moved and the tree was not fetched).
    struct Answer: Sendable {
        var at: Date
        var head: String
        var folders: [String: String]
    }

    /// Update state for each managed skill at `place`, by folder name. `cache` holds each
    /// source's last answer and is updated with any new one.
    func check(_ managed: [String: DaemonAPI.ManagedSkill], at place: SkillPlace, cache: inout [String: Answer],
               now: Date = Date()) async -> [String: DaemonAPI.UpdateState] {
        var out: [String: DaemonAPI.UpdateState] = [:]
        var side = CatalogSidecar.load(from: sidecar)
        let bySource = Dictionary(grouping: managed.values, by: { $0.source.lowercased() })
        for (source, skills) in bySource {
            guard let (owner, repo) = SkillsCatalog.gitHubSource(skills[0].source) else { continue }
            var answer = cache[source]
            if answer == nil || now.timeIntervalSince(answer!.at) > Self.interval {
                guard let head = try? await github.head(owner: owner, repo: repo) else {
                    for skill in skills { out[skill.name] = .unknown }
                    continue
                }
                let moved = skills.contains { $0.commit != head.commit }
                var folders: [String: String] = [:]
                if moved, let tree = try? await github.tree(owner: owner, repo: repo, commit: head.commit) {
                    for entry in tree where entry.type == "tree" { folders[entry.path] = entry.sha }
                }
                answer = Answer(at: now, head: head.commit, folders: folders)
                cache[source] = answer
            }
            guard let answer else { continue }
            for skill in skills {
                let key = CatalogSidecar.key(place.destination, name: skill.name)
                if skill.commit == answer.head { out[skill.name] = .current; continue }
                let folder = skill.skillPath.map { String($0.dropLast("SKILL.md".count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
                // What the folder was when it was added: the lock's tree SHA for a personal
                // skill, the sidecar's for a project one (the project lock keeps another hash).
                let was = place.lockKind == .personal ? skill.recordedHash : side.skills[key]?.treeSHA
                guard let now = answer.folders[folder], let was else { out[skill.name] = .unknown; continue }
                if now == was {
                    out[skill.name] = .current
                    side.skills[key]?.commit = answer.head
                } else {
                    out[skill.name] = .available(commit: answer.head)
                }
            }
        }
        try? side.save(to: sidecar) { _ in true }
        return out
    }
}
#endif
