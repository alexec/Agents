import Foundation

/// The Mac's Get started checklist (#982): from a fresh install to a first agent at work,
/// and on to a paired phone or browser. Each step is ticked from what is really so, never
/// from a flag the person sets; the only thing kept is whether the card has gone.
///
/// Pure, so the rules are tested here and #984's milestones can take the same facts.
public enum GetStarted {
    public enum Step: String, CaseIterable, Hashable, Sendable, Identifiable {
        case host, runtime, folder, firstAgent, device

        public var id: String { rawValue }

        /// Pairing a device is offered, not asked for: the card does not wait on it to
        /// call a person set up.
        public var isOptional: Bool { self == .device }

        public var title: String {
            switch self {
            case .host: "Pair this window with Agents Host"
            case .runtime: "Install an agent runtime"
            case .folder: "Add a folder"
            case .firstAgent: "Start your first agent"
            case .device: "Pair a phone or browser"
            }
        }

        /// What the step is about, in one line, under its title while it is not done.
        public var how: String {
            switch self {
            case .host: "Agents Host runs your agents on this Mac."
            case .runtime: "Claude, Codex or another coding CLI, signed in."
            case .folder: "A folder you work in."
            case .firstAgent: "Say what you want done and let it run a turn."
            case .device: "Optional. Answer your agents from anywhere."
            }
        }
    }

    /// What the window knows now, each read from real state.
    public struct Facts: Hashable, Sendable {
        /// This window is paired with a control plane.
        public var paired: Bool
        /// A runtime on this Mac is installed and not known to be signed out. A runtime
        /// says it is signed out only once a call refuses, so "not known to be" is as
        /// close to "signed in" as the app can get.
        public var runtimeReady: Bool
        public var hasFolder: Bool
        /// An agent has run a turn to its end.
        public var ranAgent: Bool
        /// A phone, an iPad or a browser is paired, besides this window.
        public var pairedDevice: Bool

        public init(paired: Bool = false, runtimeReady: Bool = false, hasFolder: Bool = false,
                    ranAgent: Bool = false, pairedDevice: Bool = false) {
            self.paired = paired
            self.runtimeReady = runtimeReady
            self.hasFolder = hasFolder
            self.ranAgent = ranAgent
            self.pairedDevice = pairedDevice
        }

        public func isDone(_ step: Step) -> Bool {
            switch step {
            case .host: paired
            case .runtime: runtimeReady
            case .folder: hasFolder
            case .firstAgent: ranAgent
            case .device: pairedDevice
            }
        }

        /// Every step that is asked for is done: a person already set up.
        public var isSetUp: Bool { Step.allCases.filter { !$0.isOptional }.allSatisfy(isDone) }
        public var isAllDone: Bool { Step.allCases.allSatisfy(isDone) }
        public var doneCount: Int { Step.allCases.filter(isDone).count }
    }

    /// Whether the card shows, as kept between launches.
    public enum Card: String, Sendable {
        case showing
        /// Dismissed, finished, or never needed: it does not come back.
        case gone
    }

    /// The card's state after looking at the facts. `kept` is nil the first time: a person
    /// already set up then never sees the card (Alex, #982), and anybody else does until
    /// every step is done.
    public static func card(kept: Card?, facts: Facts) -> Card {
        switch kept {
        case .gone: .gone
        case nil: facts.isSetUp ? .gone : .showing
        case .showing: facts.isAllDone ? .gone : .showing
        }
    }

    /// Whether an agent has run a turn to its end: any time after its creation, and no
    /// turn in flight now.
    public static func hasRunATurn(_ agent: Agent) -> Bool {
        agent.lastActivityAt > agent.createdAt && !agent.state.hasTurnInFlight && agent.state != .queued
    }

    /// A paired client that is not a Mac window: an iPhone, an iPad or a browser.
    public static func isDeviceOrBrowser(_ client: ClientRecord) -> Bool {
        client.forgotten != true && client.kind != .mac
    }
}
