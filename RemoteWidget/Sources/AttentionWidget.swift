import AgentsKitCore
import SwiftUI
import WidgetKit

/// The Home-screen widget: how many sessions need a person, and which.
///
/// A view of the app's number and nothing else. It opens no connection and holds no key
/// (FR-014); it reads `AttentionSnapshot` from the pair's shared storage on this device,
/// which the app writes whenever its own count changes (FR-016).
///
/// The Home screen's sizes and no others (FR-002): a small one that is the number, a
/// medium one that is the number and the newest few sessions, each row a `Link` into that
/// conversation, and a large one (and the iPad's extra large) with more of them and more of
/// each (#192). Lock Screen and StandBy are out of scope, and the reasons are in 068's
/// Out of Scope.
@main
struct AttentionWidgetBundle: WidgetBundle {
    var body: some Widget { AttentionWidget() }
}

struct AttentionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AttentionSnapshot.widgetKind, provider: AttentionProvider()) { entry in
            AttentionEntryView(entry: entry)
                // The app's own ground, so a widget on a Home screen is paper like
                // everything else the person reads in this app.
                .containerBackground(Paper.ground, for: .widget)
        }
        .configurationDisplayName("Needs you")
        .description("How many agent sessions are waiting for you.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
