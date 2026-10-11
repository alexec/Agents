import Foundation
import AgentsKitCore

/// A project's pinned pages (#159): the person's Pin, Unpin and drag, and the pages
/// themselves, read for every screen. And its pinned sessions (#180) and workflows (#432):
/// the person's Pin, Unpin and drag, from every client. Agents pin nothing since #640;
/// what they pinned before stays, under their names, until the person unpins it.
///
/// The pins are one file in the project folder, `.agents/pins.json`, written whole and
/// only here, inside the actor, never in a worktree; nothing is committed.
extension DaemonCore {
    // MARK: The person's

    public func pinsList() -> [ProjectPins] {
        allProjects(includeArchived: false).compactMap { project in
            let folder = Project.standardize(project.folder)
            let pins = pinViews(folder)
            let file = readPins(folder)
            let sessions = file.sessionPins.map(\.session)
            let workflows = file.workflowPins.map(\.workflow)
            return pins.isEmpty && sessions.isEmpty && workflows.isEmpty ? nil
                : ProjectPins(folder: folder, pins: pins, sessions: sessions, workflows: workflows)
        }
    }

    /// Pin to Project, from any client.
    public func pinByPerson(_ request: DaemonAPI.PinRequest) throws -> [PinView] {
        let project = try knownPinProject(request.folder)
        let lead = "Nothing was pinned: "
        if let view = request.view {
            if let refusal = viewPinRefusal(view, project: project) { throw pinRefusal(lead + refusal) }
            try pin(PinEntry(view: view, title: request.title, pinnedBy: .thePerson), in: project, lead: lead)
            return pinViews(project)
        }
        guard let path = personPinPath(request.path, in: project) else {
            throw pinRefusal(lead + "\(request.path) is not in this project.")
        }
        guard pinFileExists(path, in: project) else {
            throw pinRefusal(lead + "there is no file at \(path) in the project folder.")
        }
        try pin(PinEntry(path: path, title: request.title, pinnedBy: .thePerson), in: project, lead: lead)
        return pinViews(project)
    }

    /// Unpin, from any client: any pin.
    public func unpinByPerson(_ request: DaemonAPI.PinPathRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = try readPinsToChange(project)
        let path = pinKey(request.path) ?? personPinPath(request.path, in: project) ?? request.path
        guard file.pins.contains(where: { $0.path == path }) else {
            throw pinRefusal("Nothing was unpinned: \(request.path) is not pinned in this project.")
        }
        file.pins.removeAll { $0.path == path }
        try writePins(file, in: project)
    }

    /// A drop or a Move item: the whole order. Paths no longer pinned are dropped, and
    /// pins it leaves out keep their place after the ones it names.
    public func arrangePins(_ request: DaemonAPI.PinArrangeRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = try readPinsToChange(project)
        var placed: [PinEntry] = []
        for path in request.paths {
            if let entry = file.pins.first(where: { $0.path == path }), !placed.contains(entry) { placed.append(entry) }
        }
        file.pins = placed + file.pins.filter { !placed.contains($0) }
        try writePins(file, in: project)
    }

    /// Any file in the project folder, for a pinned page or what an HTML
    /// page draws from. Held to the folder: a link out of it is refused, not followed.
    public func readPage(_ request: DaemonAPI.PinReadRequest) throws -> FileReading {
        let project = try knownPinProject(request.folder)
        let url = try pageURL(request.path, in: project)
        do {
            return try FileReading.read(url, known: request.knownStamp)
        } catch FileProbe.Failure.isDirectory {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is a folder.")
        } catch FileProbe.Failure.notReadable {
            throw Self.notReadable(url)
        } catch {
            throw Self.gone(url)
        }
    }

    /// What a person typed on a pinned Markdown page. Only a Markdown file in the folder.
    public func writePage(_ request: DaemonAPI.PinWriteRequest) throws {
        let project = try knownPinProject(request.folder)
        let url = try pageURL(request.path, in: project)
        guard PinRules.kind(request.path) == .markdown else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Only a Markdown page can be typed on.")
        }
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard previous != request.text else { return }
        do {
            try Data(request.text.utf8).write(to: url, options: .atomic)
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "Could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Pinned sessions (#180)

    /// Pin, from any client: any session of the project that is not archived.
    public func pinSessionByPerson(_ request: DaemonAPI.PinSessionRequest) throws {
        let project = try knownPinProject(request.folder)
        let lead = "Nothing was pinned: "
        guard let agent = agents[request.agentID], Project.standardize(agent.projectFolder) == project else {
            throw pinRefusal(lead + "that session is not in this project.")
        }
        guard agent.state != .archived else { throw pinRefusal(lead + "an archived session can't be pinned.") }
        var file = readPins(project)
        guard !file.sessionPins.contains(where: { $0.session == request.agentID }) else { return }
        guard file.sessionPins.count < PinLimits.sessionsPerProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.sessionsPerProject) pinned sessions, the most "
                + "it can have. Unpin one first.")
        }
        file.sessionPins.append(SessionPinEntry(session: request.agentID, pinnedBy: .thePerson))
        try writePins(file, in: project)
    }

    /// Unpin, from any client: any pinned session, whoever pinned it.
    public func unpinSessionByPerson(_ request: DaemonAPI.PinSessionRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = readPins(project)
        guard file.sessionPins.contains(where: { $0.session == request.agentID }) else { return }
        file.sessionPins.removeAll { $0.session == request.agentID }
        try writePins(file, in: project)
    }

    /// A drop or a Move item among the pinned sessions: the whole order, as for pages.
    public func arrangeSessionPins(_ request: DaemonAPI.PinArrangeSessionsRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = readPins(project)
        var placed: [SessionPinEntry] = []
        for id in request.agentIDs {
            if let entry = file.sessionPins.first(where: { $0.session == id }), !placed.contains(entry) {
                placed.append(entry)
            }
        }
        file.sessionPins = placed + file.sessionPins.filter { !placed.contains($0) }
        try writePins(file, in: project)
    }

    /// Archiving a session unpins it; bringing it back does not pin it again.
    func unpinArchived(_ agentID: UUID, in folder: URL) {
        let project = Project.standardize(folder)
        var file = readPins(project)
        guard file.sessionPins.contains(where: { $0.session == agentID }) else { return }
        file.sessionPins.removeAll { $0.session == agentID }
        do {
            try writePins(file, in: project)
        } catch {
            DaemonLog.shared.write("archived \(agentID) but could not unpin it: \(error)")
        }
    }

    // MARK: Pinned workflows (#432)

    /// Pin, from any client: any workflow of the project that is not archived. Only the
    /// person pins one; no agent tool does.
    public func pinWorkflowByPerson(_ request: DaemonAPI.WorkflowRequest) throws {
        let project = try knownPinProject(request.folder)
        let lead = "Nothing was pinned: "
        guard let workflow = workflow(request.workflowID, in: project) else {
            throw pinRefusal(lead + "there is no workflow called \(request.workflowID) in this project.")
        }
        guard !workflow.isArchived else { throw pinRefusal(lead + "an archived workflow can't be pinned.") }
        var file = try readPinsToChange(project)
        guard !file.workflowPins.contains(where: { $0.workflow == request.workflowID }) else { return }
        guard file.workflowPins.count < PinLimits.workflowsPerProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.workflowsPerProject) pinned workflows, "
                + "the most it can have. Unpin one first.")
        }
        file.workflowPins.append(WorkflowPinEntry(workflow: request.workflowID, pinnedBy: .thePerson))
        try writePins(file, in: project)
    }

    /// Unpin, from any client: any pinned workflow.
    public func unpinWorkflowByPerson(_ request: DaemonAPI.WorkflowRequest) throws {
        let project = try knownPinProject(request.folder)
        guard readPins(project).workflowPins.contains(where: { $0.workflow == request.workflowID }) else { return }
        var file = try readPinsToChange(project)
        file.workflowPins.removeAll { $0.workflow == request.workflowID }
        try writePins(file, in: project)
    }

    /// A drop or a Move item among the pinned workflows: the whole order, as for sessions.
    public func arrangeWorkflowPins(_ request: DaemonAPI.PinArrangeWorkflowsRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = try readPinsToChange(project)
        var placed: [WorkflowPinEntry] = []
        for id in request.workflowIDs {
            if let entry = file.workflowPins.first(where: { $0.workflow == id }), !placed.contains(entry) {
                placed.append(entry)
            }
        }
        file.workflowPins = placed + file.workflowPins.filter { !placed.contains($0) }
        try writePins(file, in: project)
    }

    /// Archiving a workflow unpins it, as archiving a session does; Bring Back does not
    /// pin it again.
    func unpinArchivedWorkflow(_ workflowID: String, in folder: URL) {
        let project = Project.standardize(folder)
        guard readPins(project).workflowPins.contains(where: { $0.workflow == workflowID }) else { return }
        do {
            var file = try readPinsToChange(project)
            file.workflowPins.removeAll { $0.workflow == workflowID }
            try writePins(file, in: project)
        } catch {
            DaemonLog.shared.write("archived workflow \(workflowID) but could not unpin it: \(error)")
        }
    }

    // MARK: Changes

    /// Something changed under a project: its pins file, a pinned page or one beside it.
    /// Called from the project's own watch, which sees the whole folder.
    func pinFilesChanged(_ changed: [URL], in project: URL) {
        let base = project.standardizedFileURL.path(percentEncoded: false)
        let root = base.hasSuffix("/") ? base : base + "/"
        let ignored = MentionIgnore(folder: project)
        // Folders inside the project, relative to it, worktrees and git's own left out.
        let folders = Set(changed.compactMap { url -> String? in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            if path == base || path + "/" == root { return "" }
            guard path.hasPrefix(root) else { return nil }
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.hasPrefix(".agents/worktrees") || relative == ".git" || relative.hasPrefix(".git/") { return nil }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if ignored.skips(relative, isDirectory: isDirectory.boolValue) { return nil }
            return relative
        })
        guard !folders.isEmpty else { return }
        if folders.contains(".agents") { pinsChanged(project) }
        let pages = pagePaths(project)
        guard !pages.isEmpty else { return }
        // A page's own folder, or below an HTML page's, where its pictures and styles are.
        let touched = folders.filter { folder in
            pages.contains { page in
                let home = (page as NSString).deletingLastPathComponent
                return folder == home || (PinRules.kind(page) == .html && (home.isEmpty || folder.hasPrefix(home + "/")))
            }
        }
        guard !touched.isEmpty else { return }
        // A pinned file coming or going changes its row.
        if pinViews(project) != pinsSent[project] { pinsChanged(project) }
        pagesChanged(project, folders: touched)
    }

    /// Every pinned page's file: what a screen may be showing.
    ///
    /// One stat when nothing changed (#216): the pins are held, and read again only when
    /// their own file changes.
    func pagePaths(_ project: URL) -> [String] {
        readPins(project).pins.filter { $0.view == nil }.map(\.path)
    }

    /// The project's watch saw these folders change: what was read from them is read
    /// again when next asked, and nothing else is (#216).
    func forgetProjectFileCaches(_ changed: [URL], in project: URL) {
        let agents = project.appending(path: ".agents").path
        if changed.contains(where: { $0.path == agents }) { pinsCache[project] = nil }
    }

    /// Tell every screen, at most once a second per project.
    func pinsChanged(_ project: URL) {
        guard pinBroadcasts[project] == nil else { return }
        pinBroadcasts[project] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.pinBroadcastGap))
            await self?.sendPinsChanged(project)
        }
    }

    static let pinBroadcastGap = 1000

    private func sendPinsChanged(_ project: URL) {
        pinBroadcasts[project] = nil
        let pins = pinViews(project)
        pinsSent[project] = pins
        let file = readPins(project)
        broadcast(DaemonAPI.Notification.pinsChanged,
                  DaemonAPI.PinsChangedNotification(folder: project, pins: pins,
                                                    sessions: file.sessionPins.map(\.session),
                                                    workflows: file.workflowPins.map(\.workflow)))
    }

    func pagesChanged(_ project: URL, folders: Set<String>) {
        pagesPending[project, default: []].formUnion(folders)
        guard pageBroadcasts[project] == nil else { return }
        pageBroadcasts[project] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.pageBroadcastGap))
            await self?.sendPagesChanged(project)
        }
    }

    static let pageBroadcastGap = 300

    private func sendPagesChanged(_ project: URL) {
        pageBroadcasts[project] = nil
        let folders = pagesPending.removeValue(forKey: project) ?? []
        guard !folders.isEmpty else { return }
        broadcast(DaemonAPI.Notification.pagesChanged,
                  DaemonAPI.PagesChangedNotification(folder: project, folders: folders.sorted()))
    }

    // MARK: Inside

    func pinViews(_ project: URL) -> [PinView] {
        readPins(project).pins.compactMap { entry in
            if let view = entry.view {
                let reason = viewPinMissing(view, project: project)
                return PinView(path: view.uri, title: entry.title ?? PinRules.defaultTitle(view), kind: .view,
                               missing: reason != nil, pinnedBy: pinnerView(entry.pinnedBy, in: project),
                               view: view, missingReason: reason)
            }
            guard let kind = PinRules.kind(entry.path) else { return nil }
            return PinView(path: entry.path, title: entry.title ?? PinRules.defaultTitle(entry.path), kind: kind,
                           missing: !pinFileExists(entry.path, in: project),
                           pinnedBy: pinnerView(entry.pinnedBy, in: project))
        }
    }

    static func pinsFileURL(_ project: URL) -> URL {
        project.appending(path: PinsFile.path)
    }

    /// The project's pins. One that does not read (a merge's conflict markers, a newer
    /// build's pinner, a read error) shows as none and is never written over: a copy goes
    /// under the daemon's root and every pin change is refused until it reads (#205).
    ///
    /// Read once per change of the file (#216): every wake in the project asks, and the
    /// file's stamp — one stat — says whether the copy held here is still it.
    func readPins(_ project: URL) -> PinsFile {
        let url = Self.pinsFileURL(project)
        let stamp = FileStamp(url)
        if let held = pinsCache[project], held.stamp == stamp { return held.file }
        pinsReads += 1
        let file: PinsFile
        // A file changed outside the app is not used until the person keeps it (#502).
        let guarded = guardedContent(.pins, in: project)
        if guarded.onDisk {
            let read = StoreFile.read(at: url, meaning: "no pins show",
                                      outside: locations.root) { try PinsFile.read($0).file }
            if case .read(let found) = read { file = found } else { file = PinsFile() }
        } else {
            file = guarded.data.flatMap { try? PinsFile.read($0).file } ?? PinsFile()
        }
        pinsCache[project] = (stamp, file)
        return file
    }

    /// The pins, to change; refused while the file is held, before anything else is said.
    /// What this build cannot show (a newer build's kind of page, pinner or field) is
    /// dropped by the write, so the whole file is first kept under the daemon's root (#205).
    func readPinsToChange(_ project: URL) throws -> PinsFile {
        let url = Self.pinsFileURL(project)
        let file = readPins(project)
        do {
            try StoreFile.requireWritable(url)
        } catch {
            throw pinRefusal("The pins were not changed: \(error.localizedDescription)")
        }
        if let data = try? StoreFile.reader(url), let read = try? PinsFile.read(data),
           let raw = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
           raw != (try? read.file.fileData()).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? NSDictionary }) {
            StoreFile.keepPartCopy(url, under: locations.root, what: "pins this build cannot show")
        }
        return file
    }

    func writePins(_ file: PinsFile, in project: URL) throws {
        let url = Self.pinsFileURL(project)
        guard guardedFileIsSettled(.pins, in: project) else {
            throw pinRefusal(guardedRefusal(.pins, lead: "The pins were not changed: "))
        }
        do {
            if file.isEmpty {
                try StoreFile.requireWritable(url)
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                let data = try file.fileData()
                if (try? Data(contentsOf: url)) != data {
                    try StoreFile.write(data, to: url)
                }
            }
        } catch {
            throw pinRefusal("The pins could not be written in \(project.path)/.agents: \(error.localizedDescription)")
        }
        approveGuardedWrite(.pins, in: project)
        pinsCache[project] = nil
        pinsChanged(project)
    }

    /// Pin or retitle, under the limit. A view pinned again takes the new call's arguments.
    private func pin(_ entry: PinEntry, in project: URL, lead: String) throws {
        let path = entry.path
        guard entry.view != nil || PinRules.kind(path) != nil else {
            throw pinRefusal(lead + "only a Markdown (.md) or HTML (.html) page can be pinned.")
        }
        if let title = entry.title, title.count > PinLimits.titleLength {
            throw pinRefusal(lead + "`title` is at most \(PinLimits.titleLength) characters.")
        }
        var file = try readPinsToChange(project)
        if let index = file.pins.firstIndex(where: { $0.path == path }) {
            if let title = entry.title { file.pins[index].title = title }
            if let view = entry.view { file.pins[index].view = view }
            try writePins(file, in: project)
            return
        }
        guard file.pinCount < PinLimits.perProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.perProject) pins, pages and views together, "
                + "the most it can have. Unpin one first.")
        }
        file.pins.append(entry)
        try writePins(file, in: project)
    }

    private func pinnerView(_ pinner: Pinner, in project: URL) -> PinnerView {
        if pinner.isPerson { return PinnerView(kind: .person, id: "", name: "the person") }
        if let workflow = pinner.workflow {
            return PinnerView(kind: .workflow, id: workflow, name: workflows[project]?[workflow]?.name ?? workflow)
        }
        if let id = pinner.agentID {
            let name = agents[id]?.title ?? "an agent not on this host"
            return PinnerView(kind: .agent, id: id.uuidString, name: name)
        }
        return PinnerView(kind: .person, id: "", name: "the person")
    }

    /// A pinned view's key: its `ui://` address, as given (#189).
    private func pinKey(_ given: String) -> String? {
        given.hasPrefix("ui://") ? given : nil
    }

    private func personPinPath(_ given: String, in project: URL) -> String? {
        given.hasPrefix("/") ? PinRules.relative(given, in: project) : PinRules.normalize(given)
    }

    private func pinFileExists(_ path: String, in project: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: project.appending(path: path).path(percentEncoded: false),
                                              isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// A file in the project folder, its links resolved, still in the folder.
    private func pageURL(_ path: String, in project: URL) throws -> URL {
        let relative = path.hasPrefix("/") ? PinRules.relative(path, in: project) : PinRules.normalize(path)
        guard let relative else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(path) is not in this project.")
        }
        let url = project.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
        let home = project.standardizedFileURL.resolvingSymlinksInPath()
        guard PinRules.relative(url.path(percentEncoded: false), in: home) != nil else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "\(path) is not in this project.")
        }
        return url
    }

    /// A project this host has, by its folder: a screen's pin calls name one.
    private func knownPinProject(_ folder: URL) throws -> URL {
        let project = Project.standardize(folder)
        guard isProject(project) else {
            throw pinRefusal("This host has no project at \(project.path).")
        }
        return project
    }

    func pinRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.pinRefused, message: message)
    }
}
