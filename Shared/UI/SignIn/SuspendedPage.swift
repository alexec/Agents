import AgentsKitCore
import SwiftUI

/// What a client of a suspended person shows, and nothing else (#1002, FR-029): their
/// organisation's sign-in turned their access off. The client keeps its key and goes on
/// dialling, so it opens again by itself when the provider turns the person on. The same on
/// the Mac and the Remote; the web page's is in `Web/src/App.tsx`.
struct SuspendedPage: View {
    /// "Mac", "iPhone", "iPad".
    let device: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .appText(.title)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(SignInWords.suspendedLine)
                .appText(.title)
                .multilineTextAlignment(.center)
            Text(SignInWords.suspendedFoot(device))
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .combine)
    }
}
