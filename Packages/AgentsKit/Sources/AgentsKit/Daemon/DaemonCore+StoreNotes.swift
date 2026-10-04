import Foundation
import AgentsKitCore

/// What this host could not read in this run, said where the person looks (#205).
///
/// Before, only the Spending page and the Dashboard said a file had been set aside; a
/// `devices.json` or `projects.json` that did not read left paired devices or projects
/// gone from the window with only a log line to say why. Every note `StoreFile` keeps,
/// for the daemon's root and the projects' own files, now reaches the windows: asked on
/// connecting, and broadcast whenever one is added or cleared.
extension DaemonCore {
    public func storeNotes() -> DaemonAPI.StoreNotes {
        var folders = [locations.root] + allProjects(includeArchived: true).map(\.folder)
        if let home = locations.personalHome { folders.append(home.appending(path: PersonalDotAgents.folder)) }
        var seen: Set<String> = []
        let notes = folders.flatMap { SetAsideNotes.shared.notes(under: $0) }.filter { seen.insert($0).inserted }
        return DaemonAPI.StoreNotes(notes: notes)
    }

    /// Once, as the daemon loads: from then on every change to the notes is broadcast.
    func watchStoreNotes() {
        SetAsideNotes.shared.watch { [weak self] in
            Task { await self?.broadcastStoreNotes() }
        }
    }

    func broadcastStoreNotes() {
        broadcast(DaemonAPI.Notification.storeNotesChanged, storeNotes())
    }
}
