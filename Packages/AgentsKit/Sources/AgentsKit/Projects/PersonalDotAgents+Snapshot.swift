import AgentsKitCore
import Foundation

/// Settings ▸ Shared's one read of `~/.agents` (054, research R13,
/// contracts/personal-shared.md). Reach comes from the rule table and what R9 measured,
/// plus what is on disk now: the links, the record, the names in each runtime's own
/// config. Nothing here holds or returns a value from `mcp.json` (FR-023).
extension PersonalDotAgents {
    typealias Snapshot = DaemonAPI.SharedSnapshot
    typealias Reach = DaemonAPI.Reach

    /// Runtimes that keep their own server of a name over the one the app sends (R9).
    static let keepsOwnServer: Set<String> = ["codex", "copilot"]
    /// Runtimes that run both copies of a clashing server (R9).
    static let runsBothServers: Set<String> = ["cursor"]
    /// Runtimes whose handshake leaves sse out (R9: Codex says `sse: false`).
    static let refusesSSE: Set<String> = ["codex"]
    /// Where each runtime keeps MCP servers of its own, relative to the home.
    static let ownServerConfigs: [String: String] = [
        "claude": ".claude.json", "codex": ".codex/config.toml", "cursor": ".cursor/mcp.json",
        "copilot": ".copilot/mcp-config.json", "gemini": ".gemini/settings.json",
    ]

    public static func snapshot(home: URL?, installed: Set<String>, record: Record,
                                appHomes: [String: URL] = [:]) -> DaemonAPI.SharedSnapshot {
        guard let home else { return Snapshot(home: "", laidOut: false) }
        let shared = home.appending(path: folder, directoryHint: .isDirectory)
        let present = rules.filter { installed.contains($0.runtimeID) }
        var snapshot = Snapshot(home: shared.path, laidOut: true)
        snapshot.runtimes = present.map {
            DaemonAPI.RuntimeName(id: $0.runtimeID, name: RuntimeCatalog.runtime(id: $0.runtimeID)?.name ?? $0.runtimeID)
        }
        var looks: [DaemonAPI.Look] = []
        snapshot.instructions = instructions(home: home, present: present, record: record, looks: &looks)
        let plugins = personalPluginFolders(home: home)
        snapshot.skills = skills(home: home, present: present, plugins: plugins, record: record, appHomes: appHomes,
                                 looks: &looks)
        snapshot.mcp = mcp(home: home, present: present, looks: &looks)
        snapshot.plugins = plugins.map { plugin(home: home, $0, present: present, record: record) }
        if !plugins.isEmpty {
            let none = present.filter { $0.pluginHandover == .none }.map(\.runtimeID)
            if !none.isEmpty {
                let who = none.count == 1 ? "It takes" : none.count == 2 ? "Neither takes" : "None of them takes"
                looks.append(.init(kind: .noWay, page: .plugins, item: names(none),
                                   text: "\(who) a plugin from the app. Their own installs still work in their own sessions."))
            }
        }
        snapshot.otherFiles = otherFiles(shared)
        snapshot.needsALook = looks
        return snapshot
    }

    private static func names(_ ids: [String]) -> String {
        ids.map { RuntimeCatalog.runtime(id: $0)?.name ?? $0 }.joined(separator: ", ")
    }

    private static func tilde(_ relative: String) -> String { "~/\(relative)" }

    /// A path under the personal home written from `~`, the way the person thinks of it.
    /// Against that home rather than the daemon's: a scratch copy has a home of its own.
    private static func tilde(_ path: String, in home: URL) -> String {
        path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
    }

    // MARK: Instructions

    private static func instructions(home: URL, present: [Rule], record: Record, looks: inout [DaemonAPI.Look]) -> DaemonAPI.Instructions {
        let url = home.appending(path: "\(folder)/\(router)")
        var reach: [String: Reach] = [:]
        for rule in present {
            guard let file = rule.instructionsFile else {
                if let why = rule.noInstructions {
                    reach[rule.runtimeID] = .noWay(why)
                    looks.append(.init(kind: .noFile, page: .instructions, item: names([rule.runtimeID]),
                                       text: "No personal instructions file. \(why)."))
                } else {
                    reach[rule.runtimeID] = .unchecked(nil)
                }
                continue
            }
            let link = home.appending(path: file)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
               resolves(destination, from: link, to: url) {
                reach[rule.runtimeID] = .gets("\(tilde(file)) → link")
            } else if DotAgents.exists(link) {
                reach[rule.runtimeID] = .ownCopy(link.path)
            } else if record.links[file] != nil {
                reach[rule.runtimeID] = .leftOut("no \(tilde(file)): its link was removed")
            } else {
                reach[rule.runtimeID] = .gets("\(tilde(file)), linked before its next agent starts")
            }
        }
        return DaemonAPI.Instructions(path: url.path, exists: DotAgents.exists(url), reach: reach)
    }

    // MARK: Skills

    private static func skills(home: URL, present: [Rule], plugins: [URL], record: Record, appHomes: [String: URL],
                               looks: inout [DaemonAPI.Look]) -> [DaemonAPI.Skill] {
        let folderURL = home.appending(path: "\(folder)/\(skills)", directoryHint: .isDirectory)
        var list: [DaemonAPI.Skill] = []
        for name in sharedSkills(home: home) {
            let url = folderURL.appending(path: name)
            var reach: [String: Reach] = [:]
            var clash: String?
            for rule in present {
                if let skillsFolder = rule.skillsFolder {
                    let link = home.appending(path: "\(skillsFolder)/\(name)")
                    if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       resolves(destination, from: link, to: url) {
                        reach[rule.runtimeID] = .gets("through a link in \(tilde(skillsFolder))")
                    } else if DotAgents.exists(link) {
                        clash = link.path
                        reach[rule.runtimeID] = .ownCopy(link.path)
                    } else if managedNames.contains(name) {
                        reach[rule.runtimeID] = .leftOut("another tool manages that name in \(tilde(skillsFolder))")
                    } else if record.links["\(skillsFolder)/\(name)"] != nil {
                        reach[rule.runtimeID] = .leftOut("its link in \(tilde(skillsFolder)) was removed")
                    } else {
                        // Not placed yet: the layout before its next agent places it.
                        reach[rule.runtimeID] = .gets("linked in \(tilde(skillsFolder)) before its next agent starts")
                    }
                } else if rule.readsSharedSkills {
                    reach[rule.runtimeID] = .gets("reads ~/.agents/skills")
                } else if let appFolder = rule.appHomeSkillsFolder, let appHome = appHomes[rule.runtimeID] {
                    let link = appHome.appending(path: "\(appFolder)/\(name)")
                    if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == url.path {
                        reach[rule.runtimeID] = .gets("through a link in the home the app gives it")
                    } else if DotAgents.exists(link) {
                        reach[rule.runtimeID] = .ownCopy(link.path)
                    } else if record.links[link.path] != nil {
                        reach[rule.runtimeID] = .leftOut("its link in the home the app gives it was removed")
                    } else {
                        reach[rule.runtimeID] = .gets("linked into the home the app gives it before its next agent starts")
                    }
                } else {
                    reach[rule.runtimeID] = .unchecked(nil)
                }
            }
            if let clash {
                let runtime = present.first { $0.skillsFolder != nil }.map { names([$0.runtimeID]) } ?? "It"
                looks.append(.init(kind: .clash, page: .skills, item: name,
                                   text: "A skill of that name is also in \(tilde(clash, in: home)) and was left there. \(runtime) gets that one."))
            }
            list.append(.init(name: name, path: url.path, description: skillDescription(url), source: .personal,
                              clash: clash, reach: reach))
        }
        for plugin in plugins {
            let pluginName = DotAgents.pluginManifest(of: plugin)["name"] as? String ?? plugin.lastPathComponent
            let reach = pluginReach(home: home, plugin, present: present, record: record)
            let skillsURL = plugin.appending(path: skills, directoryHint: .isDirectory)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: skillsURL.path)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") && DotAgents.isDirectory(skillsURL.appending(path: name)) {
                let url = skillsURL.appending(path: name)
                list.append(.init(name: name, path: url.path, description: skillDescription(url),
                                  source: .plugin(pluginName), clash: nil, reach: reach))
            }
        }
        return list
    }

    /// The `description:` line of a skill's front matter.
    static func skillDescription(_ skill: URL) -> String? {
        guard let text = try? String(contentsOf: skill.appending(path: "SKILL.md"), encoding: .utf8),
              text.hasPrefix("---") else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("---") { break }
            if line.hasPrefix("description:") {
                let value = line.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    // MARK: MCP servers

    private static func mcp(home: URL, present: [Rule], looks: inout [DaemonAPI.Look]) -> DaemonAPI.MCP {
        var result = DaemonAPI.MCP(file: mcpURL(home: home).path)
        let own = Dictionary(uniqueKeysWithValues: present.map { ($0.runtimeID, ownServerNames(home: home, runtimeID: $0.runtimeID)) })
        let mine: [MCPServer]
        switch personalServers(home: home) {
        case .success(let servers): mine = servers
        case .failure(let problem):
            mine = []
            result.problem = .init(message: problem.message, line: problem.line)
            looks.append(.init(kind: .problem, page: .mcp, item: mcpFile,
                               text: problem.message + (problem.line.map { " Line \($0)." } ?? "")
                                   + " Agents start without your servers until it is fixed."))
        }
        let appName = "agents"
        result.app = [DaemonAPI.Server(name: appName, transport: "stdio", summary: "finish_turn, show_file and the rest",
                                       reach: Dictionary(uniqueKeysWithValues: present.map { rule in
                                           (rule.runtimeID, rule.takesStdioServers ? Reach.gets("sent at start")
                                                                                   : .gets("through the bridge"))
                                       }))]
        var seen: Set<String> = [appName]
        var sseLeftOut: [String: [String]] = [:]
        let secretFile = SecretsEnv.load(from: SecretsEnv.url(home: home))
        for server in mine {
            var reach: [String: Reach] = [:]
            var clash: [String: String] = [:]
            let taken = !seen.insert(server.name).inserted
            for rule in present {
                let id = rule.runtimeID
                let ownFile = own[id]?.contains(server.name) == true ? ownServerConfigs[id].map { home.appending(path: $0).path } : nil
                if let ownFile { clash[id] = ownFile }
                if taken {
                    reach[id] = .leftOut(server.name == appName ? "the app's own agents server has the name"
                                                                : "an earlier server has the name")
                } else if id == "gemini" {
                    reach[id] = .unchecked(nil)
                } else if case .sse = server.transport, refusesSSE.contains(id) {
                    reach[id] = .leftOut("\(names([id])) takes no sse servers")
                    sseLeftOut[id, default: []].append(server.name)
                } else if let ownFile, keepsOwnServer.contains(id) {
                    reach[id] = .ownCopy(ownFile)
                } else if ownFile != nil, runsBothServers.contains(id) {
                    reach[id] = .gets("sent at start; its own copy runs too")
                } else if case .stdio = server.transport, !rule.takesStdioServers {
                    reach[id] = .gets("through the bridge")
                } else {
                    reach[id] = .gets("sent at start")
                }
            }
            for (id, file) in clash.sorted(by: { $0.key < $1.key }) {
                let what: String
                if keepsOwnServer.contains(id) { what = "\(names([id])) uses its own copy." }
                else if runsBothServers.contains(id) { what = "\(names([id])) runs both." }
                else { what = "\(names([id])) uses the one from mcp.json." }
                looks.append(.init(kind: .clash, page: .mcp, item: server.name,
                                   text: "Also in \(tilde(file, in: home)). \(what)"))
            }
            let missing = Self.unsetSecretNames(in: server, secrets: secretFile)
            if !missing.isEmpty {
                let why = "\(missing.joined(separator: ", ")) \(missing.count == 1 ? "isn't" : "aren't") set"
                for rule in present { reach[rule.runtimeID] = .leftOut(why) }
                looks.append(.init(kind: .leftOut, page: .mcp, item: server.name,
                                   text: "\(why), so agents start without \(server.name)."))
            }
            result.servers.append(serverRow(server, clash: clash, reach: reach))
        }
        for (id, left) in sseLeftOut.sorted(by: { $0.key < $1.key }) {
            looks.append(.init(kind: .leftOut, page: .mcp, item: names([id]),
                               text: "Takes no sse servers from the app: \(left.joined(separator: " and ")) \(left.count == 1 ? "doesn't" : "don't") reach it."))
        }
        let personalNames = Set(mine.map(\.name))
        for rule in present {
            guard let file = ownServerConfigs[rule.runtimeID] else { continue }
            for name in ownServerNames(home: home, runtimeID: rule.runtimeID) where !personalNames.contains(name) {
                result.runtimeOnly.append(.init(name: name, runtimeID: rule.runtimeID, file: home.appending(path: file).path))
            }
        }
        return result
    }

    /// `${NAME}` in the entry that `secrets.env` does not have. Names only.
    private static func unsetSecretNames(in server: MCPServer, secrets: SecretsEnv) -> [String] {
        var seen = Set<String>()
        return SecretsEnv.referencedNames(in: server).filter { secrets.value(of: $0) == nil && seen.insert($0).inserted }
    }

    private static func serverRow(_ server: MCPServer, clash: [String: String], reach: [String: Reach]) -> DaemonAPI.Server {
        switch server.transport {
        case .stdio(let command, let args, let env):
            let shown = ([command] + args.prefix(3).map(maskedArgument)).joined(separator: " ")
            return .init(name: server.name, transport: "stdio", summary: shown, envNames: env.keys.sorted(),
                         clash: clash, reach: reach)
        case .http(let url, let headers), .sse(let url, let headers):
            let transport = if case .sse = server.transport { "sse" } else { "http" }
            return .init(name: server.name, transport: transport, summary: bareURL(url),
                         headerNames: headers.keys.sorted(), clash: clash, reach: reach)
        }
    }

    /// An argument shown as it is, unless it looks like it carries a secret.
    static func maskedArgument(_ argument: String) -> String {
        let lowered = argument.lowercased()
        let named = ["token", "key", "secret", "password", "auth"].contains { lowered.contains($0) } && argument.contains("=")
        let long = argument.count > 40 && !argument.contains("/")
        return named || long ? "••••" : argument
    }

    /// A URL without its query, fragment, or anything before an `@`.
    static func bareURL(_ url: String) -> String {
        guard var parts = URLComponents(string: url) else { return "••••" }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.string ?? "••••"
    }

    /// The names, and only the names, of the servers a runtime keeps in its own config.
    static func ownServerNames(home: URL, runtimeID: String) -> [String] {
        guard let file = ownServerConfigs[runtimeID] else { return [] }
        let url = home.appending(path: file)
        if runtimeID == "codex" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            // `[mcp_servers.<name>]`, a line match rather than a TOML parser (R13).
            return text.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("[mcp_servers."), trimmed.hasSuffix("]") else { return nil }
                let name = trimmed.dropFirst("[mcp_servers.".count).dropLast()
                guard !name.contains(".") else { return nil }
                return String(name).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }.uniqued()
        }
        return (DotAgents.json(at: url)?["mcpServers"] as? [String: Any])?.keys.sorted() ?? []
    }

    // MARK: Plugins

    private static func plugin(home: URL, _ url: URL, present: [Rule], record: Record) -> DaemonAPI.Plugin {
        let info = pluginInfo(url)
        let contents = DaemonAPI.Plugin.Contents(skills: info.contents.skills, commands: info.contents.commands,
                                                 agents: info.contents.agents, hooks: info.contents.hooks,
                                                 mcpServers: info.contents.mcpServers)
        return DaemonAPI.Plugin(name: info.name, version: info.version, description: info.description, path: info.path,
                                contents: contents, files: files(in: url), serverNames: pluginServers(url).map(\.name),
                                reach: pluginReach(home: home, url, present: present, record: record))
    }

    private static func pluginReach(home: URL, _ plugin: URL, present: [Rule], record: Record) -> [String: Reach] {
        let name = DotAgents.pluginManifest(of: plugin)["name"] as? String ?? plugin.lastPathComponent
        var reach: [String: Reach] = [:]
        for rule in present {
            switch rule.pluginHandover {
            case .sessionMeta:
                reach[rule.runtimeID] = .gets("handed at start")
            case .sessionMetaWithServers:
                reach[rule.runtimeID] = .gets("handed at start; its servers go out with your MCP servers")
            case .codexMarketplace:
                if record.codexPlugins[name] == fingerprint(plugin) {
                    let when = record.codexAddedAt?[name].map { ", " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                    reach[rule.runtimeID] = .gets("added to Codex\(when), a copy: added again when it changes")
                } else {
                    reach[rule.runtimeID] = .leftOut("not added to Codex yet: the next Codex agent adds it")
                }
            case .extensionLink:
                let link = "\(geminiExtensions)/\(plugin.lastPathComponent)"
                reach[rule.runtimeID] = .unchecked(DotAgents.exists(home.appending(path: link))
                                                   ? "link in ~/\(geminiExtensions), not checked yet" : nil)
            case .none:
                reach[rule.runtimeID] = rule.runtimeID == "copilot"
                    ? .noWay("not in agents the app starts (its own CLI has it)")
                    : .noWay("no way in from the app")
            }
        }
        return reach
    }

    /// A plugin's files, relative to it, for the detail's tree: at most 40.
    private static func files(in plugin: URL) -> [String] {
        let root = plugin.resolvingSymlinksInPath()
        var found: [String] = []
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in walker {
            if url.lastPathComponent == ".git" { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  url.lastPathComponent != ".DS_Store" else { continue }
            found.append(String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)))
            if found.count >= 40 { break }
        }
        return found.sorted()
    }

    // MARK: Other files

    /// Everything in `~/.agents` the other pages do not cover.
    private static func otherFiles(_ shared: URL) -> [DaemonAPI.OtherFile] {
        let covered: Set<String> = [router, skills, plugins, mcpFile, ".DS_Store"]
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: shared.path)) ?? []).sorted()
        var files: [DaemonAPI.OtherFile] = []
        for name in entries where !covered.contains(name) {
            switch name {
            case personas:
                let inside = ((try? FileManager.default.contentsOfDirectory(atPath: shared.appending(path: name).path)) ?? [])
                    .filter { !$0.hasPrefix(".") }.sorted()
                files += inside.map { .init(path: "\(personas)/\($0)", kind: .persona) }
            case ".git":
                files.append(.init(path: name, kind: .git))
            case ".skill-lock.json":
                files.append(.init(path: name, kind: .managed))
            default:
                files.append(.init(path: name, kind: .unused))
            }
        }
        return files
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
