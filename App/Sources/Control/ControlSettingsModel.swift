import AgentsKitCore
import AppKit

/// What Settings ▸ Control plane shows (058, frames D–F): the control plane itself, its
/// hosts and its clients, kept true by the control plane's own notifications.
///
/// A connection of its own to the control plane, as the window's second client session:
/// Settings can be open while the window reconnects, and the other way round.
@MainActor
@Observable
final class ControlSettingsModel {
    private(set) var status: DaemonAPI.ControlStatus?
    private(set) var hosts: [DaemonAPI.ControlHost] = []
    private(set) var clients: [ClientRecord] = []
    /// How each connected client reaches the control plane now (frame N). Empty from a
    /// control plane that does not say.
    private(set) var connections: [UUID: DaemonAPI.ClientConnection] = [:]
    /// Said when an action was refused, in the words the control plane used.
    var problem: String?
    private(set) var isReachable = false

    /// Where the control plane is, as the page says it when it can't be reached: its
    /// folder on this Mac, or the addresses it was paired at.
    let whereItIs: String
    private let link: ControlLink
    private let client: DaemonClient
    private var listening: Task<Void, Never>?

    init?(endpoint: ControlConfig.Endpoint) {
        guard let link = ControlConfig.link(endpoint) else { return nil }
        self.link = link
        client = DaemonClient(link: link.controlLink)
        switch endpoint {
        case .remote(let membership):
            whereItIs = "\(membership.name) (\(membership.url ?? membership.addresses.first ?? "no address"))"
        }
    }

    /// Whether the control plane runs on this Mac, and so may be restarted from here.
    var isOnThisMac: Bool { status?.machineID == MachineID.current }

    /// The host on this Mac: shown first and without buttons (the look gate's decision).
    var thisMacHost: DaemonAPI.ControlHost? { hosts.first { $0.machineID == MachineID.current && $0.relay != true } }
    /// Every other host, and this Mac's relay: it shares the Mac's machine but is not its host.
    var otherHosts: [DaemonAPI.ControlHost] { hosts.filter { $0.machineID != MachineID.current || $0.relay != nil } }

    var onlineCount: Int { hosts.filter { $0.state == "online" }.count }

    func start() async {
        await refresh()
        guard listening == nil else { return }
        listening = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for await note in self.client.notifications() where note.method.hasPrefix("control/") {
                    if note.method == DaemonAPI.Notification.controlInstallProgress {
                        self.installStep = note.params?["step"]?.stringValue
                        continue
                    }
                    if note.method == DaemonAPI.Notification.controlTunnelChanged,
                       let change = try? note.params?.decode(DaemonAPI.HostTunnelChanged.self) {
                        self.tunnels[change.name] = change.tunnel
                    }
                    await self.refresh()
                }
                // The control plane went; come back when it does.
                self.isReachable = false
                try? await Task.sleep(for: .seconds(2))
                await self.refresh()
            }
        }
    }

    func stop() {
        listening?.cancel()
        listening = nil
        Task { await client.disconnect() }
    }

    func refresh() async {
        do {
            try await client.connect(startIfNeeded: false, timeout: .seconds(2))
            status = try await client.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
            hosts = try await client.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)
            clients = try await client.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
                .sorted { ($0.id == status?.you ? 0 : 1, $0.paired) < ($1.id == status?.you ? 0 : 1, $1.paired) }
            let links = (try? await client.call(DaemonAPI.Method.clientsConnections,
                                                returning: [DaemonAPI.ClientConnection].self)) ?? []
            connections = Dictionary(links.map { ($0.client, $0) }, uniquingKeysWith: { $1 })
            isReachable = true
        } catch {
            isReachable = false
        }
    }

    // MARK: Actions

    func forget(_ client: UUID) async {
        await perform(DaemonAPI.Method.clientsForget, DaemonAPI.ClientRequest(client: client))
    }

    /// Forget This Mac (#344, 071 FR-015): the control plane forgets this window, and only
    /// it, then the window's pairing goes. True when it was forgotten; otherwise `problem`
    /// says why, and nothing has changed.
    func forgetThisWindow() async -> Bool {
        do {
            _ = try await client.call(DaemonAPI.Method.clientsForgetSelf, DaemonAPI.Empty())
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
            return false
        } catch {
            problem = "The control plane can’t be reached."
            return false
        }
        problem = nil
        ControlConfig.forget()
        return true
    }

    func checkAgain(_ host: HostID) async {
        await perform(DaemonAPI.Method.hostsCheckAgain, DaemonAPI.HostRequest(host: host))
    }

    func remove(_ host: HostID) async {
        await perform(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host))
    }

    /// The step the control plane says an install is at (`control/installProgress`).
    private(set) var installStep: String?
    /// How each server's reverse tunnel stands, by name, as the control plane said it
    /// (`control/tunnelChanged`, #435): before the server has joined, too.
    private(set) var tunnels: [String: DaemonAPI.HostTunnel] = [:]

    enum InstallOutcome: Equatable {
        /// `tunnel`: the server is reached through a bastion, so it dials the control plane
        /// through a reverse tunnel the control plane holds over ssh (#435).
        case added(name: String, tunnel: Bool)
        /// The server's key is new to this Mac: the person looks at it and says so.
        case needsTrust(fingerprint: String)
        case failed(String)
    }

    /// Add a server over ssh (frame M2): the control plane installs the host once with the
    /// key given here, which goes in this one call and is kept nowhere (058, T072). With no
    /// key, the control plane's ssh logs in as `ssh user@host` would (#413).
    func install(destination: String, name: String? = nil, key: String? = nil, trust: String? = nil) async -> InstallOutcome {
        installStep = nil
        var params: [String: JSONValue] = ["destination": .string(destination)]
        if let key { params["key"] = .string(key) }
        if let name, !name.isEmpty { params["name"] = .string(name) }
        if let trust { params["trust"] = .string(trust) }
        do {
            let answer = try await client.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
            await refresh()
            if let fingerprint = answer["needsTrust"]?.stringValue { return .needsTrust(fingerprint: fingerprint) }
            return .added(name: answer["name"]?.stringValue ?? name ?? destination,
                          tunnel: answer["tunnel"]?.boolValue ?? false)
        } catch let error as JSONRPCError {
            return .failed(HostProblem.controlRefusal(error))
        } catch {
            return .failed("The control plane can’t be reached.")
        }
    }

    /// The servers in the ssh config that answer, installed (#429): what happened to
    /// each, or nil with `problem` saying why it could not look.
    func detectServers() async -> [DaemonAPI.DetectedServer]? {
        installStep = nil
        do {
            let found = try await client.call(DaemonAPI.Method.hostsDetect, returning: [DaemonAPI.DetectedServer].self)
            problem = nil
            await refresh()
            return found
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached."
        }
        return nil
    }

    /// Where a host added from now on has its projects found (#429).
    var projectDetection: ProjectDetection { status?.projectDetection ?? .standard }

    func setProjectDetection(_ detection: ProjectDetection) async {
        await perform(DaemonAPI.Method.controlSetProjectDetection, detection)
    }

    /// A code for a new client, or for a new host (frame G, Add by Code). A browser's is
    /// good only through the page's own listener (071 R2).
    func startCode(forHost: Bool, browser: Bool = false) async -> DaemonAPI.ControlCodeShown? {
        do {
            let shown: DaemonAPI.ControlCodeShown = if forHost {
                try await client.call(DaemonAPI.Method.hostsStartEnroll, returning: DaemonAPI.ControlCodeShown.self)
            } else {
                try await client.call(DaemonAPI.Method.clientsStartPairing,
                                      JSONValue.object(browser ? ["kind": .string(ClientRecord.Kind.browser.rawValue)] : [:]),
                                      returning: DaemonAPI.ControlCodeShown.self)
            }
            problem = nil
            return shown
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached."
        }
        return nil
    }

    /// **Open in Browser** (#109): the page in the default browser, pairing it in the same
    /// step if no browser of its kind is paired yet (`BrowserOpening`). Nil once opened, else
    /// why not, in words to show.
    func openInBrowser() async -> String? {
        await refresh()
        guard isReachable, let status else { return "The control plane can’t be reached." }
        guard isOnThisMac else { return "The page is served only to a browser on the Mac that runs the control plane." }
        let browsers = clients.filter { $0.kind == .browser }.map(\.name)
        switch BrowserOpening.step(web: status.web, browsers: browsers, family: Self.defaultBrowserFamily) {
        case .notServed(let why):
            return why
        case .open(let url):
            Self.open(url)
            return nil
        case .pair:
            guard let web = status.web, let code = await startCode(forHost: false, browser: true) else {
                return problem ?? "No code could be made."
            }
            guard let url = BrowserOpening.pairingURL(web, code: code.text) else { return "No code could be made." }
            Self.open(url)
            return nil
        }
    }

    /// A walk drives a headless Chrome of its own, never the person's browser.
    private static var defaultBrowserFamily: String? {
        if ControlConfig.walk != nil { return "Chrome" }
        let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://localhost")!)
        return BrowserOpening.family(bundleID: app.flatMap { Bundle(url: $0)?.bundleIdentifier })
    }

    /// The default browser, or for a walk the file its headless browser is pointed at by.
    private static func open(_ url: URL) {
        if let file = ControlConfig.walkOpenedURL {
            try? Data(url.absoluteString.utf8).write(to: file, options: .atomic)  // store-ok: the window's own container
            return
        }
        NSWorkspace.shared.open(url)  // store-ok: a web page
    }

    func stopCodes() async {
        _ = try? await client.call(DaemonAPI.Method.clientsStopPairing)
    }

    func restart() async {
        // The control plane on this Mac is Agents Host's to restart.
        problem = "Restart the control plane from Agents Host."
        return
    }

    private func perform(_ method: String, _ params: some Encodable & Sendable) async {
        do {
            _ = try await client.call(method, params)
            problem = nil
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached."
        }
        await refresh()
    }
}
