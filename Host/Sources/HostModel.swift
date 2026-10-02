import AgentsKit
import AgentsKitCore
import AppKit
import Observation

/// What frame L shows and does (058, US2): this Mac's host, the single copy of the control
/// plane when it runs here, where it keeps its store, and the code to pair a window or phone.
@MainActor
@Observable
final class HostModel {
    let paths = HostPaths.current
    private(set) var settings: HostSettings
    private var services: LocalServices { LocalServices(paths: paths) }

    // MARK: What is running

    private(set) var controlRunning = false
    private(set) var daemonRunning = false
    private(set) var runningSince: Date?
    private var controlPID: Int32?
    private(set) var clients: Int?
    private(set) var hosts: Int?
    private(set) var projects: Int?
    private(set) var working: Int?
    /// macOS wants the person to allow Agents Host under Login Items.
    private(set) var needsApproval = false
    /// A step under way: "Starting the control plane…".
    private(set) var busy: String?
    /// What went wrong last, in words.
    var problem: String?

    // MARK: The store, being edited

    var storeDraft: StoreChoice
    var bucketDraft: BucketPlace
    var accessKeyDraft = ""
    var secretDraft = ""

    enum Check: Equatable {
        case checking
        case works
        case failed(String)
    }
    private(set) var check: Check?

    // MARK: Pairing

    struct PairingCode: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var target: PairingTarget
    }

    /// What the code is for, which decides how it is shown and where it works. Each may
    /// do everything once paired (#111).
    enum PairingTarget: Hashable {
        case window, phone, browser
    }
    var pairing: PairingCode?
    var pairingTarget: PairingTarget = .window
    var showingPairing = false

    /// The host code `runHere` made last: what the move tells devices, with its address,
    /// pin and key (T085).
    private(set) var lastHostCode: ControlCode?

    init() {
        let settings = HostSettings.load(HostPaths.current)
        self.settings = settings
        storeDraft = settings.store
        bucketDraft = settings.bucket
        if let keys = HostSecrets.bucketKeys(HostPaths.current) {
            accessKeyDraft = keys.accessKey
            secretDraft = keys.secretKey
        }
    }

    /// `https://<this Mac>.local:8791`: what codes carry and clients dial.
    var controlURL: String {
        let name = ProcessInfo.processInfo.hostName
        let host = name.hasSuffix(".local") ? name : (name.split(separator: ".").first.map { "\($0).local" } ?? name)
        return "https://\(host.lowercased()):\(paths.port)"
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// The store as the running copy uses it, as against the one being edited.
    var storeIsSaved: Bool {
        storeDraft == settings.store && (storeDraft == .thisMac || (bucketDraft == settings.bucket && keysMatchSaved))
    }

    private var keysMatchSaved: Bool {
        HostSecrets.bucketKeys(paths) == HostSecrets.BucketKeys(accessKey: accessKeyDraft, secretKey: secretDraft)
    }

    // MARK: Looking

    func refresh() async {
        let services = self.services
        let control = await services.running(.control)
        controlRunning = control != nil
        daemonRunning = await services.running(.daemon) != nil
        // Read again whenever the process is another one: a restart or a store switch.
        if let control, control != controlPID { runningSince = Self.started(control) }
        if control == nil { runningSince = nil }
        controlPID = control
        webRemote = control.flatMap { WebRemoteFile.read(in: paths.controlHome, pid: $0) }
        if controlRunning, settings.role == .runHere {
            let listed = await ControlTool.run(["clients"], paths: paths, settings: settings, key: false)
            clients = listed.ok ? listed.output.split(separator: "\n").count : nil
            let joined = await ControlTool.run(["hosts"], paths: paths, settings: settings, key: false)
            hosts = joined.ok ? joined.output.split(separator: "\n").count : nil
        } else {
            clients = nil
            hosts = nil
        }
        await readForwarding()
        await readReturnForwarding()
        await countWork()
    }

    /// One connection to this Mac's host, kept while it answers: a socket opened every few
    /// seconds is how a daemon's descriptors ran out once.
    private var hostClient: DaemonClient?

    /// From this Mac's own host, over its socket: never starting one.
    private func countWork() async {
        guard daemonRunning else { projects = nil; working = nil; return }
        let client: DaemonClient
        if let kept = hostClient {
            client = kept
        } else {
            client = DaemonClient(link: LookingLink(locations: paths.hostLocations))
            do { try await client.connect(startIfNeeded: false, timeout: .seconds(2)) } catch { return }
            hostClient = client
        }
        let listed = try? await client.call(DaemonAPI.Method.projectsList, [String: String](), returning: JSONValue.self)
        let agents = try? await client.call(DaemonAPI.Method.agentsList, ["includeArchived": false, "lean": true],
                                           returning: JSONValue.self)
        if listed == nil, agents == nil {
            // Gone away: connect afresh next time.
            await client.disconnect()
            hostClient = nil
            return
        }
        if case .array(let all)? = listed { projects = all.count }
        if case .array(let all)? = agents {
            working = all.filter { $0["state"]?.stringValue == AgentState.running.rawValue }.count
        }
    }

    private static func started(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    // MARK: Run it here

    /// The control plane and this Mac's host, both here, and the host enrolled with it.
    func runHere() async {
        guard busy == nil else { return }
        problem = nil
        if storeDraft == .bucket {
            guard await saveBucket() else { return }
        }
        settings.role = .runHere
        settings.store = storeDraft
        settings.save(paths)
        busy = "Starting the control plane…"
        defer { busy = nil }
        // Made before the launcher starts, so there is one key to begin with.
        do { _ = try HostSecrets.controlKey(paths) } catch { problem = "The control plane's key: \(error)"; return }
        guard await start(.control) else { return }
        // The copy writes its settings to the store as it starts; a code can be made
        // once they are there.
        var code: ControlTool.Result?
        for _ in 0..<40 {
            let made = await ControlTool.run(["code", "--host", "--home", paths.controlHome.path], paths: paths, settings: settings)
            if made.ok { code = made; break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let code, let text = code.output.split(separator: "\n").last.map(String.init) else {
            problem = "The control plane did not start. Its log is at \(paths.controlLog.path)."
            return
        }
        lastHostCode = ControlCode(text: text)
        busy = "Starting this Mac's host…"
        if !services.hostJoined {
            do { try services.leaveCode(text) } catch { problem = "\(error)"; return }
        }
        let wasRunning = await services.running(.daemon) != nil
        guard await start(.daemon) else { return }
        // A host already running read no code; started again, it does.
        if wasRunning, !services.hostJoined { _ = await services.restart(.daemon) }
        await refresh()
    }

    /// Only this Mac's host, for a control plane elsewhere: a host code from it (US9).
    func joinElsewhere(code: String) async {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ControlCode(text: code)?.purpose == .host else {
            problem = "That isn't a host code. Ask the other control plane for one: Settings ▸ Control plane ▸ Hosts ▸ Add a Mac."
            return
        }
        busy = "Joining…"
        defer { busy = nil }
        settings.role = .joinElsewhere
        settings.save(paths)
        await services.unregister(.control)
        // A membership of this Mac's own control plane would be dialled instead.
        try? FileManager.default.removeItem(at: paths.hostLocations.controlHostMembership)
        do { try services.leaveCode(code) } catch { problem = "\(error)"; return }
        let wasRunning = await services.running(.daemon) != nil
        guard await start(.daemon) else { return }
        if wasRunning { _ = await services.restart(.daemon) }
        await refresh()
    }

    // MARK: Moved to another machine (T126, frame T)

    /// This Mac's copy, while it forwards members that haven't heard where it went.
    private(set) var forwarding: HandoverStatus?

    /// The handover is done: this Mac is a host of the control plane at `place`, and its
    /// own copy forwards until `until`, if it is forwarding at all.
    func moved(to place: String, forwardingUntil until: Date?) {
        settings.role = .joinElsewhere
        settings.movedTo = place
        settings.movedAt = Date()
        settings.forwardingUntil = until
        settings.save(paths)
        Task { await refresh() }
    }

    /// Who this Mac's forwarding copy still has to tell. Asked of the control plane where
    /// it is now: members say what they hold there, not to the frozen copy here.
    /// Forwarding ends by itself once everyone has heard, or on its date (30 days at most).
    private func readForwarding() async {
        guard let until = settings.forwardingUntil, let place = settings.movedTo else { forwarding = nil; return }
        if until < Date() { return await stopForwarding() }
        let read = await ControlTool.run(["handover", "status", "--at", place, "--json"], paths: paths, settings: settings)
        guard read.ok, let status = try? JSONDecoder().decode(HandoverStatus.self, from: Data(read.output.utf8)) else { return }
        forwarding = status
        if status.stillToHear.isEmpty { await stopForwarding() }
    }

    /// Stop Forwarding: this Mac's copy stops. Anyone still to hear pairs again.
    func stopForwarding() async {
        await services.unregister(.control)
        settings.forwardingUntil = nil
        settings.save(paths)
        forwarding = nil
    }

    // MARK: Run it here again (T127, frames V–Y)

    /// The other machine, while it forwards members that haven't heard the control plane
    /// came back, as this Mac's copy sees them (they report here now).
    private(set) var returnForwarding: HandoverStatus?

    /// This Mac's copy, ready to receive: forwarding stops, the store from before the move
    /// is kept aside, and the copy starts empty. Returns the name it was kept under.
    func prepareReturn() async -> String? {
        await services.unregister(.control)
        for _ in 0..<20 where await services.running(.control) != nil { try? await Task.sleep(for: .milliseconds(250)) }
        settings.forwardingUntil = nil
        var aside: String?
        if FileManager.default.fileExists(atPath: paths.folderStore.path) {
            let day = Date().formatted(.iso8601.year().month().day())
            let name = "store-before-\(day)-\(Int(Date().timeIntervalSince1970) % 100_000)"
            if (try? FileManager.default.moveItem(at: paths.folderStore, to: paths.controlHome.appendingPathComponent(name))) != nil {
                aside = name
            }
        }
        settings.store = .thisMac
        settings.receiving = true
        settings.save(paths)
        _ = await start(.control)
        return aside
    }

    /// Cancelled before this Mac took over: its empty copy stops again.
    func undoReturn() async {
        await services.unregister(.control)
        settings.receiving = false
        settings.save(paths)
    }

    /// The control plane is back: it runs here, and `place` forwards until `until`.
    func returned(from place: String, forwardingUntil until: Date?) {
        settings.role = .runHere
        settings.movedTo = nil
        settings.movedAt = nil
        settings.forwardingUntil = nil
        settings.receiving = false
        settings.returnedFrom = place
        settings.returnForwardingUntil = until
        settings.save(paths)
        Task { await refresh() }
    }

    private func readReturnForwarding() async {
        guard settings.returnedFrom != nil, settings.role == .runHere, controlRunning else { returnForwarding = nil; return }
        returnForwarding = await HandoverTool.status(["--at", "self"], model: self)
    }

    /// Whether the other machine has nobody left to tell, or its forwarding has ended.
    var returnForwardingDone: Bool {
        if let until = settings.returnForwardingUntil, until < Date() { return true }
        return returnForwarding.map { $0.stillToHear.isEmpty } ?? false
    }

    /// Stop Forwarding (frame Y): the other machine stops now. Anyone still to hear pairs again.
    func stopReturnForwarding() async {
        guard let place = settings.returnedFrom else { return }
        let stopped = await HandoverTool.run(["stop", "--at", place], model: self)
        if !stopped.ok { problem = stopped.problem; return }
        settings.returnForwardingUntil = Date()
        settings.save(paths)
    }

    /// The row goes: the other machine can be taken down.
    func dismissReturn() {
        settings.returnedFrom = nil
        settings.returnForwardingUntil = nil
        settings.save(paths)
        returnForwarding = nil
    }

    // MARK: The web remote (071)

    /// Serve Agents to browsers on this Mac, or stop (071 FR-002): the control plane starts
    /// again with or without its loopback listener.
    func setServeWebRemote(_ on: Bool) async {
        guard settings.servesWebRemote != on else { return }
        settings.serveWebRemote = on
        settings.save(paths)
        await restartControl()
    }

    /// Where the web remote is, while it is served.
    var webRemoteAddress: String { "http://localhost:\(paths.webPort)" }

    /// Whether the running control plane serves the page, and why not (071 R3), as it wrote
    /// it to `web.json`; nil until it has, or while it isn't running.
    private(set) var webRemote: DaemonAPI.WebRemoteStatus?

    /// The toggle's line: what the control plane says, else the address it was asked for.
    var webRemoteLine: String {
        guard settings.servesWebRemote, controlRunning, let webRemote else {
            return "At \(webRemoteAddress), for a browser on this Mac only."
        }
        return webRemote.summary
    }

    /// The person turned it on and the control plane couldn't serve it.
    var webRemoteFailed: Bool { settings.servesWebRemote && controlRunning && webRemote?.served == false }

    /// Asks the running control plane to bind the page's port again, keeping every
    /// connection it has: SIGUSR1 to `agents-control serve` (071 R3).
    func retryWebRemote() async {
        guard let controlPID else { return }
        busy = "Trying again…"
        defer { busy = nil }
        kill(controlPID, SIGUSR1)
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    /// **Open in Browser** (#109): the page in the default browser, pairing it in the same
    /// step with a browser code in the fragment if no browser of its kind is paired yet
    /// (`BrowserOpening`). Why not goes to `problem`.
    func openInBrowser() async {
        problem = nil
        let listed = await ControlTool.run(["clients"], paths: paths, settings: settings, key: false)
        // `<id>\t<name>\t<kind>` a line.
        let browsers = listed.output.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            .filter { $0.count >= 3 && $0[2] == ClientRecord.Kind.browser.rawValue }.map { $0[1] }
        let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "http://localhost")!)
        let family = BrowserOpening.family(bundleID: app.flatMap { Bundle(url: $0)?.bundleIdentifier })
        let web = settings.servesWebRemote && controlRunning ? webRemote : nil
        switch BrowserOpening.step(web: web, browsers: browsers, family: family) {
        case .notServed(let why):
            problem = why
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .pair:
            // A browser's code is good only through the page's own listener (071 R2).
            let made = await ControlTool.run(["code", "--client", "--browser", "--home", paths.controlHome.path],
                                             paths: paths, settings: settings)
            guard made.ok, let web, let text = made.output.split(separator: "\n").last.map(String.init),
                  let url = BrowserOpening.pairingURL(web, code: text) else {
                problem = made.problem.isEmpty ? "No code could be made." : made.problem
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func restartControl() async {
        busy = "Restarting…"
        defer { busy = nil }
        _ = await services.restart(.control)
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    private func start(_ job: LocalServices.Job) async -> Bool {
        switch await services.register(job) {
        case .enabled:
            needsApproval = false
            return true
        case .needsApproval:
            needsApproval = true
            problem = "Allow Agents Host in System Settings ▸ General ▸ Login Items, then try again."
            return false
        case .failed(let why):
            problem = why
            return false
        }
    }

    // MARK: The store

    private var draftKeys: HostSecrets.BucketKeys {
        HostSecrets.BucketKeys(accessKey: accessKeyDraft.trimmingCharacters(in: .whitespaces),
                               secretKey: secretDraft.trimmingCharacters(in: .whitespaces))
    }

    /// The start-up probe against the bucket as typed, before anything is saved (T058a).
    func checkBucket() async {
        check = .checking
        let address = StoreAddress(.bucket, bucket: bucketDraft, paths: paths)
        let result = await ControlTool.run(["store", "check"], paths: paths, settings: settings, key: false,
                                           store: address, keys: draftKeys)
        check = result.ok ? .works : .failed(result.problem)
    }

    /// The bucket's place in the settings and its keys in the keychain.
    @discardableResult
    private func saveBucket() async -> Bool {
        guard bucketDraft.isComplete, !draftKeys.accessKey.isEmpty, !draftKeys.secretKey.isEmpty else {
            problem = "Say the bucket and both keys first."
            return false
        }
        do {
            try HostSecrets.saveBucketKeys(draftKeys, paths)
        } catch {
            problem = "The keys could not be kept: \(error)"
            return false
        }
        settings.bucket = bucketDraft
        settings.save(paths)
        return true
    }

    /// Switch Store… (T058b): stop the copy, copy every record across, point the copy at
    /// the new store and start it. The old store is kept until the person removes it.
    func switchStore() async {
        guard busy == nil, settings.role == .runHere else { return }
        problem = nil
        let from = StoreAddress(settings.store, bucket: settings.bucket, paths: paths)
        if storeDraft == .bucket {
            guard await saveBucket() else { return }
        }
        let to = StoreAddress(storeDraft, bucket: bucketDraft, paths: paths)
        guard from != to else { return }
        busy = "Switching the store…"
        defer { busy = nil }
        await services.unregister(.control)
        for _ in 0..<20 where await services.running(.control) != nil { try? await Task.sleep(for: .milliseconds(250)) }
        // A folder store switched away from before is kept aside, so switching back to
        // this Mac starts from an empty folder rather than a stale one.
        if to.url == paths.folderStore.absoluteString, FileManager.default.fileExists(atPath: paths.folderStore.path) {
            let aside = paths.controlHome.appendingPathComponent("store-before-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: paths.folderStore, to: aside)
        }
        let bucket = from.needsKeys ? from : to
        let copied = await ControlTool.run(["store", "copy", "--from", from.url, "--to", to.url], paths: paths,
                                           settings: settings, key: false, store: bucket)
        if copied.ok {
            settings.store = storeDraft
            settings.save(paths)
        } else {
            problem = copied.problem
        }
        // Started again either way: on the new store, or on the old one after a failure.
        _ = await start(.control)
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    // MARK: Pairing

    /// A code to type into a window, a phone or a browser.
    func makeCode() async {
        pairing = nil
        let target = pairingTarget
        // A browser's code is good only through the page's own listener (071 R2).
        let made = await ControlTool.run(["code", "--client", "--home", paths.controlHome.path]
                                             + (target == .browser ? ["--browser"] : []),
                                         paths: paths, settings: settings)
        guard made.ok, let text = made.output.split(separator: "\n").last.map(String.init) else {
            problem = made.problem.isEmpty ? "No code could be made." : made.problem
            return
        }
        pairing = PairingCode(text: text, target: target)
    }
}

/// A way to this Mac's host that only looks: when nothing answers, it starts nothing.
struct LookingLink: DaemonLink {
    let locations: StoreLocations
    func transport() async throws -> any LineTransport {
        FDTransport(socket: try connectUnixSocket(path: locations.socket.path))
    }
    func start() async throws {}
}
