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
        PersonalDotAgents.reconcile(home: home, installed: installedRuntimeIDs(), record: &record, appHomes: appHomes())
        guard record != before else { return }
        PersonalDotAgents.attempt("save \(locations.personalLayout.lastPathComponent)") {
            try record.save(to: locations.personalLayout)
        }
    }

    /// Before a Gemini session: the project's plugins linked in as extensions switched on
    /// only in that project, since Gemini has no project folder for them. Like the rest of
    /// the home, nothing on a scratch root with no personal home.
    func linkGeminiProjectPlugins(runtimeID: String, cwd: URL) {
        guard PersonalDotAgents.rule(for: runtimeID)?.pluginHandover == .extensionLink,
              let home = locations.personalHome else { return }
        var record = PersonalDotAgents.Record.load(from: locations.personalLayout, home: home)
        let before = record
        PersonalDotAgents.linkGeminiProjectExtensions(home: home, cwd: cwd, record: &record)
        guard record != before else { return }
        PersonalDotAgents.attempt("save \(locations.personalLayout.lastPathComponent)") {
            try record.save(to: locations.personalLayout)
        }
    }

    /// The homes the app gives runtimes of its own, from their launch environment's
    /// `<root>` value (Antigravity's `GEMINI_HOME`, 049's D7).
    func appHomes() -> [String: URL] {
        var homes: [String: URL] = [:]
        for launch in RuntimeLaunchCatalog.builtIn {
            guard let value = launch.environment.values.compactMap({ $0 }).first(where: { $0.hasPrefix("<root>") })
            else { continue }
            homes[launch.runtimeID] = URL(filePath: value.replacingOccurrences(of: "<root>", with: locations.root.path))
        }
        return homes
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

/// Codex's copy of the person's plugins (054, R12). Codex loads a plugin only once it is
/// added from a marketplace, and adding copies it, so the app adds it again whenever the
/// plugin's folder changes and removes it once it is gone. Codex's own command does the
/// writing; nothing of Codex's is written here.
extension DaemonCore {
    /// At daemon start, and before a Codex session only. A second caller while a pass is
    /// running waits for that one.
    func syncCodexPlugins(before runtimeID: String? = nil) async {
        if let runtimeID, PersonalDotAgents.rule(for: runtimeID)?.pluginHandover != .codexMarketplace { return }
        guard let home = locations.personalHome, installedRuntimeIDs().contains("codex") else { return }
        if let running = codexPluginSync {
            await running.value
            return
        }
        let pass = Task { await self.codexPluginPass(home: home) }
        codexPluginSync = pass
        await pass.value
        codexPluginSync = nil
    }

    private func codexPluginPass(home: URL) async {
        let found = PersonalDotAgents.personalPluginFolders(home: home)
        guard PersonalDotAgents.writeCodexIndex(home: home, plugins: found) else {
            DaemonLog.shared.write("personal plugins: ~/.agents/plugins/marketplace.json is the person's own, so Codex is left to it")
            return
        }
        let changes = PersonalDotAgents.codexChanges(home: home, record: .load(from: locations.personalLayout, home: home))
        guard !changes.add.isEmpty || !changes.remove.isEmpty else { return }
        guard let codex = codexCLI() else {
            DaemonLog.shared.write("personal plugins: no codex to add them with")
            return
        }
        let marketplace = PersonalDotAgents.codexMarketplace
        for (name, print) in changes.add {
            let status = await Self.run(codex, ["plugin", "add", "\(name)@\(marketplace)"], home: home)
            DaemonLog.shared.write("personal plugins: codex plugin add \(name): " + (status == 0 ? "added" : "failed (\(status))"))
            guard status == 0 else { continue }
            updateRecord(home: home) {
                $0.codexPlugins[name] = print
                $0.codexAddedAt = ($0.codexAddedAt ?? [:]).merging([name: Date()]) { $1 }
            }
        }
        for name in changes.remove {
            let status = await Self.run(codex, ["plugin", "remove", "\(name)@\(marketplace)"], home: home)
            DaemonLog.shared.write("personal plugins: codex plugin remove \(name): " + (status == 0 ? "removed" : "failed (\(status))"))
            guard status == 0 else { continue }
            updateRecord(home: home) {
                $0.codexPlugins.removeValue(forKey: name)
                $0.codexAddedAt?.removeValue(forKey: name)
            }
        }
    }

    private func updateRecord(home: URL, _ change: (inout PersonalDotAgents.Record) -> Void) {
        var record = PersonalDotAgents.Record.load(from: locations.personalLayout, home: home)
        change(&record)
        PersonalDotAgents.attempt("save \(locations.personalLayout.lastPathComponent)") {
            try record.save(to: locations.personalLayout)
        }
    }

    /// Run `codex` from here instead of the toolset: a test's stand-in.
    func useCodexCLI(_ url: URL?) { codexCLIOverride = url }

    /// The toolset's own `codex`, the one the app's Codex agents run (047).
    func codexCLI() -> URL? {
        if let codexCLIOverride { return codexCLIOverride }
        guard let runtime = RuntimeCatalog.runtime(id: "codex"),
              let shim = discovery.appToolset(for: runtime) else { return nil }
        let current = URL(filePath: shim).deletingLastPathComponent().deletingLastPathComponent()
        let openai = current.appending(path: "lib/node_modules/@openai")
        let fileManager = FileManager.default
        for package in ((try? fileManager.contentsOfDirectory(atPath: openai.path)) ?? []).sorted()
        where package.hasPrefix("codex-") {
            let vendor = openai.appending(path: "\(package)/vendor")
            for triple in (try? fileManager.contentsOfDirectory(atPath: vendor.path)) ?? [] {
                let binary = vendor.appending(path: "\(triple)/bin/codex")
                if fileManager.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }

    /// Run a command to its end off the actor, with `HOME` as the person's home, and give
    /// back its exit status (-1 when it could not start). Its output is not kept.
    static func run(_ executable: URL, _ arguments: [String], home: URL) async -> Int32 {
        await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["HOME"] = home.path
            process.environment = environment
            process.currentDirectoryURL = home
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                done.resume(returning: -1)
            }
        }
    }
}

extension DaemonCore {
    /// Settings ▸ Shared's read of `~/.agents` (054, R13). A window's only: a phone or a
    /// helper is refused before it gets here, by its role.
    func sharedSnapshot() -> DaemonAPI.SharedSnapshot {
        guard let home = locations.personalHome else { return PersonalDotAgents.snapshot(home: nil, installed: [], record: .init(home: "")) }
        return PersonalDotAgents.snapshot(home: home, installed: installedRuntimeIDs(),
                                          record: .load(from: locations.personalLayout, home: home),
                                          appHomes: appHomes())
    }
}
