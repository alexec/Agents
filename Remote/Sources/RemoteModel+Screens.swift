import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: What the screens read

    var folders: [DaemonAPI.FolderSummary] { work.liveFolders }

    /// One host's heading in the folder list. Several hosts, and the list is grouped
    /// under these; one host, and there is no heading, as on the Mac (058, frame H).
    struct HostSection: Identifiable {
        /// The id folders from this host are stamped with. The phone's own Mac is
        /// `.mac`, whichever id the control plane gave that host.
        var id: MachineRef
        var title: String
        var offline: Bool
    }

    var hostSections: [HostSection] {
        guard controlHosts.count > 1, let home = controlHome else { return [] }
        let homeRecord = controlHosts.first { $0.id == home }
        var sections = [HostSection(id: .mac, title: "This Mac",
                                    offline: homeRecord?.state == "offline")]
        for host in controlHosts where host.id != home && host.id != .mac {
            sections.append(HostSection(id: host.id, title: host.name.isEmpty ? host.id.rawValue : host.name,
                                        offline: host.state == "offline"))
        }
        return sections
    }

    /// Whether `host`'s folders are last known rather than current (frame H greys them).
    /// A host's name as a server folder's row leads with it (#145): `devbox:api`.
    func hostLabel(_ host: MachineRef) -> String {
        hostSections.first { $0.id == host }?.title ?? host.rawValue
    }

    func hostIsOffline(_ host: MachineRef) -> Bool {
        hostSections.first { $0.id == host }?.offline ?? false
    }

    /// The open folder's standing arrangements.
    var workflows: [WorkflowSummary] { work.workflows(in: selectedFolder) }

    var userWorkflows: [WorkflowSummary] { work.userWorkflows }

    /// What the sidebar has picked (#226), the Mac's one value for it: the first of what is
    /// open over the folder — a pinned page, a workflow, a chat — and what
    /// was opened from that is pushed over it in the detail. A folder chosen with nothing
    /// open over it starts a new session in it, as the Mac's New session row does (#375):
    /// only that row and the folder's New Session (long press, swipe) choose it so; a
    /// tap on the folder's own row only folds it. Nothing open and no new session asked
    /// for, and nothing is picked (#2090).
    var sidebarItem: SidebarItem? {
        get {
            // Work's row is its list's (#4004), and Back can go to another list.
            if case .work = openActivity { return .work(workPlace.kind) }
            if let openActivity { return openActivity }
            guard let key = selectedKey else { return nil }
            switch openArchive {
            case .sessions: return .archivedSessions(key)
            case .workflows: return .archivedWorkflows(key)
            case nil: break
            }
            if let openPin { return .pin(openPin, in: key) }
            if let openWorkflow { return .workflow(openWorkflow, in: key) }
            if let selection { return .session(selection) }
            if let openReview { return .review(openReview, in: key) }
            return composing ? .folder(key) : nil
        }
        set {
            defer {
                if case .folder = newValue { composing = true } else { composing = false }
            }
            switch newValue {
            case nil:
                openActivity = nil
                selectedKey = nil
                selection = nil
                openWorkflow = nil
                openPin = nil
                openArchive = nil
                openReview = nil
            case .folder(let key):
                selectedKey = key
                selection = nil
                openPin = nil
                openWorkflow = nil
                openArchive = nil
                openReview = nil
                // The next New Session at the sidebar's top starts here too (#495).
                rememberNewSessionFolder(key)
            case .session(let id):
                if let agent = work.agent(id) { selectedKey = FolderKey(host: agent.host, folder: agent.folderPath) }
                openPin = nil
                openWorkflow = nil
                openArchive = nil
                openReview = nil
                selection = id
            case .workflow(let id, let key):
                selectedKey = key
                openPin = nil
                selection = nil
                openArchive = nil
                openReview = nil
                openWorkflow = id
            case .pin(let path, let key):
                selectedKey = key
                openWorkflow = nil
                selection = nil
                openArchive = nil
                openReview = nil
                openPin = path
            case .review(let id, let key):
                // A change waiting for an OK (#1472), from its row under Needs You.
                selectedKey = key
                selection = nil
                openPin = nil
                openWorkflow = nil
                openArchive = nil
                openReview = id
            case .resources, .events, .runtimes, .summary, .secretsStatus, .accountsStatus:
                openActivity = newValue
            case .work(let kind):
                // The list's row: its list, or the place in it still open (#4004).
                if workPlace.kind != kind { workHistory.go(WorkPlace(kind: kind)) }
                openActivity = newValue
            case .archivedSessions(let key), .archivedWorkflows(let key):
                // One of the folder's archive pages (#495, #4448), with what is opened from
                // it pushed over it.
                selectedKey = key
                selection = nil
                openPin = nil
                openWorkflow = nil
                openReview = nil
                if case .archivedSessions = newValue { openArchive = .sessions } else { openArchive = .workflows }
            case .machine:
                // A machine's page (#4034), as the window's Machines group opens it.
                openActivity = newValue
            case .multiplier, .velocity:
                // The Multiplier page (#4116) and Velocity (#4758), from their rows under Status.
                openActivity = newValue
            case .spending, .tokens, .time,
                 .folderMCPServers, .docs, .messages:
                // Cost, Tokens, Time, a folder's connectors and Docs are Mac + web (#2798,
                // #3321): the Remote opens none of them.
                break
            }
        }
    }

    var selectedSummary: DaemonAPI.FolderSummary? { work.folder(selectedKey) }

    /// The folder New Session at the top of the sidebar starts in (#495, #498, #2160): the
    /// window's rule, `NewSessionFolder`. A change of choice is said in remote.log.
    var newSessionFolder: FolderKey? {
        let chosen = NewSessionFolder.choose(live: folders.map(\.key), remembered: rememberedNewSessionFolder,
                                              selected: selectedSummary?.key)
        if chosen != saidNewSessionFolder {
            saidNewSessionFolder = chosen
            note("new session: \(chosen?.sentence ?? "no folder")")
        }
        return chosen?.key
    }

    /// Every way into a folder's New session calls this, and a start in it (#2160).
    func rememberNewSessionFolder(_ key: FolderKey) {
        rememberProjectFolder(key)
        guard rememberedNewSessionFolder != key else { return }
        rememberedNewSessionFolder = key
        UserDefaults.standard.set(key.stored, forKey: Self.newSessionFolderDefault)
    }

    /// New Session's projects (#3279): the live folders in the sidebar's order, as
    /// projects. A project with one folder is that folder, as before.
    var newSessionProjects: [NewSessionProject.Choice] {
        let servers = hostSections.map(\.id).filter { $0 != .mac }
        return NewSessionProject.choices(SidebarOrder.folders(folders, servers: servers))
    }

    /// A new session in the project, in the folder last used in it (#3279): the Remote is
    /// no machine of the project's, so "this machine" is the one last used.
    func showProject(_ choice: NewSessionProject.Choice) {
        let remembered = rememberedProjectFolders[choice.id].flatMap(FolderKey.init(stored:))
        guard let key = NewSessionProject.folder(in: choice, isHere: { _ in false }, remembered: remembered) else { return }
        sidebarItem = .folder(key)
    }

    /// A machine listed its folders, or left the control plane (`listed` empty): what the
    /// Remote keeps by folder there goes for each folder it no longer has (#3750). An offline
    /// machine lists nothing, so its folds stay. The Remote lists no archived folders and
    /// shows none, so theirs go too.
    func pruneFolderDefaults(of host: MachineRef, listed: [DaemonAPI.FolderSummary]) {
        let keys = listed.map { FolderKey(host: host, folder: $0.folder.folder) }
        ClientDefaults.pruneFolders(.standard, host: host, listed: keys)
        let kept = ClientDefaults.pruneProjectFolders(rememberedProjectFolders, host: host, listed: keys)
        guard kept != rememberedProjectFolders else { return }
        rememberedProjectFolders = kept
        UserDefaults.standard.set(kept, forKey: Self.newSessionProjectFoldersDefault)
    }

    func rememberProjectFolder(_ key: FolderKey) {
        guard let summary = work.folder(key) else { return }
        let id = NewSessionProject.id(of: summary)
        guard rememberedProjectFolders[id] != key.stored else { return }
        rememberedProjectFolders[id] = key.stored
        UserDefaults.standard.set(rememberedProjectFolders, forKey: Self.newSessionProjectFoldersDefault)
    }

    var selectedAgent: Agent? { work.agent(selection) }

    var entries: [TranscriptEntry] { work.entries }

    var transcriptItems: [TranscriptItem] { work.transcriptItems }

    /// What the reader will allow, as the Mac has it. The phone shows limits and does
    /// not set them; it can only let one agent go on past its own (033).
    var costState: DaemonAPI.CostState? { work.costState }

    var costLimits: CostLimits { work.costState?.limits ?? CostLimits() }

    var hasMoreBefore: Bool { work.hasMoreBefore }

    /// Told by the conversation, which is the only thing that knows how tall it is.
    func measure(transcriptHeight height: CGFloat) {
        guard height > 0 else { return }
        let entries = (height / Self.entryHeight) * Self.screensHeld
        firstPageSize = min(200, max(30, Int(entries.rounded())))
    }
}
