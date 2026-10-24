import AgentsKitCore
import Foundation
import SwiftUI
import WidgetKit

/// One reading of the snapshot, for every layout.
///
/// The provider does no work of its own: the file is the whole of what the widget knows,
/// and the app is the only thing that writes it (FR-014). It asks to be shown again in a
/// quarter of an hour so that a number the app has not refreshed does not sit on a Home
/// screen for a day saying nothing about how old it is — and because the app redraws it
/// the moment the count actually moves, this is the floor and not the heartbeat.
struct AttentionProvider: TimelineProvider {

    /// What the widget shows before the app has ever run on this device.
    ///
    /// A placeholder is drawn greyed and never counted, and no file is not a zero: the
    /// view for "no snapshot" says it does not know yet (FR-009).
    func placeholder(in context: Context) -> AttentionEntry {
        AttentionEntry(date: Date(), snapshot: AttentionSnapshot(writtenAt: Date(), total: 3, sessions: [
            AttentionSnapshotSession(id: UUID(), folder: "api", title: "Fix the widget",
                                     wanted: "which branch should this go on",
                                     kind: .elicitation, since: Date()),
        ]), isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (AttentionEntry) -> Void) {
        completion(AttentionEntry(date: Date(), snapshot: AttentionSnapshotStore.read()))
    }

    /// A second entry at the moment the number turns stale (#1163), so "Updated 14:02"
    /// becomes "Updated 15 min ago" then and not at the next reading.
    func getTimeline(in context: Context, completion: @escaping (Timeline<AttentionEntry>) -> Void) {
        let now = Date()
        let snapshot = AttentionSnapshotStore.read()
        var entries = [AttentionEntry(date: now, snapshot: snapshot)]
        if let staleAt = snapshot.map({ $0.writtenAt.addingTimeInterval(AttentionSnapshot.staleness + 1) }),
           staleAt > now {
            entries.append(AttentionEntry(date: staleAt, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

/// One moment of the widget: when it is being drawn, and what the app had written.
struct AttentionEntry: TimelineEntry {
    let date: Date
    /// Nil when there is no file, which the widget says rather than showing a zero.
    let snapshot: AttentionSnapshot?
    /// A gallery or a redraw placeholder, drawn greyed and never counted.
    let isPlaceholder: Bool

    init(date: Date, snapshot: AttentionSnapshot?, isPlaceholder: Bool = false) {
        self.date = date
        self.snapshot = snapshot
        self.isPlaceholder = isPlaceholder
    }

    /// Nothing waiting, or nothing known: the two are different and must not look alike.
    var isEmpty: Bool { snapshot?.total == 0 }
    var isUnknown: Bool { snapshot == nil }
    var count: Int { snapshot?.total ?? 0 }

    /// The rows a size draws, newest first, and how many waiting are left undrawn there.
    func rows(for size: AttentionSnapshot.Size) -> [AttentionSnapshotSession] { snapshot?.rows(for: size) ?? [] }
    func leftover(for size: AttentionSnapshot.Size) -> Int { snapshot?.leftover(for: size) ?? 0 }
}
