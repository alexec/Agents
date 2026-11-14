import AgentsKitCore
import AppKit
import Foundation
import os

/// The catalogue, personas from a marketplace and marketplaces (059, #3665, #687).
extension AppModel {
    // MARK: The catalogue (059)

    /// What a catalogue call said, or why it could not: the sheet shows either, so these
    /// do not go through `attempt`, which would put a failure in the window's banner too.
    func catalogSearch(_ query: String, marketplace: String? = nil,
                       destination: DaemonAPI.SkillDestination? = nil) async -> DaemonAPI.CatalogSearchAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.catalogSearch,
                                         DaemonAPI.CatalogSearchRequest(query: query, marketplace: marketplace,
                                                                        destination: destination),
                                         returning: DaemonAPI.CatalogSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.catalogError(error))
        }
    }

    func catalogPreview(_ result: DaemonAPI.CatalogResult,
                        for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogPreviewAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.catalogPreview,
                                         DaemonAPI.CatalogPreviewRequest(result: result, destination: destination),
                                         returning: DaemonAPI.CatalogPreviewAnswer.self)
        } catch {
            return .init(preview: nil, error: Self.catalogError(error))
        }
    }

    func addSkill(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                  replace: Bool) async -> Result<DaemonAPI.ManagedSkill, DaemonAPI.CatalogError> {
        do {
            let answer = try await macClient.call(DaemonAPI.Method.skillsAdd,
                                               DaemonAPI.SkillAddRequest(previewID: previewID, destination: destination,
                                                                         replace: replace),
                                               returning: DaemonAPI.SkillAddAnswer.self)
            return .success(answer.skill)
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Skills in `~/.agents/skills` or a folder's `.agents/skills`.
    func skills(at destination: DaemonAPI.SkillDestination) async -> [DaemonAPI.ListedSkill]? {
        try? await macClient.call(DaemonAPI.Method.skillsList,
                               DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillsListAnswer.self).skills
    }

    /// Whether each added skill at a destination has an update (FR-018). Nil when it could
    /// not be asked; the page then shows no marks rather than wrong ones.
    func skillUpdates(at destination: DaemonAPI.SkillDestination) async -> [String: DaemonAPI.UpdateState]? {
        try? await macClient.call(DaemonAPI.Method.skillsCheckUpdates, DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillUpdatesAnswer.self).updates
    }

    func skillUpdatePreview(_ name: String, at destination: DaemonAPI.SkillDestination)
        async -> Result<DaemonAPI.SkillUpdatePreviewAnswer, DaemonAPI.CatalogError> {
        do {
            return .success(try await macClient.call(DaemonAPI.Method.skillsUpdatePreview,
                                                  DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                                  returning: DaemonAPI.SkillUpdatePreviewAnswer.self))
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Take out a skill the app or the skills tool added; its folder goes to the Trash.
    func removeSkill(_ name: String, at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogError? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.skillsRemove,
                                      DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                      returning: DaemonAPI.SkillRemoveAnswer.self)
            return nil
        } catch {
            return Self.catalogError(error)
        }
    }

    // MARK: Personas from a marketplace (#3665)

    func personaSearch(_ query: String, marketplace: String?,
                       destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogSearchAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.personasSearch,
                                         DaemonAPI.CatalogSearchRequest(query: query, marketplace: marketplace,
                                                                        destination: destination),
                                         returning: DaemonAPI.CatalogSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.catalogError(error))
        }
    }

    func personaPreview(_ result: DaemonAPI.CatalogResult,
                        for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.PersonaPreviewAnswer {
        do {
            return try await macClient.call(DaemonAPI.Method.personasPreview,
                                         DaemonAPI.CatalogPreviewRequest(result: result, destination: destination),
                                         returning: DaemonAPI.PersonaPreviewAnswer.self)
        } catch {
            return .init(preview: nil, error: Self.catalogError(error))
        }
    }

    func addPersona(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                    replace: Bool) async -> Result<DaemonAPI.ManagedPersona, DaemonAPI.CatalogError> {
        do {
            let answer = try await macClient.call(DaemonAPI.Method.personasAdd,
                                               DaemonAPI.SkillAddRequest(previewID: previewID, destination: destination,
                                                                         replace: replace),
                                               returning: DaemonAPI.PersonaAddAnswer.self)
            return .success(answer.persona)
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// The personas at a destination that were added from a marketplace.
    func managedPersonas(at destination: DaemonAPI.SkillDestination) async -> [DaemonAPI.ManagedPersona]? {
        try? await macClient.call(DaemonAPI.Method.personasManaged, DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.PersonasManagedAnswer.self).personas
    }

    /// Whether each persona added from a marketplace has an update. Nil when it could not be
    /// asked, so no marks rather than wrong ones.
    func personaUpdates(at destination: DaemonAPI.SkillDestination) async -> [String: DaemonAPI.UpdateState]? {
        try? await macClient.call(DaemonAPI.Method.personasCheckUpdates, DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillUpdatesAnswer.self).updates
    }

    func personaUpdatePreview(_ id: String, at destination: DaemonAPI.SkillDestination)
        async -> Result<DaemonAPI.PersonaUpdatePreviewAnswer, DaemonAPI.CatalogError> {
        do {
            return .success(try await macClient.call(DaemonAPI.Method.personasUpdatePreview,
                                                  DaemonAPI.SkillNameRequest(destination: destination, name: id),
                                                  returning: DaemonAPI.PersonaUpdatePreviewAnswer.self))
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Take out a persona added from a marketplace; its file goes to the Trash.
    func removePersona(_ id: String, at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogError? {
        do {
            _ = try await macClient.call(DaemonAPI.Method.personasRemove,
                                      DaemonAPI.SkillNameRequest(destination: destination, name: id),
                                      returning: DaemonAPI.SkillRemoveAnswer.self)
            return nil
        } catch {
            return Self.catalogError(error)
        }
    }

    /// The daemon's own reason when it gave one, and "can't reach" the daemon otherwise.
    static func catalogError(_ error: any Error) -> DaemonAPI.CatalogError {
        if let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.catalogRefused,
           let reason = try? rpc.data?.decode(DaemonAPI.CatalogError.self) {
            return reason
        }
        // The organisation's policy refused it (#998): its own words, as the other clients say them.
        if let refusal = DaemonAPI.PolicyRefusal(error: error) { return .failed(refusal.line) }
        if let rpc = error as? JSONRPCError { return .failed(rpc.message) }
        return .failed(String(describing: error))
    }

    // MARK: Marketplaces (#687)

    /// The marketplaces for a kind, a folder's among them when it is the destination. Nil
    /// when the daemon could not be asked.
    func marketplaces(_ kind: DaemonAPI.CatalogKind,
                      for destination: DaemonAPI.SkillDestination?) async -> DaemonAPI.MarketplacesListAnswer? {
        try? await macClient.call(DaemonAPI.Method.marketplacesList,
                               DaemonAPI.MarketplacesListRequest(kind: kind, destination: destination),
                               returning: DaemonAPI.MarketplacesListAnswer.self)
    }

    /// Nil when added, else the daemon's reason in words.
    func addMarketplace(_ request: DaemonAPI.MarketplaceAddRequest) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesAdd, request)
    }

    func removeMarketplace(_ id: String) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesRemove, DaemonAPI.MarketplaceIDRequest(id: id))
    }

    func setMarketplace(_ id: String, enabled: Bool) async -> String? {
        await marketplaceCall(DaemonAPI.Method.marketplacesSetEnabled,
                              DaemonAPI.MarketplaceSetEnabledRequest(id: id, enabled: enabled))
    }

    func marketplaceCall<P: Encodable & Sendable>(_ method: String, _ params: P) async -> String? {
        do {
            _ = try await macClient.call(method, params, returning: DaemonAPI.MarketplacesListAnswer.self)
            return nil
        } catch let rpc as JSONRPCError {
            return rpc.message
        } catch {
            return String(describing: error)
        }
    }
}
