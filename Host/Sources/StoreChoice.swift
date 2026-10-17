import AgentsKitCore
import Foundation

/// What the person chose in frame L, kept in `~/.agents/settings/host.json` under this Mac's
/// name (#1033), so the launcher (the same program, started by launchd) reads the same
/// choice, and one file holds the role of each of the person's Macs.
struct HostSettings: Codable, Sendable, Equatable {
    enum Role: String, Codable, Sendable {
        /// Nothing chosen yet.
        case none
        /// The control plane and this Mac's host, both here.
        case runHere
        /// Only this Mac's host, for a control plane elsewhere (US9).
        case joinElsewhere
    }

    var role: Role = .none
    var store: StoreChoice = .thisMac
    var bucket = BucketPlace()
    /// Where the control plane went when it was moved off this Mac (T126, frame T), and
    /// when; and until when this Mac's copy forwards members that haven't heard.
    var movedTo: String?
    var movedAt: Date?
    var forwardingUntil: Date?
    /// Run It Here Again (T127, frames V–Y): this Mac's copy starts empty, to receive the
    /// control plane back; and afterwards, where it came back from and until when that
    /// machine forwards.
    var receiving: Bool?
    var returnedFrom: String?
    var returnForwardingUntil: Date?
    /// Serve Agents to browsers on this Mac (071 FR-002). Absent in settings saved before it,
    /// which is on, as it is by default.
    var serveWebRemote: Bool?
    var servesWebRemote: Bool { serveWebRemote ?? true }
    /// Relay for my devices (#809): `agents-relay` carries the person's iPhone and iPad
    /// through iCloud when away, and posts their notices. Off until turned on (Alex).
    var relay: Bool?
    var relaysForDevices: Bool { relay ?? false }

    /// This Mac's entry in `host.json`: its Bonjour name, which the person sees in Sharing.
    private static func key(_ paths: HostPaths) -> String {
        paths.scratchRoot == nil ? LocalHostName.current : "hostSettings.\(paths.suffix)"
    }

    /// Where settings that would not decode are kept (#205): a newer build's role or
    /// store, say. The first such value is kept and never written over.
    static func asideKey(_ paths: HostPaths) -> String { "\(key(paths)).unreadable" }

    /// `~/.agents/settings/host.json` (#1033): one entry per Mac, so the file can follow the
    /// person and each Mac still keeps its own role. The bucket's keys stay in the keychain.
    static var file: URL {
        StoreLocations.settings(inHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            .appendingPathComponent("host.json")
    }

    /// The ordinary set-up's are in `host.json`. A scratch set-up's are a file in its own
    /// root (#1029), which goes when the root does, and never touches the real `~/.agents`.
    private static func read(_ key: String, _ paths: HostPaths) -> Data? {
        guard let root = paths.scratchRoot else {
            guard let entry = entries()?[key] else { return nil }
            return try? JSONSerialization.data(withJSONObject: entry, options: [.fragmentsAllowed])
        }
        return try? Data(contentsOf: root.appendingPathComponent("\(key).json"))
    }

    private static func write(_ data: Data, _ key: String, _ paths: HostPaths) {
        guard let root = paths.scratchRoot else {
            // A file that will not parse is the person's to mend, never ours to replace.
            guard var all = entries() else { return }
            all[key] = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let whole = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            else { return }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? whole.write(to: file, options: .atomic)
            return
        }
        try? data.write(to: root.appendingPathComponent("\(key).json"), options: .atomic)
    }

    /// Every Mac's entry: none when there is no file, and nil when there is one that will
    /// not parse, which `write` then leaves alone.
    private static func entries() -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func load(_ paths: HostPaths) -> HostSettings {
        read(key(paths), paths).flatMap { try? JSONDecoder().decode(HostSettings.self, from: $0) } ?? HostSettings()
    }

    /// What to tell the person when the saved settings would not decode, or nil.
    static func unreadableNote(_ paths: HostPaths) -> String? {
        if paths.scratchRoot == nil, entries() == nil {
            return "\(file.path) could not be read, so this Mac starts with the defaults and leaves the file "
                + "as it is. Mend it, or remove it to start again."
        }
        guard let data = read(key(paths), paths),
              (try? JSONDecoder().decode(HostSettings.self, from: data)) == nil else { return nil }
        return "This Mac's host settings could not be read (perhaps a newer build saved them), so it starts "
            + "with the defaults. What was saved is kept aside, under its own name, and never written over."
    }

    /// A value that would not decode is copied aside first, so the defaults written now
    /// never take the only copy of what a newer build chose.
    func save(_ paths: HostPaths) {
        if let old = Self.read(Self.key(paths), paths),
           (try? JSONDecoder().decode(HostSettings.self, from: old)) == nil,
           Self.read(Self.asideKey(paths), paths) == nil {
            Self.write(old, Self.asideKey(paths), paths)
        }
        if let data = try? JSONEncoder().encode(self) { Self.write(data, Self.key(paths), paths) }
    }
}

/// Where the single copy keeps what it remembers (058, FR-024a, T058a).
enum StoreChoice: String, Codable, Sendable, CaseIterable {
    case thisMac
    case bucket
}

/// A bucket of the person's own. The keys are not here: they are in the keychain.
struct BucketPlace: Codable, Sendable, Equatable {
    var endpoint = ""
    var bucket = ""
    var prefix = "control"
    var region = "us-east-1"

    var isComplete: Bool { !bucket.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Anything but AWS itself is addressed path-style, as MinIO and most others want.
    var pathStyle: Bool { !endpoint.isEmpty && !endpoint.contains("amazonaws.com") }
}

/// The address `agents-control` is given for a choice, and the environment beside it.
struct StoreAddress: Equatable {
    var url: String
    var environment: [String: String]
    var needsKeys: Bool

    init(_ choice: StoreChoice, bucket: BucketPlace, paths: HostPaths) {
        switch choice {
        case .thisMac:
            url = paths.folderStore.absoluteString
            environment = [:]
            needsKeys = false
        case .bucket:
            let prefix = bucket.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            url = "s3://\(bucket.bucket.trimmingCharacters(in: .whitespaces))" + (prefix.isEmpty ? "" : "/\(prefix)")
            var env = ["AGENTS_STORE_REGION": bucket.region.isEmpty ? "us-east-1" : bucket.region]
            let endpoint = bucket.endpoint.trimmingCharacters(in: .whitespaces)
            if !endpoint.isEmpty { env["AGENTS_STORE_ENDPOINT"] = endpoint }
            if bucket.pathStyle { env["AGENTS_STORE_PATH_STYLE"] = "1" }
            environment = env
            needsKeys = true
        }
    }
}
