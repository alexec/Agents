import Foundation
import AgentsKitCore

/// A project's pinned pages (#159): the agents' `pin_page`, `unpin_page` and `move_pin`,
/// the person's Pin, Unpin and drag, and the pages themselves, read for every screen.
/// And its pinned sessions (#180): `pin_session`, and the person's Pin, Unpin and drag.
/// And its pinned workflows (#432): the person's Pin, Unpin and drag, from every client.
///
/// The pins are one file in the project folder, `.agents/pins.json`, written whole and
/// only here, inside the actor, never in a worktree; nothing is committed.
extension DaemonCore {
    // MARK: Agents' tools

    /// `pin_page`: pin a Markdown or HTML file in the caller's project, or retitle one.
    public func pinPage(_ request: DaemonAPI.PinToolRequest) throws -> String {
        let caller = try pinCaller(request.token)
        let project = caller.projectFolder
        try requireFolder(project)
        let lead = "Nothing was pinned: "
        let arguments = request.arguments
        if arguments["view"] != nil { return try pinViewTool(arguments, for: caller, lead: lead) }
        guard let given = pinText(arguments, "path") else {
            throw pinRefusal(lead + "say which file, in `path`, or which view, in `view`.")
        }
        guard let path = agentPinPath(given, for: caller) else {
            throw pinRefusal(lead + "\(given) is not in this project. Give a path in the project folder, "
                + "relative to it or absolute.")
        }
        let title = pinText(arguments, "title")
        let position = pinText(arguments, "position")
        if let position, position != "first", position != "last" {
            throw pinRefusal(lead + "`position` is first or last.")
        }
        let inProject = pinFileExists(path, in: project)
        let inWorktree = caller.worktree != nil && FileManager.default.fileExists(
            atPath: caller.cwd.appending(path: path).path(percentEncoded: false))
        guard inProject || inWorktree else {
            throw pinRefusal(lead + "there is no file at \(path) in the project folder"
                + (caller.worktree != nil ? " or in your worktree." : "."))
        }
        let notes = try pin(PinEntry(path: path, title: title, pinnedBy: pinner(for: caller)), first: position == "first",
                            in: project, lead: lead)
        var lines = notes
        if !inProject {
            lines.append("\(path) is only in your worktree so far. The pin opens the project folder's copy, "
                + "so it shows as missing until your branch lands there.")
        }
        return (lines + ["", pinsWords(project, for: caller)]).joined(separator: "\n")
    }

    /// `unpin_page`: unpin a page the caller (or its workflow) pinned.
    public func unpinPage(_ request: DaemonAPI.PinToolRequest) throws -> String {
        let caller = try pinCaller(request.token)
        let project = caller.projectFolder
        let lead = "Nothing was unpinned: "
        guard let given = pinText(request.arguments, "path") else { throw pinRefusal(lead + "say which page, in `path`.") }
        var file = try readPinsToChange(project)
        guard let path = pinKey(given) ?? agentPinPath(given, for: caller),
              let index = file.pins.firstIndex(where: { $0.path == path }) else {
            throw pinRefusal(lead + "\(given) is not pinned in this project.")
        }
        let held = file.pins[index].pinnedBy
        guard held == pinner(for: caller) else {
            let who = pinnerView(held, in: project)
            throw pinRefusal(lead + "\(path) was pinned by \(pinnerWords(who)). Only the person, or whoever pinned it, "
                + "can unpin it.")
        }
        file.pins.remove(at: index)
        try writePins(file, in: project)
        return "Unpinned \(path).\n\n" + pinsWords(project, for: caller)
    }

    /// `move_pin`: put any pin somewhere else, as a person can drag any pin.
    public func movePin(_ request: DaemonAPI.PinToolRequest) throws -> String {
        let caller = try pinCaller(request.token)
        let project = caller.projectFolder
        let lead = "Nothing was moved: "
        let arguments = request.arguments
        guard let given = pinText(arguments, "path") else { throw pinRefusal(lead + "say which page, in `path`.") }
        var file = try readPinsToChange(project)
        let paths = file.pins.map(\.path)
        guard let path = pinKey(given) ?? agentPinPath(given, for: caller), paths.contains(path) else {
            throw pinRefusal(lead + "\(given) is not pinned in this project.")
        }
        let rawBefore = pinText(arguments, "before"), rawAfter = pinText(arguments, "after")
        let position = pinText(arguments, "position")
        guard [rawBefore, rawAfter, position].compactMap({ $0 }).count == 1 else {
            throw pinRefusal(lead + "give one of `before`, `after` or `position`.")
        }
        func pinned(_ other: String) throws -> String {
            guard let found = pinKey(other) ?? agentPinPath(other, for: caller), paths.contains(found) else {
                throw pinRefusal(lead + "\(other) is not pinned in this project.")
            }
            guard found != path else { throw pinRefusal(lead + "a page can't go next to itself.") }
            return found
        }
        let before = try rawBefore.map(pinned)
        let after = try rawAfter.map(pinned)
        if let position, position != "first", position != "last" {
            throw pinRefusal(lead + "`position` is first or last.")
        }
        let order = PinRules.moving(paths, path, before: before, after: after, first: position == "first")
        file.pins = order.compactMap { want in file.pins.first { $0.path == want } }
        try writePins(file, in: project)
        return "Moved \(path).\n\n" + pinsWords(project, for: caller)
    }

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
            _ = try pin(PinEntry(view: view, title: request.title, pinnedBy: .thePerson), first: false, in: project, lead: lead)
            return pinViews(project)
        }
        guard let path = personPinPath(request.path, in: project) else {
            throw pinRefusal(lead + "\(request.path) is not in this project.")
        }
        guard pinFileExists(path, in: project) else {
            throw pinRefusal(lead + "there is no file at \(path) in the project folder.")
        }
        _ = try pin(PinEntry(path: path, title: request.title, pinnedBy: .thePerson), first: false, in: project, lead: lead)
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

    /// `pin_session`: the caller pins its own session at the top of its project, or, with
    /// `pinned: false`, unpins it if it was the one that pinned it.
    public func pinSessionTool(_ request: DaemonAPI.PinToolRequest) throws -> String {
        let caller = try pinCaller(request.token)
        let project = caller.projectFolder
        try requireFolder(project)
        let arguments = request.arguments
        let wantsPinned = arguments["pinned"]?.boolValue ?? true
        let position = pinText(arguments, "position")
        if let position, position != "first", position != "last" {
            throw pinRefusal((wantsPinned ? "Nothing was pinned: " : "Nothing was unpinned: ") + "`position` is first or last.")
        }
        var file = readPins(project)
        let index = file.sessionPins.firstIndex { $0.session == caller.id }
        if wantsPinned {
            if index != nil { return "This session was already pinned.\n\n" + sessionPinsWords(project, for: caller) }
            try pinSession(caller.id, first: position == "first", by: .agent(caller.id), in: project,
                           lead: "Nothing was pinned: ")
            return "Pinned this session at the top of its project, in .agents/pins.json in the project folder.\n\n"
                + sessionPinsWords(project, for: caller)
        }
        guard let index else { return "This session was not pinned.\n\n" + sessionPinsWords(project, for: caller) }
        guard file.sessionPins[index].pinnedBy == .agent(caller.id) else {
            throw pinRefusal("Nothing was unpinned: this session was pinned by the person. Only the person, or "
                + "whoever pinned it, can unpin it.")
        }
        file.sessionPins.remove(at: index)
        try writePins(file, in: project)
        return "Unpinned this session.\n\n" + sessionPinsWords(project, for: caller)
    }

    /// Pin, from any client: any session of the project that is not archived.
    public func pinSessionByPerson(_ request: DaemonAPI.PinSessionRequest) throws {
        let project = try knownPinProject(request.folder)
        let lead = "Nothing was pinned: "
        guard let agent = agents[request.agentID], Project.standardize(agent.projectFolder) == project else {
            throw pinRefusal(lead + "that session is not in this project.")
        }
        guard agent.state != .archived else { throw pinRefusal(lead + "an archived session can't be pinned.") }
        guard !readPins(project).sessionPins.contains(where: { $0.session == request.agentID }) else { return }
        try pinSession(request.agentID, first: false, by: .thePerson, in: project, lead: lead)
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

    private func pinSession(_ id: UUID, first: Bool, by who: Pinner, in project: URL, lead: String) throws {
        var file = readPins(project)
        guard file.sessionPins.count < PinLimits.sessionsPerProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.sessionsPerProject) pinned sessions, the most "
                + "it can have. Unpin one first, or ask the person which to unpin.")
        }
        let entry = SessionPinEntry(session: id, pinnedBy: who)
        if first { file.sessionPins.insert(entry, at: 0) } else { file.sessionPins.append(entry) }
        try writePins(file, in: project)
    }

    /// The pinned sessions, numbered, for `pin_session`'s answer.
    func sessionPinsWords(_ project: URL, for caller: Agent) -> String {
        let entries = readPins(project).sessionPins
        guard !entries.isEmpty else { return "This project has no pinned sessions." }
        let lines = entries.enumerated().map { index, entry in
            let name = entry.session == caller.id ? "this session"
                : agents[entry.session].map { "\u{201C}\($0.title ?? "Untitled")\u{201D}" } ?? "a session not on this host"
            return "\(index + 1). \(name)"
        }
        return (["Pinned sessions (\(entries.count) of \(PinLimits.sessionsPerProject)), at the top of the project:"]
            + lines).joined(separator: "\n")
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
        let read = StoreFile.read(at: url, meaning: "no pins show",
                                  outside: locations.root) { try PinsFile.read($0).file }
        let file: PinsFile
        if case .read(let found) = read { file = found } else { file = PinsFile() }
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
        pinsCache[project] = nil
        pinsChanged(project)
    }

    /// Pin or retitle, under the limit. Returns what to say. A view pinned again takes the
    /// new call's arguments.
    private func pin(_ entry: PinEntry, first: Bool, in project: URL, lead: String) throws -> [String] {
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
            return [entry.title.map { "\(path) was already pinned; its title is now \u{201C}\($0)\u{201D}." }
                ?? "\(path) was already pinned."]
        }
        guard file.pinCount < PinLimits.perProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.perProject) pins, pages and views together, "
                + "the most it can have. Unpin one first, or ask the person which to unpin.")
        }
        if first { file.pins.insert(entry, at: 0) } else { file.pins.append(entry) }
        try writePins(file, in: project)
        return ["Pinned \(path) under the project, in .agents/pins.json in the project folder."]
    }

    /// `pin_page` with `view` (#189): a view of the agents server, fed by a read-only tool.
    private func pinViewTool(_ arguments: JSONValue, for caller: Agent, lead: String) throws -> String {
        let project = caller.projectFolder
        guard pinText(arguments, "path") == nil else { throw pinRefusal(lead + "give `path` or `view`, not both.") }
        guard let given = arguments["view"], case .object = given else {
            throw pinRefusal(lead + "`view` is an object: server, uri, tool and arguments.")
        }
        let view = ViewPin(server: given["server"]?.stringValue ?? "", uri: given["uri"]?.stringValue ?? "",
                           tool: given["tool"]?.stringValue ?? "", arguments: given["arguments"])
        if let refusal = viewPinRefusal(view, project: project) { throw pinRefusal(lead + refusal) }
        let position = pinText(arguments, "position")
        if let position, position != "first", position != "last" {
            throw pinRefusal(lead + "`position` is first or last.")
        }
        let entry = PinEntry(view: view, title: pinText(arguments, "title"), pinnedBy: pinner(for: caller))
        let notes = try pin(entry, first: position == "first", in: project, lead: lead)
        return (notes + ["Opening it calls \(view.tool) on the \(view.server) server and draws \(view.uri).", "",
                         pinsWords(project, for: caller)]).joined(separator: "\n")
    }

    /// The numbered pins, for an agent's answer.
    func pinsWords(_ project: URL, for caller: Agent?) -> String {
        let pins = pinViews(project)
        guard !pins.isEmpty else { return "This project has no pinned pages. Pin one with pin_page." }
        let mine = caller.map { pinner(for: $0) }
        let entries = readPins(project).pins
        let lines = pins.enumerated().map { index, pin in
            let yours = entries.first { $0.path == pin.path }?.pinnedBy == mine
            let by = ", pinned by " + (yours ? "you" : pinnerWords(pin.pinnedBy))
            if let view = pin.view {
                return "\(index + 1). \(pin.title) — \(view.uri) [view of the \(view.server) server, fed by \(view.tool)]"
                    + by + (pin.missingReason.map { "; missing: \($0)" } ?? "")
            }
            return "\(index + 1). \(pin.title) — \(pin.path) [\(pin.kind.rawValue)]"
                + by + (pin.missing ? "; missing from the project folder" : "")
        }
        return (["Pinned pages (\(pins.count) of \(PinLimits.perProject)):"] + lines)
            .joined(separator: "\n")
    }

    func pinner(for agent: Agent) -> Pinner {
        if let workflow = agent.startedByWorkflow, agent.startedByAgent == nil { return .workflow(workflow) }
        return .agent(agent.id)
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

    private func pinnerWords(_ view: PinnerView) -> String {
        switch view.kind {
        case .person: "the person"
        case .agent: "the agent \u{201C}\(view.name)\u{201D}"
        case .workflow: "the workflow \u{201C}\(view.name)\u{201D}"
        }
    }

    /// A path an agent gave: relative to the project, absolute in the project folder, or
    /// absolute in its own worktree (the same relative path).
    private func agentPinPath(_ given: String, for agent: Agent) -> String? {
        guard given.hasPrefix("/") else { return PinRules.normalize(given) }
        // The worktree first: it is often inside the project's own `.agents/worktrees/`.
        if agent.worktree != nil, let inTree = PinRules.relative(given, in: agent.cwd) { return inTree }
        return PinRules.relative(given, in: agent.projectFolder)
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

    private func pinCaller(_ token: String) throws -> Agent {
        guard let id = appTokens[token], let agent = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: LeaseWords.noConversation)
        }
        return agent
    }

    private func pinText(_ arguments: JSONValue, _ key: String) -> String? {
        let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func requireFolder(_ project: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw pinRefusal("Nothing was pinned: the project folder \(project.path) is not there.")
        }
    }

    func pinRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.pinRefused, message: message)
    }
}
