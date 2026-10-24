import AgentsKitCore
import Foundation

/// The Get started card (#982): the facts it ticks from, and whether it shows.
extension AppModel {
    /// What the window knows now. A paired device is the card's to say: it alone holds a
    /// connection to the control plane's list of clients, and only while it shows.
    func getStartedFacts(pairedDevice: Bool = false) -> GetStarted.Facts {
        GetStarted.Facts(paired: !needsFirstRun,
                         runtimeReady: !macRuntimesAvailable.isEmpty,
                         hasFolder: !liveFolders.isEmpty,
                         ranAgent: hasSeenAgentRun || agents.contains(where: GetStarted.hasRunATurn),
                         pairedDevice: pairedDevice)
    }

    var showsGetStarted: Bool { getStartedCard == .showing && !needsFirstRun }

    /// Weighed once the lists have all come in, so a person already set up is not taken
    /// for a newcomer by a list that has not arrived yet.
    func weighGetStarted() {
        let facts = getStartedFacts()
        noteAgentRun(facts)
        guard getStartedCard == nil, !needsFirstRun, hasLoadedFolders, hasLoadedAgents, !runtimes.isEmpty else { return }
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

/// The card's state, in `WindowDefaults` as `InstallOffer` is, so a scratch copy does not
/// dismiss the real app's card.
enum GetStartedStore {
    static var kept: GetStarted.Card? {
        get { WindowDefaults.store.string(forKey: "getStarted").flatMap(GetStarted.Card.init(rawValue:)) }
        set { WindowDefaults.store.set(newValue?.rawValue, forKey: "getStarted") }
    }

    static var ranAgent: Bool {
        get { WindowDefaults.store.bool(forKey: "getStarted.ranAgent") }
        set { WindowDefaults.store.set(newValue, forKey: "getStarted.ranAgent") }
    }
}
