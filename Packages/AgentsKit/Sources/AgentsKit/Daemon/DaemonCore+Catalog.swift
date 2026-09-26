#if canImport(CryptoKit)
import Foundation

/// Searching a catalogue and adding skills to the person or a project (059,
/// contracts/catalog-methods.md). Control-only: none of these is in `deviceMethods` or
/// `agentMethods`.
extension DaemonCore {
    var catalog: SkillsCatalog { SkillsCatalog(session: catalogSession, endpoints: catalogEndpoints) }

    var catalogGitHub: GitHubSource {
        GitHubSource(session: catalogSession, endpoints: catalogEndpoints, gh: catalogEndpoints.isLive ? gitHubCLI : nil)
    }

    var catalogInstaller: SkillInstaller {
        SkillInstaller(sidecar: locations.root.appending(path: "catalog-skills.json"), afterRename: catalogAfterRename)
    }

    /// Where a destination is. A scratch root or a named personal home never uses the
    /// person's real Trash (research R9).
    func skillPlace(_ destination: DaemonAPI.SkillDestination) throws -> SkillPlace {
        let environment = ProcessInfo.processInfo.environment
        let realTrash = locations.isStandard && environment[StoreLocations.personalHomeVariable] == nil
        let records = projectRecords()
        let agentFolders = Set(agents.values.map(\.projectFolder))
        return try SkillPlace.resolve(destination, personalHome: locations.personalHome, root: locations.root,
                                      usesRealTrash: realTrash, environment: environment) { folder in
            Self.isProjectFolder(folder, records: records, agentFolders: agentFolders)
        }
    }

    /// A project on this Mac, one an agent has worked in, or a worktree of either.
    static func isProjectFolder(_ folder: URL, records: [URL: Project], agentFolders: Set<URL>) -> Bool {
        let folder = Project.standardize(folder)
        if records[folder] != nil || agentFolders.contains(folder) { return true }
        let marker = "/\(WorktreeName.folder)/"
        guard let range = folder.path.range(of: marker) else { return false }
        let repo = Project.standardize(URL(filePath: String(folder.path[..<range.lowerBound])))
        return records[repo] != nil || agentFolders.contains(repo)
    }

    // MARK: catalog/search

    func catalogSearch(_ request: DaemonAPI.CatalogSearchRequest) async -> DaemonAPI.CatalogSearchAnswer {
        do {
            let results = try await catalog.search(request.query)
            DaemonLog.shared.write("catalog: search \"\(request.query)\" → \(results.count)")
            return .init(results: results)
        } catch let error as DaemonAPI.CatalogError {
            DaemonLog.shared.write("catalog: search \"\(request.query)\" failed: \(error)")
            return .init(results: [], error: error)
        } catch {
            return .init(results: [], error: .failed(String(describing: error)))
        }
    }

    // MARK: catalog/preview

    func catalogPreview(_ request: DaemonAPI.CatalogPreviewRequest) async -> DaemonAPI.CatalogPreviewAnswer {
        let id = UUID()
        let folder = await catalogStaging.folder(for: id)
        do {
            var staged = try await SkillPreviewer(catalog: catalog, github: catalogGitHub)
                .stage(request.result, into: folder, id: id)
            staged.preview.destinationState = destinationState(of: staged.preview, at: request.destination)
            await catalogStaging.put(staged)
            let via = Dictionary(grouping: staged.preview.files, by: \.via).mapValues(\.count)
            DaemonLog.shared.write("catalog: preview \(request.result.id) @ \(staged.preview.commit.prefix(7)) \(via)")
            return .init(preview: staged.preview)
        } catch let error as DaemonAPI.CatalogError {
            try? FileManager.default.removeItem(at: folder)
            DaemonLog.shared.write("catalog: preview \(request.result.id) failed: \(error)")
            return .init(preview: nil, error: error)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return .init(preview: nil, error: .failed(String(describing: error)))
        }
    }

    func destinationState(of preview: DaemonAPI.SkillPreview,
                          at destination: DaemonAPI.SkillDestination) -> DaemonAPI.DestinationState {
        do {
            return catalogInstaller.state(of: preview, at: try skillPlace(destination))
        } catch let error as DaemonAPI.CatalogError {
            return .unavailable(error)
        } catch {
            return .unavailable(.failed(String(describing: error)))
        }
    }

    // MARK: catalog/destination-state

    func catalogDestinationState(_ request: DaemonAPI.DestinationStateRequest) async throws -> DaemonAPI.DestinationStateAnswer {
        guard let staged = await catalogStaging.get(request.previewID) else { throw Self.refusal(.previewExpired) }
        return .init(destinationState: destinationState(of: staged.preview, at: request.destination))
    }

    // MARK: skills/add

    func skillsAdd(_ request: DaemonAPI.SkillAddRequest) async throws -> DaemonAPI.SkillAddAnswer {
        guard let staged = await catalogStaging.take(request.previewID) else { throw Self.refusal(.previewExpired) }
        defer { Task { await catalogStaging.discard(request.previewID) } }
        do {
            let place = try skillPlace(request.destination)
            let skill = try catalogInstaller.add(staged, to: place, replace: request.replace)
            let whereTo = place.folder.map { "project \($0.lastPathComponent)" } ?? "personal"
            DaemonLog.shared.write("catalog: add \(skill.name) from \(skill.source) @ \(staged.preview.commit.prefix(7)) → \(whereTo)")
            return .init(skill: skill)
        } catch let error as DaemonAPI.CatalogError {
            DaemonLog.shared.write("catalog: add \(staged.preview.name) refused: \(error)")
            throw Self.refusal(error)
        }
    }

    // MARK: skills/list

    func skillsList(_ request: DaemonAPI.SkillsListRequest) throws -> DaemonAPI.SkillsListAnswer {
        let place: SkillPlace
        do { place = try skillPlace(request.destination) } catch let e as DaemonAPI.CatalogError { throw Self.refusal(e) }
        let managed = catalogInstaller.managed(at: place)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: place.skills.path)) ?? []).sorted()
        var skills: [DaemonAPI.ListedSkill] = []
        for name in names where !name.hasPrefix(".") {
            let folder = place.skills.appending(path: name)
            guard let text = try? String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8) else { continue }
            skills.append(.init(name: name, description: SkillFile(text: text).description, folder: folder.path,
                                managed: managed[name]))
        }
        return .init(skills: skills)
    }

    /// Settings ▸ Shared's personal skills, each with where a lock says it came from.
    func withManagedSkills(_ snapshot: DaemonAPI.SharedSnapshot) -> DaemonAPI.SharedSnapshot {
        guard let place = try? skillPlace(.personal) else { return snapshot }
        let managed = catalogInstaller.managed(at: place)
        guard !managed.isEmpty else { return snapshot }
        var out = snapshot
        for i in out.skills.indices where out.skills[i].source == .personal {
            out.skills[i].managed = managed[out.skills[i].name]
        }
        return out
    }

    static func refusal(_ error: DaemonAPI.CatalogError) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.catalogRefused, message: CatalogWords.sentence(error),
                     data: try? JSONValue.encoding(error))
    }
}

/// A catalogue refusal in a sentence, for the log and for a client that shows only the message.
enum CatalogWords {
    static func sentence(_ error: DaemonAPI.CatalogError) -> String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)."
        case .rateLimited: "GitHub is limiting requests. Try again in a few minutes."
        case .unmanaged(let path): "A skill you made is already at \(path), so it was left alone."
        case .lockUnreadable(let path): "\(path) could not be read, so it was not written."
        case .noPersonalHome: "This copy of the app has no personal ~/.agents."
        case .previewExpired: "That preview has expired. Open the skill again."
        case .notAProject(let path): "\(path) is not a project on this Mac."
        case .replaceMismatch: "The skill there has changed. Open it again."
        case .cannotAdd: "This skill can't be added."
        case .notManaged(let name): "\(name) was not added by the app or the skills tool."
        case .failed(let why): "It could not be added: \(why)."
        }
    }
}
#endif
