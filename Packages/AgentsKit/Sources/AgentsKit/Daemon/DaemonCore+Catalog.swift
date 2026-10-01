#if canImport(CryptoKit)
import Foundation

/// Searching a catalogue and adding skills to the person or a project (059,
/// contracts/catalog-methods.md). Control-only: none of these is in `deviceMethods` or
/// `agentMethods`.
extension DaemonCore {

    /// At start: undo an add the last daemon died in the middle of (SC-003).
    func recoverCatalog() {
        if let undone = SkillInstaller.recover(journal: catalogInstaller.journal) {
            DaemonLog.shared.write("catalog: \(undone)")
        }
    }

    /// `AGENTS_TEST_CATALOG_PAUSE=afterRename` holds every add for 30 s between the rename
    /// and the lock write, so a walk can kill the daemon there (quickstart §3 step 13).
    static func catalogPause(_ environment: [String: String]) -> (@Sendable () throws -> Void)? {
        guard environment["AGENTS_TEST_CATALOG_PAUSE"] == "afterRename" else { return nil }
        return { Thread.sleep(forTimeInterval: 30) }
    }

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
        return .init(skills: catalogInstaller.list(at: place))
    }

    // MARK: skills/check-updates

    func skillsCheckUpdates(_ request: DaemonAPI.SkillsListRequest) async throws -> DaemonAPI.SkillUpdatesAnswer {
        let place: SkillPlace
        do { place = try skillPlace(request.destination) } catch let e as DaemonAPI.CatalogError { throw Self.refusal(e) }
        var cache = catalogUpdateChecks
        let states = await SkillUpdates(github: catalogGitHub, sidecar: catalogInstaller.sidecar)
            .check(catalogInstaller.managed(at: place), at: place, cache: &cache)
        catalogUpdateChecks = cache
        let available = states.filter { if case .available = $0.value { true } else { false } }.keys.sorted()
        DaemonLog.shared.write("catalog: update-check \(states.count) skills → \(available.isEmpty ? "current" : "available: \(available.joined(separator: ", "))")")
        return .init(updates: states)
    }

    // MARK: skills/update-preview

    /// The skill's source at its current commit, staged as a preview, with what it would
    /// change in the installed folder and whether that folder was edited since.
    func skillsUpdatePreview(_ request: DaemonAPI.SkillNameRequest) async throws -> DaemonAPI.SkillUpdatePreviewAnswer {
        do {
            let place = try skillPlace(request.destination)
            guard let managed = catalogInstaller.managed(at: place)[request.name],
                  let (owner, repo) = SkillsCatalog.gitHubSource(managed.source) else {
                throw DaemonAPI.CatalogError.notManaged(name: request.name)
            }
            let folderPath = managed.skillPath.map { String($0.dropLast("SKILL.md".count)) } ?? ""
            let skillID = folderPath.split(separator: "/").last.map(String.init) ?? request.name
            let result = DaemonAPI.CatalogResult(id: "\(owner)/\(repo)/\(skillID)", name: request.name, owner: owner,
                                                 repo: repo, skillID: skillID, installs: 0, known: KnownOwners.isKnown(owner))
            let id = UUID()
            var staged = try await SkillPreviewer(catalog: catalog, github: catalogGitHub)
                .stage(result, into: await catalogStaging.folder(for: id), id: id)
            staged.preview.destinationState = catalogInstaller.state(of: staged.preview, at: place)
            await catalogStaging.put(staged)
            let changes = SkillInstaller.changes(from: place.skills.appending(path: request.name), to: staged.folder)
            DaemonLog.shared.write("catalog: update-preview \(request.name) @ \(staged.preview.commit.prefix(7))")
            return .init(preview: staged.preview, changes: changes, edited: managed.edited)
        } catch let error as DaemonAPI.CatalogError {
            throw Self.refusal(error)
        }
    }

    // MARK: skills/remove

    func skillsRemove(_ request: DaemonAPI.SkillNameRequest) throws -> DaemonAPI.SkillRemoveAnswer {
        do {
            let place = try skillPlace(request.destination)
            let trashed = try catalogInstaller.remove(request.name, at: place)
            DaemonLog.shared.write("catalog: remove \(request.name) → \(place.folder.map { "project \($0.lastPathComponent)" } ?? "personal")")
            return .init(trashedTo: trashed.path)
        } catch let error as DaemonAPI.CatalogError {
            throw Self.refusal(error)
        }
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
