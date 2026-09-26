import SwiftUI
import UIKit

/// What the terminal, the live page and files show while the phone is away (046, look B).
///
/// Those three stream too much, too often, for iCloud's seconds. Rather than a spinner
/// that never finishes, the place they would be says where they will work, and what
/// works here. It turns into the real thing by itself when the phone is back on the
/// Mac's network: the pane is drawn from the link, so nobody has to reopen it (FR-012).
struct NeedsSameNetworkView: View {
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone" }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house")
                // Decorative: a glyph above the words, not text, and hidden from VoiceOver.
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Needs the same network as your Mac")
                .appText(.reading).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("The terminal, the live page and files open here when your \(device) is on your Mac's Wi-Fi. "
                 + "Chat, questions and starting agents work from anywhere.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// What a phone that has never been on the Mac's network shows away (046, look C): the
/// one thing it has to do, and what doing it buys.
struct PairAtHomeView: View {
    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone" }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house")
                // Decorative: a glyph above the words, not text, and hidden from VoiceOver.
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Open Agents once on your Mac's Wi-Fi")
                .appText(.reading).fontWeight(.semibold)
                .multilineTextAlignment(.center)
            Text("After that, your \(device) reaches your Mac from anywhere, through your iCloud.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
