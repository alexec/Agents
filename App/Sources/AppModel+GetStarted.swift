import AgentsKitCore
import Foundation

/// The Get started card (#982): the facts it ticks from, and whether it shows.
extension AppModel {
    /// What the window knows now. A paired device is the card's to say: it alone holds a
    /// connection to the control plane's list of clients, and only while it shows.
    func getStartedFacts(pairedDevice: Bool = false) -> GetStarted.Facts {
        GetStarted.Facts(paired: !needsFirstRun,
                         runtimeReady: !macRuntimesAvailable.isEmpty,
                         hasProject: !liveProjects.isEmpty,
                         ranAgent: hasSeenAgentRun || agents.contains(where: GetStarted.hasRunATurn),
                         pairedDevice: pairedDevice)
    }

    var showsGetStarted: Bool { getStartedCard == .showing && !needsFirstRun }

    /// Weighed once the lists have all come in, so a person already set up is not taken
    /// for a newcomer by a list that has not arrived yet.
    func weighGetStarted() {
        let facts = getStartedFacts()
        noteAgentRun(facts)
        guard getStartedCard == nil, !needsFirstRun, hasLoadedProjects, hasLoadedAgents, !runtimes.isEmpty else { return }
        keepGetStarted(GetStarted.card(kept: nil, facts: facts))
        // Already set up: the install sheet offers what is missing, as before.
        if getStartedCard == .gone { weighInstallOffer() }
    }

    /// The card's facts changed while it shows: every step done takes it away.
    func reweighGetStarted(pairedDevice: Bool) {
        let facts = getStartedFacts(pairedDevice: pairedDevice)
        noteAgentRun(facts)
        guard let kept = getStartedCard else { return }
        keepGetStarted(GetStarted.card(kept: kept, facts: facts))
    }

    private func noteAgentRun(_ facts: GetStarted.Facts) {
        guard facts.ranAgent, !hasSeenAgentRun else { return }
        hasSeenAgentRun = true
        GetStartedStore.ranAgent = true
    }

    /// Dismissed. The install sheet does not then open on its own until the next launch.
    func dismissGetStarted() {
        hasWeighedInstallOffer = true
        keepGetStarted(.gone)
    }

    private func keepGetStarted(_ card: GetStarted.Card) {
        guard card != getStartedCard else { return }
        getStartedCard = card
        GetStartedStore.kept = card
    }
}

/// The card's state, kept per root as `InstallOffer` is, and per walk: every copy of the
/// app shares one defaults domain, and a scratch copy must not dismiss the real app's card.
/// A walk's window (run-app) reads the standard root, so its walk name is the scope there.
enum GetStartedStore {
    private static func key(_ name: String) -> String {
        if let walk = ControlConfig.walk { return "\(name).walk:\(walk)" }
        let locations = StoreLocations.default
        return locations.isStandard ? name : "\(name).root:\(locations.name)"
    }

    static var kept: GetStarted.Card? {
        get { UserDefaults.standard.string(forKey: key("getStarted")).flatMap(GetStarted.Card.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: key("getStarted")) }
    }

    static var ranAgent: Bool {
        get { UserDefaults.standard.bool(forKey: key("getStarted.ranAgent")) }
        set { UserDefaults.standard.set(newValue, forKey: key("getStarted.ranAgent")) }
    }
}
