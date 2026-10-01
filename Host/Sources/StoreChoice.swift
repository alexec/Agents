import Foundation

/// What the person chose in frame L, kept in the app's defaults under the set-up's suffix
/// so the launcher (the same program, started by launchd) reads the same choice.
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

    private static func key(_ paths: HostPaths) -> String { "hostSettings.\(paths.suffix)" }

    static func load(_ paths: HostPaths) -> HostSettings {
        UserDefaults.standard.data(forKey: key(paths)).flatMap { try? JSONDecoder().decode(HostSettings.self, from: $0) }
            ?? HostSettings()
    }

    func save(_ paths: HostPaths) {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key(paths)) }
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
