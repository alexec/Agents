#if canImport(CryptoKit)
import Foundation

/// The marketplaces a catalogue sheet searches (#687): listing them, adding and removing the
/// person's own, turning any on or off, and asking the one a search names.
extension DaemonCore {

    func marketplacesList(_ request: DaemonAPI.MarketplacesListRequest) -> DaemonAPI.MarketplacesListAnswer {
        var problem: String?
        var personal = Marketplaces.File()
        if let home = locations.personalHome {
            do { personal = try Marketplaces.load(Marketplaces.personalURL(home: home)) } catch let error as Marketplaces.Unreadable {
                problem = error.message
            } catch {}
        }
        var project: Marketplaces.File?
        if let folder = marketplaceProjectFolder(request.destination) {
            do { project = try Marketplaces.load(Marketplaces.projectURL(folder: folder)) } catch let error as Marketplaces.Unreadable {
                problem = problem ?? error.message
            } catch {}
        }
        let secrets = locations.personalHome.map { SecretsEnv.load(from: SecretsEnv.url(home: $0)) } ?? SecretsEnv(lines: [])
        let list = Marketplaces.list(kind: request.kind, personal: personal, project: project, secretIsSet: secrets.isSet)
        return .init(marketplaces: list, problem: problem)
    }

    func marketplacesAdd(_ request: DaemonAPI.MarketplaceAddRequest) throws -> DaemonAPI.MarketplacesListAnswer {
        let home = try marketplaceHome()
        if let problem = Marketplaces.problem(request) { throw Self.marketplaceRefusal(problem) }
        let url = Marketplaces.personalURL(home: home)
        var file = try marketplaceFile(url)
        let address = Marketplaces.normalized(request.url)
        if file.marketplaces.contains(where: { Marketplaces.normalized($0.url) == address }) {
            throw Self.marketplaceRefusal("You have a marketplace at \(address) already.")
        }
        let token = request.token?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let token, let value = request.tokenValue, !value.isEmpty {
            let secretsURL = SecretsEnv.url(home: home)
            do {
                var secrets = try SecretsEnv.loadForChange(from: secretsURL)
                secrets.set(token, value: value)
                try secrets.save(to: secretsURL)
            } catch let error as SecretsEnv.Unreadable {
                throw Self.marketplaceRefusal(error.message)
            }
        }
        file.marketplaces.append(.init(name: request.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                       format: request.format, url: address, token: token))
        try Marketplaces.save(file, to: url)
        DaemonLog.shared.write("marketplaces: added \(request.format.rawValue) \(URL(string: address)?.host ?? address)")
        return marketplacesList(.init(kind: request.format.kind))
    }

    /// Only the person's own can be removed; the token's value stays in `secrets.env`,
    /// where something else may use it.
    func marketplacesRemove(_ request: DaemonAPI.MarketplaceIDRequest) throws -> DaemonAPI.MarketplacesListAnswer {
        let home = try marketplaceHome()
        let url = Marketplaces.personalURL(home: home)
        var file = try marketplaceFile(url)
        let before = file.marketplaces.count
        file.marketplaces.removeAll { Marketplaces.id(origin: .personal, url: $0.url) == request.id }
        guard file.marketplaces.count < before else {
            throw Self.marketplaceRefusal("Only a marketplace of your own can be removed; the others can be turned off.")
        }
        file.off = file.off?.filter { $0 != request.id }
        if file.off?.isEmpty == true { file.off = nil }
        try Marketplaces.save(file, to: url)
        DaemonLog.shared.write("marketplaces: removed one")
        return marketplacesList(.init())
    }

    func marketplacesSetEnabled(_ request: DaemonAPI.MarketplaceSetEnabledRequest) throws -> DaemonAPI.MarketplacesListAnswer {
        let home = try marketplaceHome()
        let url = Marketplaces.personalURL(home: home)
        var file = try marketplaceFile(url)
        // A project's is known by its id alone: the person turns on what the list showed them.
        let origin: DaemonAPI.MarketplaceOrigin = request.id.hasPrefix("project:") ? .project : .personal
        let marketplace = DaemonAPI.Marketplace(id: request.id, name: "", format: .mcpRegistry, url: "", origin: origin)
        Marketplaces.setEnabled(marketplace, request.enabled, in: &file)
        try Marketplaces.save(file, to: url)
        DaemonLog.shared.write("marketplaces: \(request.enabled ? "on" : "off") \(request.id)")
        return marketplacesList(.init())
    }

    /// The marketplace a search or preview names, if it is on; else the first one on for
    /// the kind. Nil when every one is off.
    func marketplace(_ id: String?, kind: DaemonAPI.CatalogKind,
                     destination: DaemonAPI.SkillDestination?) -> DaemonAPI.Marketplace? {
        let on = marketplacesList(.init(kind: kind, destination: destination)).marketplaces.filter(\.enabled)
        if let id { return on.first { $0.id == id } }
        return on.first
    }

    /// The registry a marketplace is, with its token filled from `secrets.env`.
    func mcpRegistry(for marketplace: DaemonAPI.Marketplace) -> MCPRegistry {
        guard let base = URL(string: marketplace.url) else { return mcpRegistry }
        let token = marketplace.token.flatMap { name in
            locations.personalHome.flatMap { SecretsEnv.load(from: SecretsEnv.url(home: $0)).value(of: name) }
        }
        return MCPRegistry(session: mcpRegistrySession, endpoints: MCPRegistryEndpoints(base: base, token: token))
    }

    func skillsCatalog(for marketplace: DaemonAPI.Marketplace) -> SkillsCatalog {
        var endpoints = catalogEndpoints
        if let url = URL(string: marketplace.url) { endpoints.catalog = url }
        return SkillsCatalog(session: catalogSession, endpoints: endpoints)
    }

    private func marketplaceProjectFolder(_ destination: DaemonAPI.SkillDestination?) -> URL? {
        guard case .project = destination, let destination, let place = try? skillPlace(destination) else { return nil }
        return place.folder
    }

    private func marketplaceHome() throws -> URL {
        guard let home = locations.personalHome else {
            throw Self.marketplaceRefusal("This copy of the app has no ~/.agents of its own.")
        }
        return home
    }

    private func marketplaceFile(_ url: URL) throws -> Marketplaces.File {
        do { return try Marketplaces.load(url) } catch let error as Marketplaces.Unreadable {
            throw Self.marketplaceRefusal(error.message)
        }
    }

    static func marketplaceRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.catalogRefused, message: message,
                     data: try? JSONValue.encoding(DaemonAPI.CatalogError.failed(message)))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
