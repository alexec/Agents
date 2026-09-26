import Foundation

/// The person's `~/.agents`, kept in line with what each runtime needs (054).
extension DaemonCore {
    /// Reconcile the personal home, if this daemon has one.
    ///
    /// Run once when the daemon starts and again before every session is made, so a
    /// skill added since is there for the next agent without a restart (FR-010). A
    /// scratch root with no `AGENTS_PERSONAL_HOME` has no home and does nothing here,
    /// which is what keeps a walk on a branch build off the person's real `~/.claude`
    /// (research R4). On the actor, so two starts at once never reconcile together.
    func reconcileHome() {
        guard let home = locations.personalHome else { return }
        var record = PersonalDotAgents.Record.load(from: locations.personalLayout, home: home)
        let before = record
        PersonalDotAgents.reconcile(home: home, installed: installedRuntimeIDs(), record: &record)
        guard record != before else { return }
        PersonalDotAgents.attempt("save \(locations.personalLayout.lastPathComponent)") {
            try record.save(to: locations.personalLayout)
        }
    }

    /// The runtimes this Mac can start. A runtime's folder alone is not proof: Antigravity
    /// makes `~/.gemini` whether or not Gemini is here.
    func installedRuntimeIDs() -> Set<String> {
        Set(RuntimeCatalog.builtIn.compactMap { runtime in
            if case .available = discovery.locate(runtime) { return runtime.id }
            return nil
        })
    }
}
