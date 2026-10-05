import Foundation

/// Which runtimes a new agent may start on, here, and why not the others (#117).
///
/// One answer for every place that starts an agent without a person choosing from a
/// menu: an agent's `start_agent`, and a workflow's `runtime:`. It is the answer the
/// Runtimes page and the pool already give (`unusable`, the allowance states), asked of
/// this host, because a helper starts in its caller's project and so on its caller's
/// host. Said before anything starts: a runtime that is not installed, not signed in or
/// out of the pool otherwise fails seconds later, inside the runtime, in its own words
/// or none.
extension DaemonCore {
    /// Why a runtime cannot take a new agent here, in the Runtimes page's words. Nil
    /// when it can. A rate limit is not a reason: it passes, and the turn waits for it.
    func whyUnavailable(_ runtimeID: String) -> String? {
        let entry = Self.ownEntry(runtimeID: runtimeID)
        if let unusable = unusable(entry) { return unusable }
        let at = now()
        var state = allowanceState(for: entry)
        state.settle(now: at)
        guard state.isOut else { return nil }
        return "out of the pool: \(PoolWords.state(state, now: at))"
    }

    /// The runtime's models out, in the Pool page's words, or nil (#140).
    func modelsOutNote(runtimeID: String) -> String? {
        PoolWords.modelsOut(allowanceState(for: Self.ownEntry(runtimeID: runtimeID)), now: now())
    }

    /// Whether the runtime itself is out of the pool, as the choosers' Out run has it.
    func isOutOfPool(runtimeID: String) -> Bool {
        var state = allowanceState(for: Self.ownEntry(runtimeID: runtimeID))
        state.settle(now: now())
        return state.isOut
    }

    /// Its Pool page line when the runtime or any of its models is out, else nil.
    func poolNote(runtimeID: String) -> String? {
        let at = now()
        var state = allowanceState(for: Self.ownEntry(runtimeID: runtimeID))
        state.settle(now: at)
        guard state.isOut || !state.modelsOut(now: at).isEmpty else { return nil }
        return PoolWords.stateWithModels(state, now: at)
    }

    /// Where "here" is, as the refusal says it.
    static var here: String {
        #if os(macOS)
        "on this Mac"
        #else
        "on this host"
        #endif
    }

    /// The refusal for a runtime that cannot take a new agent here, naming the ones
    /// that can. Nil when it can. No full stop: the callers add their own.
    func unavailableRuntimeRefusal(_ runtime: Runtime) -> String? {
        guard let why = whyUnavailable(runtime.id) else { return nil }
        let available = RuntimeCatalog.builtIn.filter { whyUnavailable($0.id) == nil }.map(\.id)
        let others = available.isEmpty
            ? "No runtime is available \(Self.here) right now"
            : "Available: \(available.joined(separator: ", "))"
        return "\(runtime.name) isn't available \(Self.here) (\(why)). \(others)"
    }

    /// Every runtime, available or not, for an agent about to choose one: the ids it
    /// may name, each with the model it starts on where this folder has used it, and
    /// the rest with why not. What `list_my_agents` ends with.
    func runtimeChoices(in folder: URL) -> String {
        var available: [String] = []
        var not: [String] = []
        for runtime in RuntimeCatalog.builtIn {
            if let why = whyUnavailable(runtime.id) {
                not.append("\(runtime.id) (\(why))")
            } else {
                // A model out is said beside it (#140): the runtime takes agents, that model may not.
                let notes = [rememberedModel(runtimeID: runtime.id, folder: folder).map { "model \($0)" },
                             modelsOutNote(runtimeID: runtime.id)].compactMap { $0 }
                available.append(notes.isEmpty ? runtime.id : "\(runtime.id) (\(notes.joined(separator: "; ")))")
            }
        }
        var lines = [available.isEmpty
            ? "No runtime can take a new agent \(Self.here) right now."
            : "Runtimes you can start agents on (\(RuntimeCatalog.defaultRuntime.id) if you name none): "
                + available.joined(separator: ", ") + "."]
        if !not.isEmpty { lines.append("Not available \(Self.here): " + not.joined(separator: ", ") + ".") }
        return lines.joined(separator: "\n")
    }

    /// The model a runtime last said it starts on in this folder, from what it last
    /// advertised here with any MCP servers. Nil when it has not been used here: a
    /// remembered answer is all this can be without starting the runtime, and a model
    /// it will not take is refused at the start in its own words.
    private func rememberedModel(runtimeID: String, folder: URL) -> String? {
        if rememberedOptions == nil { rememberedOptions = optionCache.load() }
        let prefix = OptionCache.key(runtimeID: runtimeID, cwd: folder, mcpServers: [])
        let entry = rememberedOptions?
            .filter { $0.key.hasPrefix(prefix) && $0.value.isWorthKeeping }
            .max { $0.value.savedAt < $1.value.savedAt }?.value
        guard let option = entry.flatMap({ WorkflowSettings.modelOption(in: $0.options) }),
              let value = option.currentValue?.stringValue else { return nil }
        return value
    }
}
