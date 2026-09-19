import Foundation

/// What the area under the prompt is showing.
///
/// There is always one of these, which is the whole point of the type. The row used to
/// be drawn by an `if` with no `else`, so six different upstream conditions — a runtime
/// that advertises nothing, a fetch that failed, a fetch still running, a folder not yet
/// chosen — all came out as the same silent gap, and the person could not tell which.
/// A total enum makes "never silently empty" something the compiler holds rather than
/// something a reviewer has to notice.
///
/// Derived, never stored. `resolve` is the only way to make one.
public enum PromptControlsState: Equatable, Sendable {
    /// A new chat with nowhere to work yet.
    case needsFolder
    /// A folder, but no runtime to run in it.
    case needsRuntime
    /// Asking the runtime what it offers.
    case loading(runtimeName: String)
    /// The asking failed. The reason is the person's to read, and the caller offers a
    /// way to ask again.
    case failed(reason: String)
    /// The runtime answered and has nothing to adjust. Cursor is always here, by
    /// design: it advertises no `configOptions` at all.
    case nothingOffered(runtimeName: String)
    /// Filtered by `isRenderable`, ordered by `categoryRank`. Never empty.
    case controls([ConfigOption])

    /// What the runtime is called when we were not told.
    public static let unnamedRuntime = "the runtime"

    /// One answer, for every combination of what the window knows.
    ///
    /// Precedence, in order, each line a bug this type exists to stop:
    ///
    /// 1. no folder — you cannot ask a runtime about nowhere
    /// 2. no runtime — nor ask nobody
    /// 3. a fetch in flight — say so rather than showing the last answer as settled
    /// 4. a fetch that failed — which told us nothing about what the runtime offers
    /// 5. options we can draw — from the agent if it has any, otherwise the draft
    /// 6. otherwise the runtime genuinely offers nothing
    ///
    /// - Parameters:
    ///   - agentOptions: what a started agent advertises, or nil when there is no agent
    ///     yet. An **empty** array is not an answer: it falls through to the draft, the
    ///     failure or step 6. This is the bug — `agent?.advertised ?? draft` could never
    ///     reach the draft, because a non-nil empty array coalesces to itself.
    ///   - runtimeName: the display name, or nil. This does not look it up; the catalog
    ///     is the caller's side of the wall.
    ///   - failure: prose already fit to show a person.
    public static func resolve(agentOptions: [ConfigOption]?,
                               draftOptions: [ConfigOption],
                               hasFolder: Bool,
                               hasRuntime: Bool,
                               runtimeName: String?,
                               isLoading: Bool,
                               failure: String?) -> PromptControlsState {
        guard hasFolder else { return .needsFolder }
        guard hasRuntime else { return .needsRuntime }
        let named = runtimeName ?? unnamedRuntime
        if isLoading { return .loading(runtimeName: named) }
        if let failure { return .failed(reason: failure) }
        let offered = drawable(agentOptions: agentOptions, draftOptions: draftOptions)
        return offered.isEmpty ? .nothingOffered(runtimeName: named) : .controls(offered)
    }

    /// The options worth drawing, in the order they are drawn.
    ///
    /// Renderability is decided here rather than by the caller, so a list of options we
    /// cannot draw is `nothingOffered` and never `controls([])`.
    ///
    /// The sort is made stable by hand. `sorted(by:)` gives no such promise, and two
    /// options in the same category swapping places between redraws is a row that
    /// moves under the pointer.
    public static func drawable(agentOptions: [ConfigOption]?, draftOptions: [ConfigOption]) -> [ConfigOption] {
        let source: [ConfigOption]
        if let agentOptions, !agentOptions.isEmpty {
            source = agentOptions
        } else {
            source = draftOptions
        }
        return source.filter(\.isRenderable)
            .enumerated()
            .sorted { left, right in
                left.element.categoryRank == right.element.categoryRank
                    ? left.offset < right.offset
                    : left.element.categoryRank < right.element.categoryRank
            }
            .map(\.element)
    }
}
