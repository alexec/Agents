import AgentsKitCore
import Foundation

/// The first build's question page (#5050, `specs/5048-first-build/spec.md`): who sees it,
/// and what Submit does.
extension AppModel {
    /// The window paired with the control plane that the first open set up on this Mac:
    /// the question page stays until Submit, also across a quit.
    func keepAskingFirstBuild() {
        asksFirstBuild = true
        FirstBuildStore.asking = true
    }

    /// Only a newcomer sees the question page (section 9): once the lists are in, a control
    /// plane with a folder or an agent on it (an alpha's set-up, left as it was) is not new.
    func weighFirstBuild() {
        guard asksFirstBuild, !needsFirstRun, hasLoadedFolders, hasLoadedAgents else { return }
        if !liveFolders.isEmpty || !agents.isEmpty { leaveFirstBuildQuestion() }
    }

    /// Submit, once the window is paired. The plan page (#5053) takes the idea from here;
    /// until it is built, the usual window takes the question page's place.
    func submitFirstBuild(_ idea: String) {
        firstBuildIdea = idea
        leaveFirstBuildQuestion()
    }

    private func leaveFirstBuildQuestion() {
        asksFirstBuild = false
        FirstBuildStore.asking = false
    }
}

/// Whether the question page is still to answer, in `WindowDefaults` as the Get started
/// card is, so a scratch copy does not answer the real app's.
enum FirstBuildStore {
    static var asking: Bool {
        get { WindowDefaults.store.bool(forKey: "firstBuild.asking") }
        set { WindowDefaults.store.set(newValue, forKey: "firstBuild.asking") }
    }
}
