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
        if agent.state.hasTurnInFlight { return "What do you want to do next?" }
        switch agent.state {
        // `.starting` cannot reach here — it answers true to `hasTurnInFlight`, so the
        // guard above has already returned. Named anyway, because the compiler asks and
        // because a silent `default:` is how the next new state gets the wrong words.
        case .starting, .running, .waitingOnUser: return askPlaceholder
        case .finished, .stopped: return askPlaceholder
        // What is typed waits with it, and goes when it starts (#362).
        case .queued: return "Queued: what you type goes when it starts"
        case .archived: return "Say what next, and this comes back"
        }
    }

    /// Whether what is typed now will wait rather than go.
    static func willQueue(_ agent: Agent) -> Bool {
        agent.state.hasTurnInFlight || agent.state == .queued || !agent.queuedPrompts.isEmpty
    }

    /// The prompt's own words when nothing better is on offer.
    static let askPlaceholder = "What do you want to do?"
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
    static let dictationPrimer = "The phone listens while the button is on, and what you say becomes the words in the prompt. It is recognised on this phone where this phone can do it."
    /// Before voice mode first listens (#2444).
    static let voicePrimerTitle = "Talk to the agent"
    static let voicePrimer = "The phone listens while voice mode is on, and what you say goes to the chat after a short pause. It is recognised on this phone where this phone can do it."

    /// The runtime's name as a person knows it.
    static func runtimeName(_ id: String) -> String {
        if id == LevelWords.autoID { return LevelWords.auto }
        return RuntimeCatalog.runtime(id: id)?.name ?? id
    }

    /// A started session's runtime, and the account it runs on when that is not the
    /// runtime's own sign-in, as the Runtimes rows name it: "Claude · Work" (#2259).
    static func runtimeName(_ agent: Agent, accounts: [AccountProfile]) -> String {
        let runtime = runtimeName(agent.runtimeID)
        let named = accounts.name(of: agent.accountID, on: agent.runtimeID).map { "\(runtime) · \($0)" } ?? runtime
        // An Auto agent says so, with the runtime it picked (#2658, FR-009): "Auto · Claude".
        return agent.auto == nil ? named : LevelWords.header(named)
    }
}

/// Where the agent is working, how full it is, and what runs it: the row above the
/// field once an agent exists.
///
/// What the agent runs in the background, above the prompt. What it waits for on events
/// is a card at the end of the chat (#1995), and what it holds and waits for in line is
/// with the working line (#2344).
/// Live, so shown only while it is so. The settled facts — its place, its runtime,
/// what it has used — are not drawn here: the pills under the prompt are the settings.
struct PromptHeader: View {
    let agent: Agent
    /// What it has running in the background (057): a block of
    /// rows, or on a phone one line that opens them (`compactBackground`).
    var background: [BackgroundItem] = []
    var backgroundActions = BackgroundActions()
    var compactBackground = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if compactBackground {
                BackgroundLine(items: background, actions: backgroundActions)
            } else {
                BackgroundBlock(items: background, actions: backgroundActions)
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
                Text(agent.spentWords(under: limits) + " Anything you send waits until you allow more.")
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
                Text(costState?.limits.isDayTokenLimitReached(tokensToday: costState?.tokensToday ?? 0) == true
                     ? "The day's token limit has been reached"
                     : "The day's spending limit has been reached")
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
