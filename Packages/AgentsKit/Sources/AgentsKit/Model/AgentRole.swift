import Foundation

/// What an agent is for.
///
/// A lead is an agent in every way that matters — a runtime, a folder, a conversation,
/// a state, a transcript, a cost, a context meter — which is why this is a field on
/// `Agent` rather than a second kind of record. The chat view, the prompt bar, the
/// permission flow and the store all work on a lead with no special case.
///
/// Three things make it a lead, and they are the whole difference: it is created with
/// its project rather than by the user, it alone is offered the tools for working with
/// its project's agents, and it cannot be archived apart from its project.
public enum AgentRole: String, Codable, Hashable, Sendable, CaseIterable {
    /// An agent doing a piece of work. Everything written before this feature.
    case worker
    /// The one agent per project whose job is the project.
    case lead
}
