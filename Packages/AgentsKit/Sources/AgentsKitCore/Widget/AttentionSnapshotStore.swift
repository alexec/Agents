import Foundation

/// Where the snapshot the widget reads lives, and who writes it.
///
/// The pair's shared storage on this device: an app group the Remote already holds and
/// nothing has used until now (068). One file, written by the app, read by the widget, and
/// removed with the app (FR-015). Nothing here is the work itself, and nothing here outlives
/// the app that wrote it.
///
/// Every failure is silent by design (FR-018): a widget that cannot be written is the same
/// widget as yesterday, and an error the person cannot do anything about is not shown.
public enum AttentionSnapshotStore {

    /// The Remote's own app group. The widget's entitlements ask for this and nothing else.
    public static let appGroup = "group.com.alexecollins.agents"

    public static let fileName = "attention-snapshot.json"

    /// Where the file is, or nil when the app group is not available — a simulator run
    /// with no entitlement, an extension out of context, or a Linux server, which has no
    /// app groups.
    public static var container: URL? {
        #if canImport(Darwin)
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        #else
        nil
        #endif
    }

    /// The file itself, or nil when there is no container.
    public static func url(in container: URL? = nil) -> URL? {
        (container ?? AttentionSnapshotStore.container)?.appendingPathComponent(fileName)
    }

    /// Write it whole, or not at all: a half-written file is a widget showing half a
    /// count.
    ///
    /// - Returns: whether it was written, so a caller can skip a redraw when nothing moved.
    @discardableResult
    public static func write(_ snapshot: AttentionSnapshot, into container: URL? = nil) -> Bool {
        guard let url = url(in: container),
              let data = try? JSONEncoder().encode(snapshot) else { return false }
        // Compared by what it says, not by its bytes: the notification loop delivers several
        // notifications for one change, and a redraw costs more than the write.
        if let existing = read(from: container), existing.saysTheSame(as: snapshot) { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// The last snapshot the app wrote, or nil when there is none — which the widget says
    /// out loud rather than showing a zero (FR-009).
    public static func read(from container: URL? = nil) -> AttentionSnapshot? {
        guard let url = url(in: container), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AttentionSnapshot.self, from: data)
    }

    /// Take it away, which nothing needs today and exists for the tests to be sure of.
    static func remove(from container: URL? = nil) {
        guard let url = url(in: container) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
