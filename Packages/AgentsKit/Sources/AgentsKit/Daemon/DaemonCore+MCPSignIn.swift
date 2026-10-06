#if canImport(CryptoKit)
import AgentsKitCore
import Foundation

/// Signing in to a person's MCP server (#306). The daemon is the OAuth client: it finds
/// where to sign in, registers itself or uses the person's own client, makes the PKCE pair,
/// listens for the browser on loopback, exchanges the code and keeps the grant in
/// `~/.agents/mcp-sign-ins.json`. The window only opens the page and waits.
///
/// Logged: the server's name and what happened in a word. Never an address, a code, a
/// client secret or a token.
extension DaemonCore {

    /// One sign-in under way: waited on by the window, a long poll at a time.
    final class MCPSignInFlow: @unchecked Sendable {
        let id = UUID()
        let name: String
        let server: String
        private let lock = NSLock()
        private var status: DaemonAPI.MCPSignInStatus?
        private var waiters: [UUID: CheckedContinuation<DaemonAPI.MCPSignInStatus, Never>] = [:]
        private(set) var cancelled = false
        var stop: @Sendable () -> Void = {}

        init(name: String, server: String) {
            self.name = name
            self.server = server
        }

        func complete(_ status: DaemonAPI.MCPSignInStatus) {
            let waiting = lock.withLock { () -> [CheckedContinuation<DaemonAPI.MCPSignInStatus, Never>] in
                guard self.status == nil else { return [] }
                self.status = status
                defer { waiters = [:] }
                return Array(waiters.values)
            }
            for waiter in waiting { waiter.resume(returning: status) }
        }

        func cancel() {
            lock.withLock { cancelled = true }
            stop()
            complete(.cancelled)
        }

        /// The outcome, or `waiting` once `limit` passes without one.
        func wait(upTo limit: Duration) async -> DaemonAPI.MCPSignInStatus {
            let key = UUID()
            return await withCheckedContinuation { done in
                let ready = lock.withLock { () -> DaemonAPI.MCPSignInStatus? in
                    if let status { return status }
                    waiters[key] = done
                    return nil
                }
                if let ready { return done.resume(returning: ready) }
                Task {
                    try? await Task.sleep(for: limit)
                    let waiter = self.lock.withLock { self.waiters.removeValue(forKey: key) }
                    waiter?.resume(returning: .waiting)
                }
            }
        }
    }

    /// How long a sign-in waits for the browser before it gives up.
    static let mcpSignInLifetime: Duration = .seconds(600)

    // MARK: Methods

    func mcpSignIn(_ request: DaemonAPI.MCPSignInRequest) async -> DaemonAPI.MCPSignInAnswer {
        let name = request.target.name
        #if canImport(Network) && canImport(Security)
        let server: (url: String, headers: [String: String])
        do {
            server = try mcpSignInServer(request.target)
        } catch {
            DaemonLog.shared.write("mcp sign-in: \(name) refused")
            return .init(error: Self.mcpSignInWords(error))
        }
        if MCPSignIns.bringsOwnAuthorization(server.headers) {
            return .init(error: "\(name) is sent an Authorization header of its own, so the app doesn't sign in to it. "
                         + "Take the header out of its entry to sign in instead.")
        }
        // A sign-in already under way for this server is replaced by this one.
        for (id, flow) in mcpSignInFlows where flow.server == server.url {
            flow.cancel()
            mcpSignInFlows[id] = nil
        }

        let signIns = mcpSignIns
        let http = await signIns.httpSend
        let plan: MCPOAuth.Plan
        let client: MCPOAuth.Client?
        var personsOwn: MCPOAuth.Client?
        do {
            var metadata = await signIns.resourceMetadata(server: server.url)
            if metadata == nil {
                // Ask the server itself: its 401 says where its metadata is.
                let probe = MCPClient(server: MCPServer(name: name, transport: .http(url: server.url, headers: server.headers)),
                                      cwd: locations.personalHome ?? locations.root, timeout: .seconds(15), http: http)
                do {
                    try await probe.connect()
                } catch MCPClient.Failure.authRequired(let named) {
                    metadata = named
                } catch {}
                await probe.end()
            }
            plan = try await MCPOAuth.discover(server: server.url, resourceMetadata: metadata, http: http)
            if let given = request.client, !given.id.trimmingCharacters(in: .whitespaces).isEmpty {
                let secret = given.secret?.trimmingCharacters(in: .whitespacesAndNewlines)
                let kept = MCPOAuth.Client(id: given.id.trimmingCharacters(in: .whitespaces),
                                           secret: secret?.isEmpty == false ? secret : nil, authMethod: nil)
                // Kept once it has signed in, so a mistyped one is asked for again.
                personsOwn = kept
                client = kept
            } else if let kept = await signIns.client(issuer: plan.server.issuer) {
                client = kept
            } else if plan.server.registrationEndpoint != nil {
                client = nil
            } else {
                DaemonLog.shared.write("mcp sign-in: \(name) needs a client of the person's own")
                return .init(needsClient: plan.server.issuer, callback: "http://127.0.0.1/callback")
            }
        } catch {
            DaemonLog.shared.write("mcp sign-in: \(name) could not start (\(Self.mcpSignInLogWord(error)))")
            return .init(error: Self.mcpSignInWords(error))
        }

        let state = MCPOAuth.randomToken()
        let verifier = MCPOAuth.randomToken()
        let redirect = MCPLoopbackRedirect(state: state)
        let registered: MCPOAuth.Client
        let address: URL
        do {
            try await redirect.start()
            if let client {
                registered = client
            } else {
                registered = try await MCPOAuth.register(at: plan.server.registrationEndpoint ?? "",
                                                         redirect: redirect.redirect, http: http)
            }
            guard let url = MCPOAuth.authorizationURL(plan, client: registered, redirect: redirect.redirect,
                                                      state: state, challenge: MCPOAuth.challenge(verifier)) else {
                throw MCPOAuth.Failure.malformed
            }
            address = url
        } catch {
            redirect.stop()
            DaemonLog.shared.write("mcp sign-in: \(name) could not start (\(Self.mcpSignInLogWord(error)))")
            return .init(error: Self.mcpSignInWords(error))
        }

        let flow = MCPSignInFlow(name: name, server: server.url)
        flow.stop = { redirect.stop() }
        mcpSignInFlows[flow.id] = flow
        let lifetime = Self.mcpSignInLifetime
        Task {
            try? await Task.sleep(for: lifetime)
            redirect.stop()
        }
        Task {
            let status = await Self.finishSignIn(flow: flow, redirect: redirect, plan: plan, client: registered,
                                                 verifier: verifier, signIns: signIns, given: personsOwn, http: http)
            flow.complete(status)
        }
        DaemonLog.shared.write("mcp sign-in: \(name) waiting for the browser")
        return .init(flowID: flow.id, authorizationURL: address.absoluteString)
        #else
        return .init(error: "Signing in to \(name) runs on a Mac's own host for now.")
        #endif
    }

    #if canImport(Network) && canImport(Security)
    /// The browser's return, the code exchanged, the grant kept, and a page to say so.
    private static func finishSignIn(flow: MCPSignInFlow, redirect: MCPLoopbackRedirect, plan: MCPOAuth.Plan,
                                     client: MCPOAuth.Client, verifier: String, signIns: MCPSignIns,
                                     given: MCPOAuth.Client?, http: @escaping MCPClient.HTTPSend) async -> DaemonAPI.MCPSignInStatus {
        let name = flow.name
        guard let callback = await redirect.callback() else {
            if flow.cancelled { return .cancelled }
            DaemonLog.shared.write("mcp sign-in: \(name) not finished in time")
            return .failed("The sign-in wasn't finished in time. Start it again.")
        }
        func fail(_ failure: MCPOAuth.Failure) -> DaemonAPI.MCPSignInStatus {
            redirect.finish(title: "Sign-in didn't finish", body: failure.sentence + " You can close this tab.")
            DaemonLog.shared.write("mcp sign-in: \(name) failed (\(failure.logWord))")
            return .failed(failure.sentence)
        }
        if let error = callback.query["error"] {
            if error == "access_denied" {
                redirect.finish(title: "Sign-in cancelled", body: "Nothing was kept. You can close this tab.")
                DaemonLog.shared.write("mcp sign-in: \(name) declined in the browser")
                return .failed("The sign-in was declined in the browser.")
            }
            return fail(.refused(String((callback.query["error_description"] ?? error).prefix(200))))
        }
        // RFC 9207: an `iss` that is not the issuer asked is a mix-up.
        if let issuer = callback.query["iss"], issuer != plan.server.issuer { return fail(.refused("It came back from another server.")) }
        guard let code = callback.query["code"], !code.isEmpty else { return fail(.malformed) }
        do {
            let tokens = try await MCPOAuth.exchange(code: code, verifier: verifier, redirect: redirect.redirect,
                                                     client: client, plan: plan, http: http)
            try await signIns.keep(server: flow.server, name: name, plan: plan, client: client, tokens: tokens)
            if let given { try await signIns.keepClient(given, issuer: plan.server.issuer) }
            redirect.finish(title: "Signed in to \(name)",
                            body: "The next agent you start has it. You can close this tab and go back to Agents.")
            return .signedIn
        } catch let failure as MCPOAuth.Failure {
            return fail(failure)
        } catch {
            redirect.finish(title: "Sign-in didn't finish", body: "The sign-in couldn't be kept. You can close this tab.")
            DaemonLog.shared.write("mcp sign-in: \(name) could not be kept")
            return .failed("The sign-in couldn't be kept: \(MCPSignInFile.fileName) could not be read or written.")
        }
    }
    #endif

    func mcpSignInWait(_ request: DaemonAPI.MCPSignInFlowRequest) async -> DaemonAPI.MCPSignInWaitAnswer {
        guard let flow = mcpSignInFlows[request.flowID] else {
            return .init(status: .failed("That sign-in has ended. Start it again."))
        }
        let status = await flow.wait(upTo: mcpSignInWaitLimit)
        if status != .waiting { mcpSignInFlows[request.flowID] = nil }
        return .init(status: status)
    }

    func mcpSignInCancel(_ request: DaemonAPI.MCPSignInFlowRequest) -> DaemonAPI.MCPSignInWaitAnswer {
        guard let flow = mcpSignInFlows.removeValue(forKey: request.flowID) else { return .init(status: .cancelled) }
        flow.cancel()
        DaemonLog.shared.write("mcp sign-in: \(flow.name) cancelled")
        return .init(status: .cancelled)
    }

    func mcpSignOut(_ request: DaemonAPI.MCPSignOutRequest) async -> DaemonAPI.MCPSignOutAnswer {
        do {
            let server = try mcpSignInServer(request.target)
            try await mcpSignIns.signOut(server: server.url, name: request.target.name)
            return .init()
        } catch {
            DaemonLog.shared.write("mcp sign-in: \(request.target.name) sign-out refused")
            return .init(error: Self.mcpSignInWords(error))
        }
    }

    /// For a test: the sign-ins' http through a stand-in, a clock, and a short long poll.
    func setMCPSignIn(http: MCPClient.HTTPSend?, now: (@Sendable () -> Date)? = nil, waitLimit: Duration? = nil,
                      log: (@Sendable (String) -> Void)? = nil) {
        mcpSignIns = MCPSignIns(home: locations.personalHome, http: http,
                                log: log ?? { DaemonLog.shared.write($0) }, now: now ?? { Date() })
        if let waitLimit { mcpSignInWaitLimit = waitLimit }
    }

    // MARK: Which server

    /// A server to sign in to, its secrets filled: an http one, in the destination's
    /// `mcp.json` or typed on the sheet.
    func mcpSignInServer(_ target: DaemonAPI.MCPSignInTarget) throws -> (url: String, headers: [String: String]) {
        switch target {
        case .url(_, let url):
            guard MCPOAuth.canonical(url) != nil else {
                throw DaemonAPI.MCPCatalogError.invalid("That is not an http or https address.")
            }
            return (url, [:])
        case .entry(let destination, let name):
            try requireMCPProject(destination)
            guard let home = locations.personalHome else { throw DaemonAPI.MCPCatalogError.noPersonalHome }
            let file = try mcpInstaller.mcpURL(destination, personalHome: home)
            guard case .success(let servers) = PersonalDotAgents.servers(at: file) else {
                throw DaemonAPI.MCPCatalogError.mcpUnreadable(path: file.path)
            }
            guard let server = servers.first(where: { $0.name == name }) else {
                throw DaemonAPI.MCPCatalogError.invalid("There is no server called \(name) there any more.")
            }
            guard let filled = SecretsEnv.load(from: SecretsEnv.url(home: home)).filled(server) else {
                let missing = SecretsEnv.referencedNames(in: server).first ?? "A secret"
                throw DaemonAPI.MCPCatalogError.missingSecret(name: missing)
            }
            guard case .http(let url, let headers) = filled.transport else {
                throw DaemonAPI.MCPCatalogError.invalid("Only a remote (http) server is signed in to.")
            }
            return (url, headers)
        }
    }

    // MARK: Rows

    /// Each row's sign-in, from what is kept, asking an http server that has never been
    /// asked this run once, briefly: an approved one only, with no Authorization of its own.
    func mcpSignInStates(_ rows: [DaemonAPI.ProjectMCPServer],
                         destination: DaemonAPI.SkillDestination) async -> [DaemonAPI.ProjectMCPServer] {
        guard let home = locations.personalHome,
              let file = try? mcpInstaller.mcpURL(destination, personalHome: home),
              case .success(let servers) = PersonalDotAgents.servers(at: file) else { return rows }
        let secrets = SecretsEnv.load(from: SecretsEnv.url(home: home))
        let signIns = mcpSignIns
        var out = rows
        for index in out.indices {
            guard case .approved = out[index].approval, out[index].missingSecrets.isEmpty,
                  let server = servers.first(where: { $0.name == out[index].name }),
                  let filled = secrets.filled(server),
                  case .http(let url, let headers) = filled.transport,
                  !MCPSignIns.bringsOwnAuthorization(headers) else { continue }
            if let state = await signIns.state(server: url) {
                out[index].signIn = state
                continue
            }
            guard !(await signIns.wasProbed(server: url)) else { continue }
            let probe = MCPClient(server: filled, cwd: home, timeout: mcpSignInProbeTimeout, http: await signIns.httpSend)
            do {
                try await probe.connect()
                await signIns.noteProbe(server: url, wantsSignIn: false)
            } catch MCPClient.Failure.authRequired(let metadata) {
                await signIns.markNeedsSignIn(server: url, name: server.name, resourceMetadata: metadata)
                out[index].signIn = .needsSignIn
            } catch {
                await signIns.noteProbe(server: url, wantsSignIn: false)
            }
            await probe.end()
        }
        return out
    }

    // MARK: Words

    static func mcpSignInWords(_ error: any Error) -> String {
        switch error {
        case let failure as MCPOAuth.Failure: failure.sentence
        case let catalog as DaemonAPI.MCPCatalogError: MCPCatalogWords.sentence(catalog)
        case is MCPSignInFile.Unreadable:
            "\(MCPSignInFile.fileName) could not be read, so nothing was written to it. Check it in ~/.agents."
        case let client as MCPClient.Failure: MCPHandEntry.sentence(client, timeout: 15)
        case let refusal as JSONRPCError: refusal.message
        default: "The sign-in couldn't start."
        }
    }

    private static func mcpSignInLogWord(_ error: any Error) -> String {
        switch error {
        case let failure as MCPOAuth.Failure: failure.logWord
        case is MCPSignInFile.Unreadable: "file unreadable"
        default: "failed"
        }
    }
}
#endif
