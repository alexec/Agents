import Foundation
import AgentsKitCore

/// A project's pinned pages (#159): the agents' `pin_page`, `unpin_page` and `move_pin`,
/// the person's Pin, Unpin and drag, and the pages themselves, read for every screen.
///
/// The pins are one file in the project folder, `.agents/pins.json`, written whole and
/// only here, inside the actor, never in a worktree; nothing is committed. As the
/// Dashboard's tiles are (074).
extension DaemonCore {
    // MARK: Agents' tools

    /// `pin_page`: pin a Markdown or HTML file in the caller's project, or retitle one.
    public func pinPage(_ request: DaemonAPI.PinToolRequest) throws -> String {
        let caller = try pinCaller(request.token)
        let project = caller.projectFolder
        try requireFolder(project)
        let lead = "Nothing was pinned: "
        let arguments = request.arguments
        guard let given = pinText(arguments, "path") else { throw pinRefusal(lead + "say which file, in `path`.") }
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
        let notes = try pin(path, title: title, first: position == "first", by: pinner(for: caller), in: project, lead: lead)
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
        var file = readPins(project)
        guard let path = agentPinPath(given, for: caller), let index = file.pins.firstIndex(where: { $0.path == path }) else {
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
        var file = readPins(project)
        let paths = file.pins.map(\.path)
        guard let path = agentPinPath(given, for: caller), paths.contains(path) else {
            throw pinRefusal(lead + "\(given) is not pinned in this project.")
        }
        let rawBefore = pinText(arguments, "before"), rawAfter = pinText(arguments, "after")
        let position = pinText(arguments, "position")
        guard [rawBefore, rawAfter, position].compactMap({ $0 }).count == 1 else {
            throw pinRefusal(lead + "give one of `before`, `after` or `position`.")
        }
        func pinned(_ other: String) throws -> String {
            guard let found = agentPinPath(other, for: caller), paths.contains(found) else {
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
            return pins.isEmpty ? nil : ProjectPins(folder: folder, pins: pins)
        }
    }

    /// Pin to Project, from any client.
    public func pinByPerson(_ request: DaemonAPI.PinRequest) throws -> [PinView] {
        let project = try knownPinProject(request.folder)
        let lead = "Nothing was pinned: "
        guard let path = personPinPath(request.path, in: project) else {
            throw pinRefusal(lead + "\(request.path) is not in this project.")
        }
        guard pinFileExists(path, in: project) else {
            throw pinRefusal(lead + "there is no file at \(path) in the project folder.")
        }
        _ = try pin(path, title: request.title, first: false, by: .thePerson, in: project, lead: lead)
        return pinViews(project)
    }

    /// Unpin, from any client: any pin.
    public func unpinByPerson(_ request: DaemonAPI.PinPathRequest) throws {
        let project = try knownPinProject(request.folder)
        var file = readPins(project)
        let path = personPinPath(request.path, in: project) ?? request.path
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
        var file = readPins(project)
        var placed: [PinEntry] = []
        for path in request.paths {
            if let entry = file.pins.first(where: { $0.path == path }), !placed.contains(entry) { placed.append(entry) }
        }
        file.pins = placed + file.pins.filter { !placed.contains($0) }
        try writePins(file, in: project)
    }

    /// Any file in the project folder, for a pinned page, a page tile or what an HTML
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

    // MARK: Changes

    /// Something changed under a project: its pins file, a pinned page or one beside it.
    /// Called from the project's own watch, which sees the whole folder.
    func pinFilesChanged(_ changed: [URL], in project: URL) {
        let base = project.standardizedFileURL.path(percentEncoded: false)
        let root = base.hasSuffix("/") ? base : base + "/"
        // Folders inside the project, relative to it, worktrees and git's own left out.
        let folders = Set(changed.compactMap { url -> String? in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            if path == base || path + "/" == root { return "" }
            guard path.hasPrefix(root) else { return nil }
            let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if relative.hasPrefix(".agents/worktrees") || relative == ".git" || relative.hasPrefix(".git/") { return nil }
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

    /// Every pinned page and every page tile's file: what a screen may be showing.
    func pagePaths(_ project: URL) -> [String] {
        let tiles = dashboardStore.readTiles(project).compactMap { $0.tile?.page?.file }.compactMap(PinRules.normalize)
        return readPins(project).pins.map(\.path) + tiles
    }

    /// Tell every screen, at most once a second per project.
    func pinsChanged(_ project: URL) {
        guard pinBroadcasts[project] == nil else { return }
        pinBroadcasts[project] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.dashboardBroadcastGap))
            await self?.sendPinsChanged(project)
        }
    }

    private func sendPinsChanged(_ project: URL) {
        pinBroadcasts[project] = nil
        let pins = pinViews(project)
        pinsSent[project] = pins
        broadcast(DaemonAPI.Notification.pinsChanged, DaemonAPI.PinsChangedNotification(folder: project, pins: pins))
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
            guard let kind = PinRules.kind(entry.path) else { return nil }
            return PinView(path: entry.path, title: entry.title ?? PinRules.defaultTitle(entry.path), kind: kind,
                           missing: !pinFileExists(entry.path, in: project),
                           pinnedBy: pinnerView(entry.pinnedBy, in: project))
        }
    }

    static func pinsFileURL(_ project: URL) -> URL {
        project.appending(path: PinsFile.path)
    }

    func readPins(_ project: URL) -> PinsFile {
        guard let data = try? Data(contentsOf: Self.pinsFileURL(project)),
              let read = try? PinsFile.read(data) else { return PinsFile() }
        return read.file
    }

    func writePins(_ file: PinsFile, in project: URL) throws {
        let url = Self.pinsFileURL(project)
        do {
            if file.pins.isEmpty {
                if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: url)
                }
            } else {
                let data = try file.fileData()
                if (try? Data(contentsOf: url)) != data {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                }
            }
        } catch {
            throw pinRefusal("The pins could not be written in \(project.path)/.agents: \(error.localizedDescription)")
        }
        pinsChanged(project)
    }

    /// Pin or retitle, under the limit. Returns what to say.
    private func pin(_ path: String, title: String?, first: Bool, by who: Pinner, in project: URL,
                     lead: String) throws -> [String] {
        guard PinRules.kind(path) != nil else {
            throw pinRefusal(lead + "only a Markdown (.md) or HTML (.html) page can be pinned.")
        }
        if let title, title.count > PinLimits.titleLength {
            throw pinRefusal(lead + "`title` is at most \(PinLimits.titleLength) characters.")
        }
        var file = readPins(project)
        if let index = file.pins.firstIndex(where: { $0.path == path }) {
            if let title { file.pins[index].title = title }
            try writePins(file, in: project)
            return [title == nil ? "\(path) was already pinned." : "\(path) was already pinned; its title is now \u{201C}\(title!)\u{201D}."]
        }
        guard file.pins.count < PinLimits.perProject else {
            throw pinRefusal(lead + "this project already has \(PinLimits.perProject) pinned pages, the most it can have. "
                + "Unpin one first, or ask the person which to unpin.")
        }
        let entry = PinEntry(path: path, title: title, pinnedBy: who)
        if first { file.pins.insert(entry, at: 0) } else { file.pins.append(entry) }
        try writePins(file, in: project)
        return ["Pinned \(path) under the project, in .agents/pins.json in the project folder."]
    }

    /// The numbered pins, for an agent's answer and `read_dashboard`.
    func pinsWords(_ project: URL, for caller: Agent?) -> String {
        let pins = pinViews(project)
        guard !pins.isEmpty else { return "This project has no pinned pages. Pin one with pin_page." }
        let mine = caller.map { pinner(for: $0) }
        let entries = readPins(project).pins
        let lines = pins.enumerated().map { index, pin in
            let yours = entries.first { $0.path == pin.path }?.pinnedBy == mine
            return "\(index + 1). \(pin.title) — \(pin.path) [\(pin.kind.rawValue)], pinned by "
                + (yours ? "you" : pinnerWords(pin.pinnedBy)) + (pin.missing ? "; missing from the project folder" : "")
        }
        return (["Pinned pages (\(pins.count) of \(PinLimits.perProject)), after the Dashboard:"] + lines)
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
            let name = agents[id]?.title ?? retired[id]?.title ?? "an agent not on this host"
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
        guard allProjects(includeArchived: true).contains(where: { Project.standardize($0.folder) == project }) else {
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

    func pinRefusal(_ message: String) -> JSONRPCError {
        JSONRPCError(code: DaemonAPI.Failure.pinRefused, message: message)
    }
}
