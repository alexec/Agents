import AgentsKitCore
import SwiftUI

/// The parts of the prompt area both apps draw (033): what the field says, what sits
/// above it, and what shows where the controls would be when there are none.
///
/// The field and the controls themselves stay each app's own, because a pointer and a
/// thumb want different things of them. The words and the order do not.
enum PromptWords {
    /// What the empty field says to an agent that exists.
    ///
    /// While it works, the field says what happens to what you type rather than what the
    /// agent is doing. The state line in the transcript says that.
    static func placeholder(for agent: Agent) -> String {
        if agent.state.hasTurnInFlight { return "Say what next, and it goes when this turn ends" }
        switch agent.state {
        // `.starting` cannot reach here — it answers true to `hasTurnInFlight`, so the
        // guard above has already returned. Named anyway, because the compiler asks and
        // because a silent `default:` is how the next new state gets the wrong words.
        case .starting, .running, .waitingOnUser: return "What do you want to do?"
        case .finished, .stopped: return "What do you want to do?"
        case .archived: return "Say what next, and this comes back"
        }
    }

    /// Whether what is typed now will wait rather than go.
    static func willQueue(_ agent: Agent) -> Bool {
        agent.state.hasTurnInFlight || !agent.queuedPrompts.isEmpty
    }

    static func sendSymbol(willQueue: Bool) -> String { willQueue ? "arrow.up.to.line" : "arrow.up" }
    /// Where send is while the agent works and nothing is typed: the one way to stop it.
    static let stopSymbol = "stop.fill"
    static let stopHelp = "Stop this agent and stay on the chat"
    static func sendLabel(willQueue: Bool) -> String { willQueue ? "Queue" : "Send" }
    static func sendHelp(willQueue: Bool) -> String {
        willQueue ? "Queue this, to go when the turn ends" : "Send"
    }

    static let atItsCostLimit = "This agent has reached its cost limit"
    static let draftLostSomething = "A picture you had pasted was too large to keep, so it did not come back with the rest."
    static let dictationPrimerTitle = "Say it instead of typing it"

    /// The runtime's name as a person knows it.
    static func runtimeName(_ id: String) -> String {
        RuntimeCatalog.runtime(id: id)?.name ?? id
    }
}

/// Where the agent is working, how full it is, and what runs it: the row above the
/// field once an agent exists.
///
/// What the agent holds, waits for and runs in the background, above the prompt.
/// Live, so shown only while it is so. The settled facts — its place, its runtime,
/// what it has used — are not drawn here: the pills under the prompt are the settings.
struct PromptHeader: View {
    let agent: Agent
    /// What the agent holds and waits for (036), drawn as a row of its own above
    /// this one. Nil draws nothing.
    var leaseStatus: LeaseStatus? = nil
    /// What a lease capsule does when pressed. See `LeaseRow`.
    var openLease: ((ResourceName) -> Void)? = nil
    /// What the agent waits for on events (042), drawn above this row. Nil draws nothing.
    var waitStatus: WaitStatus? = nil
    var waitHint: String = ""
    /// What the wait capsule does when pressed, and its ✕. See `WaitCapsule`.
    var openWait: (() -> Void)? = nil
    var cancelWait: (() -> Void)? = nil
    /// What it has running in the background (057), drawn above the leases: a block of
    /// rows, or on a phone one line that opens them (`compactBackground`).
    var background: [BackgroundItem] = []
    var backgroundActions = BackgroundActions()
    var compactBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let waitStatus {
                WaitCapsule(status: waitStatus, hint: waitHint, open: openWait, cancel: cancelWait)
            }
            if compactBackground {
                BackgroundLine(items: background, actions: backgroundActions)
            } else {
                BackgroundBlock(items: background, actions: backgroundActions)
            }
            if let leaseStatus {
                LeaseRow(status: leaseStatus, open: openLease)
            }
        }
    }

}

/// Said above the field when the open agent may take no more prompts, with exactly two
/// ways out: raise the limit, or let this one agent go on.
///
/// Neither happens without the reader choosing it and neither is the default. Nothing
/// here sends a prompt — raising a ceiling makes an agent promptable again; continuing
/// is the reader's second act, deliberately.
///
/// `raise` is each app's: the Mac opens its Settings, and a phone, which has no limits
/// page of its own, says where they are changed.
struct CostLimitBanner<Raise: View>: View {
    let agent: Agent
    let limits: CostLimits
    let costState: DaemonAPI.CostState?
    let goOn: () -> Void
    @ViewBuilder let raise: () -> Raise

    var body: some View {
        if agent.isAtCostLimit(under: limits) {
            banner {
                // The failure tint, not attention. An agent at its limit is waiting on
                // a ceiling being raised, which is a thing broken about its situation
                // rather than a question it has asked; orange is reserved for the
                // latter (FR-006a).
                Image(systemName: "exclamationmark.triangle.fill")
                    .tinted(.failure)
            } words: {
                Text(PromptWords.atItsCostLimit)
                    .appText(.fine).fontWeight(.medium)
                Text("\(Cost.total(of: agent.costToDate) ?? "") spent. "
                     + "Anything you send waits until you allow more.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            } actions: {
                raise()
                Button("Let this one go on", action: goOn)
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .help("Raises this agent's own ceiling. No other agent is changed.")
            }
        } else if costState?.dayLimitReached == true {
            banner {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            } words: {
                Text("The day's spending limit has been reached")
                    .appText(.fine).fontWeight(.medium)
                Text("What you send waits here, and goes when the day rolls over.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            } actions: {
                raise()
            }
        }
    }

    /// One row on a Mac. On a phone the buttons go under the words: a row holding two
    /// sentences and two buttons at 390 points is a row of truncations.
    @ViewBuilder
    private func banner<Icon: View, Words: View, Actions: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder words: () -> Words,
        @ViewBuilder actions: () -> Actions) -> some View {
        #if os(macOS)
        HStack(spacing: 10) {
            icon()
            VStack(alignment: .leading, spacing: 1) { words() }
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paperRaised(in: Capsule())
        #else
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                icon()
                VStack(alignment: .leading, spacing: 1) { words() }
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                actions()
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .paperRaised(in: RoundedRectangle(cornerRadius: 16))
        #endif
    }
}

/// Where a phone says the limit is changed, in place of the Mac's Settings button.
struct RaiseTheLimitOnTheMac: View {
    var body: some View {
        Text("Change the limit in Settings on your Mac.")
            .appText(.fine)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the area under the prompt shows when there are no controls, which is never
/// nothing.
///
/// Six ways to have no controls, and each one says which it is. This used to be an `if`
/// with no `else`, so a runtime that advertises nothing, a fetch that failed and a
/// folder not yet chosen were all the same silent gap.
struct OptionsNote: View {
    let state: PromptControlsState
    var retry: (() -> Void)? = nil

    var body: some View {
        switch state {
        case .needsFolder:
            note("Choose a folder to see what this runtime offers.")
        case .needsRuntime:
            note("Choose a runtime to see what it offers.")
        case .loading(let name):
            note("Asking \(name) what it offers…")
        case .nothingOffered(let name):
            note("\(name) has nothing to adjust.")
        case .failed(let reason):
            // The one case that may carry the app's error treatment, and the only one
            // with something to press.
            HStack(spacing: 8) {
                Text(reason)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let retry {
                    Button("Try again", action: retry)
                        .buttonStyle(.paper)
                        .appText(.fine)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .controls:
            EmptyView()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
