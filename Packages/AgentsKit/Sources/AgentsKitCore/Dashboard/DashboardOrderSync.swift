import Foundation

/// One screen's Dashboard order kept in step with its host while tiles are dragged (#176).
///
/// A drop is shown at once and sent as the whole order. Two quick drops each sent their
/// own order and refetched, and a refresh for a `dashboard/changed` could be on its way at
/// the same time, so the replies landed in any order: a tile jumped back to where it was,
/// or the host kept the first drop and not the second. So:
/// - **Writes are serial and the last one wins.** One send at a time per folder; drops
///   made while it is out wait, and only the newest of them is sent next.
/// - **A fetch is kept only if nothing newer is.** A reply to a fetch begun before
///   another that has already been kept is dropped; while an order of this screen's is
///   not yet known to be on the host, a fetched snapshot is shown in that order.
///
/// Holds no snapshots, only what was arranged here: the caller stores what `accept` says.
public struct DashboardOrderSync: Sendable {
    /// The newest order arranged here and not yet seen back from the host, by folder.
    private var arranged: [URL: DashboardOrder] = [:]
    /// The newest order waiting to be sent, while a send is out.
    private var unsent: [URL: DashboardOrder] = [:]
    /// Folders with a send out.
    private var sending: Set<URL> = []
    /// Fetches begun, and the newest of them kept, by folder.
    private var begun: [URL: Int] = [:]
    private var kept: [URL: Int] = [:]
    /// The first fetch that began after every order arranged here had been sent.
    private var settledFrom: [URL: Int] = [:]

    public init() {}

    /// A drop or a Move item arranged `order`. True when the caller is to send it, and
    /// then to go on sending `takeUnsent` until it says there is nothing left; false when
    /// a send is already out, which takes this order next.
    public mutating func arrange(_ order: DashboardOrder, in folder: URL) -> Bool {
        let folder = Project.standardize(folder)
        arranged[folder] = order
        unsent[folder] = order
        return sending.insert(folder).inserted
    }

    /// The order to send next, or nil when everything arranged here has been sent.
    public mutating func takeUnsent(in folder: URL) -> DashboardOrder? {
        let folder = Project.standardize(folder)
        if let next = unsent.removeValue(forKey: folder) { return next }
        sending.remove(folder)
        settledFrom[folder] = (begun[folder] ?? 0) + 1
        return nil
    }

    /// A fetch is about to be asked for. Hand its ticket to `accept` with the reply.
    public mutating func beginFetch(in folder: URL) -> Int {
        let folder = Project.standardize(folder)
        begun[folder, default: 0] += 1
        return begun[folder]!
    }

    /// What to show for a fetched snapshot, or nil to keep what is shown: a newer fetch
    /// has already been kept.
    public mutating func accept(_ snapshot: DashboardSnapshot, ticket: Int) -> DashboardSnapshot? {
        let folder = Project.standardize(snapshot.folder)
        guard ticket > (kept[folder] ?? 0) else { return nil }
        kept[folder] = ticket
        guard let order = arranged[folder] else { return snapshot }
        // Asked for after the last send finished: the host's order includes it.
        if !sending.contains(folder), ticket >= (settledFrom[folder] ?? .max) {
            arranged[folder] = nil
            return snapshot
        }
        var shown = snapshot
        shown.order = order
        return shown
    }
}
