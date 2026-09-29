import SwiftUI

/// A host's name over its projects (058, frame H).
///
/// Upper case, at the fine step, which is what a section heading is. `note` sits at
/// the trailing end in sentence case — frame H's "offline" — so a list style that
/// uppercases its headers does not shout it.
struct HostListHeading: View {
    var name: String
    var note: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(name.uppercased())
                .fontWeight(.semibold)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .fontWeight(.regular)
                    .textCase(nil)
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
