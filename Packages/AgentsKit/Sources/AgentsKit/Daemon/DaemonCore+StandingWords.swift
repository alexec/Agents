import Foundation

extension DaemonCore {
    /// The words of ours a conversation hears once, before anything the person says:
    /// the briefing, with who is who (#121) and what the person declared on this
    /// machine (#116), then the persona it was started as (#760). Read now, so an edit to
    /// the persona's file reaches the next conversation, and from the project the agent
    /// belongs to.
    func standingWords(runtimeID: String, persona: String?, project: URL, startedBy starter: UUID?) -> [String] {
        loadDeclaredIfNeeded()
        let naming = Briefing.Naming(runtime: RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID,
                                     person: personSettings.effectiveName(),
                                     pronouns: personSettings.givenPronouns,
                                     startedBy: starter.map { agents[$0]?.title ?? "" })
        var words = [Briefing.text(for: ToolPolicyCatalog.policy(for: runtimeID),
                                   movesItself: RuntimeCatalog.canMoveFolders(runtimeID: runtimeID),
                                   naming: naming, declared: declaredResources)]
        if let persona, let found = PersonaFile.find(persona, project: project, home: locations.personalHome),
           !found.prompt.isEmpty {
            words.append(found.prompt)
        }
        return words
    }

    /// Those words as one system prompt, for a runtime that takes one (#1080); nil for a
    /// runtime that does not, which hears them in its first prompt instead.
    func systemPrompt(runtimeID: String, persona: String?, project: URL, startedBy starter: UUID?) -> String? {
        guard RuntimeCatalog.systemPromptDelivery(runtimeID: runtimeID) != nil else { return nil }
        return standingWords(runtimeID: runtimeID, persona: persona, project: project, startedBy: starter)
            .joined(separator: "\n\n")
    }

    /// An agent's system prompt, for picking its conversation back up: `session/load`
    /// and `session/resume` read `_meta` again, so the words are given again. A writer
    /// (#858) has none: its prompt is its whole briefing.
    func systemPrompt(for agent: Agent) -> String? {
        guard agent.purpose == nil else { return nil }
        return systemPrompt(runtimeID: agent.runtimeID, persona: agent.persona, project: agent.projectFolder,
                            startedBy: agent.startedByAgent)
    }

    /// `meta` with the system prompt in it, where this runtime reads one.
    static func adding(systemPrompt: String?, runtimeID: String, to meta: JSONValue?) -> JSONValue? {
        guard let systemPrompt, let delivery = RuntimeCatalog.systemPromptDelivery(runtimeID: runtimeID) else {
            return meta
        }
        switch delivery {
        case .append:
            return merging(meta, ["systemPrompt": ["append": .string(systemPrompt)]])
        case .rules:
            // Grok's rules may already hold the app's tool cards (`AppToolPreface`):
            // the briefing goes first, and the cards it names follow.
            let rules = [systemPrompt, meta?["rules"]?.stringValue].compactMap { $0 }.joined(separator: "\n\n")
            return merging(meta, ["rules": .string(rules)])
        }
    }
}
