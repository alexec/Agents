import Foundation

/// The Mac window's and the Remote's local copy (#4791; spec 4777-fast, "the copy is a
/// cache, never the record"): each machine's folders and lean session records (the live
/// ones and the archived ones on screen), and the end of the last 20 chats opened, as
/// plain JSON files in the platform's `Caches` folder. Keyed by ref (#4727). The client
/// draws it at once, before its host answers, and the host's answer always wins. The
/// system may delete the folder at any time; the client then fetches as before.
///
/// An actor, so encoding and the disk are off the main actor. One file per machine and
/// one per session: a list change writes one small file, and a chat opened writes its own.
public actor LocalCopy {
    /// The most the copy holds on a Mac and on a phone (spec 4777-fast).
    public static let macCap = 200 * 1024 * 1024
    public static let remoteCap = 50 * 1024 * 1024
    /// The transcripts kept: the last ones opened.
    public static let transcriptsKept = 20
    /// A transcript's entries kept: its end, as one `agents/transcript` page.
    public static let entriesKept = ChatOpening.wholeTurn
    /// Archived records kept for one machine: a page's worth, not every fold ever opened.
    public static let archivedKept = 200

    /// One machine: its folders and session records.
    public struct Machine: Codable, Sendable, Equatable {
        public var host: MachineRef
        public var folders: [DaemonAPI.FolderSummary]
        public var agents: [Agent]
        /// Where `agents` are in the host's order of changes (#4794), so a launch asks only
        /// for what changed since. Nil from a copy made before it, or a host that predates it.
        public var point: DaemonAPI.ListRevision?

        public init(host: MachineRef, folders: [DaemonAPI.FolderSummary], agents: [Agent],
                    point: DaemonAPI.ListRevision? = nil) {
            self.host = host
            self.folders = folders
            self.agents = agents
            self.point = point
        }
    }

    /// One chat's end: its finished turns, its last page of entries, and the open turn's
    /// prompt when the page starts after it.
    public struct Transcript: Codable, Sendable, Equatable {
        public var session: UUID
        public var turns: TurnsPage
        public var page: TranscriptPage
        public var ask: TranscriptEntry?

        public init(session: UUID, turns: TurnsPage, page: TranscriptPage, ask: TranscriptEntry? = nil) {
            self.session = session
            self.turns = turns
            self.page = page
            self.ask = ask
        }

        /// What `takeOpening` puts on screen.
        public var opening: ChatOpening.Loaded {
            ChatOpening.Loaded(turns: turns, page: page, turnsFailure: nil, ask: ask)
        }
    }

    public let folder: URL
    public let cap: Int
    public let transcriptsKept: Int

    public init(folder: URL, cap: Int, transcriptsKept: Int = LocalCopy.transcriptsKept) {
        self.folder = folder
        self.cap = cap
        self.transcriptsKept = transcriptsKept
    }

    /// The Mac window's copy: in its root's cache folder, so a scratch root has its own.
    public static func mac(_ locations: StoreLocations = .default) -> LocalCopy {
        LocalCopy(folder: locations.cacheRoot.appendingPathComponent("copy", isDirectory: true), cap: macCap)
    }

    /// The Remote's copy: in the app's own `Caches`.
    public static func remote() -> LocalCopy {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return LocalCopy(folder: caches.appendingPathComponent("copy", isDirectory: true), cap: remoteCap)
    }

    /// A machine's ref (#4727).
    public static func machineRef(_ host: MachineRef) -> WireRef {
        WireRef(provider: "agents", type: "machine", topic: "", id: host.rawValue)
    }

    /// A session's ref (#4727), as the web page's copy keys it: the topic is left out, as the
    /// id is unique without it.
    public static func sessionRef(_ session: UUID) -> WireRef {
        WireRef(provider: "agents", type: "session", topic: "", id: session.uuidString.lowercased())
    }

    private var machines: URL { folder.appendingPathComponent("machines", isDirectory: true) }
    private var transcripts: URL { folder.appendingPathComponent("transcripts", isDirectory: true) }

    /// A ref as a file's name: only letters, digits, `-` and `.`; the ref itself is in the file.
    static func fileName(_ ref: WireRef) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        let name = String(ref.description.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return name + ".json"
    }

    /// The file's form: the ref beside what it holds, so a file is read back only for its ref.
    struct Record<Value: Codable & Sendable>: Codable, Sendable {
        var ref: WireRef
        var value: Value
        /// When the client read `value` from its host (#5141), for the "Last update" line.
        /// Nil in a file written before it: the file's own time is used then.
        var at: Date?
    }

    // MARK: Machines

    /// Every machine held, in no order.
    public func allMachines() -> [Machine] { machinesRead().map(\.machine) }

    /// Every machine held, in no order, with when it was read from its host (#5141).
    public func machinesRead() -> [(machine: Machine, at: Date)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: machines, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { url -> (machine: Machine, at: Date)? in
            guard url.pathExtension == "json", let record = read(Machine.self, at: url) else { return nil }
            var machine = record.value
            // The host is the copy's to say, whatever a record's own coding keeps of it.
            machine.agents = machine.agents.map { var agent = $0; agent.host = machine.host; return agent }
            let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (machine, record.at ?? written ?? .distantPast)
        }
    }

    /// `at` is when the client read the machine from its host; now when not given.
    public func keep(_ machine: Machine, readAt at: Date = Date()) {
        var machine = machine
        // The live ones whole, and the archived ones newest first, at most a page of them.
        let live = machine.agents.filter { $0.state != .archived }
        let archived = machine.agents.filter { $0.state == .archived }
            .sorted { ($0.archivedAt ?? $0.createdAt) > ($1.archivedAt ?? $1.createdAt) }
            .prefix(Self.archivedKept)
        machine.agents = live + archived
        let ref = Self.machineRef(machine.host)
        write(Record(ref: ref, value: machine, at: at), to: machines.appendingPathComponent(Self.fileName(ref)))
    }

    // MARK: Transcripts

    public func transcript(of session: UUID) -> Transcript? {
        let ref = Self.sessionRef(session)
        guard let record = read(Transcript.self, at: transcripts.appendingPathComponent(Self.fileName(ref))),
              record.ref == ref else { return nil }
        return record.value
    }

    /// A chat's end, kept: at most `entriesKept` of its entries, then the copy trimmed to
    /// its caps, the oldest transcript first.
    public func keep(_ transcript: Transcript) {
        var transcript = transcript
        let drop = transcript.page.entries.count - Self.entriesKept
        if drop > 0 {
            transcript.page.entries.removeFirst(drop)
            transcript.page.firstIndex += drop
        }
        let ref = Self.sessionRef(transcript.session)
        write(Record(ref: ref, value: transcript, at: Date()), to: transcripts.appendingPathComponent(Self.fileName(ref)))
        trim()
    }

    /// Transcripts past the newest `transcriptsKept`, then, while the whole copy is over `cap`,
    /// the oldest Work entry (#4930) and, with none left, the oldest transcript. Machines are
    /// never dropped: all of them are well under a megabyte.
    func trim() {
        let fm = FileManager.default
        var held = Self.files(transcripts).sorted { $0.at > $1.at }
        while held.count > transcriptsKept, let oldest = held.popLast() { try? fm.removeItem(at: oldest.url) }
        var work = trimWork().sorted { $0.at > $1.at }
        var total = (held + work + Self.files(machines)).reduce(0) { $0 + $1.bytes }
        while total > cap, let oldest = work.popLast() ?? held.popLast() {
            try? fm.removeItem(at: oldest.url)
            total -= oldest.bytes
        }
    }

    static func files(_ in: URL) -> [(url: URL, at: Date, bytes: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        return ((try? FileManager.default.contentsOfDirectory(at: `in`, includingPropertiesForKeys: keys)) ?? []).map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
        }
    }

    /// Everything gone: the pairing went, and what this device kept of it goes with it.
    public func forget() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Files

    func read<Value: Codable & Sendable>(_: Value.Type, at url: URL) -> Record<Value>? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A file that does not read (an older form, cut short) is only a copy missing.
        return try? JSONDecoder().decode(Record<Value>.self, from: data)
    }

    func write<Value: Codable & Sendable>(_ record: Record<Value>, to url: URL) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic, so a reader never finds half a file.
        try? data.write(to: url, options: .atomic)
    }
}
