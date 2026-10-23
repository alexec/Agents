#if os(iOS)
import SwiftUI

/// Our own words before the system asks for the microphone and speech recognition, the
/// first time only (#427): before dictation, and before voice mode (#2444).
struct DictationPrimer: View {
    let title: String
    let what: String
    let notNow: () -> Void
    let `continue`: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(what)
                .foregroundStyle(.secondary)
            Text("iOS will ask for the microphone and for speech recognition next.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now", action: notNow)
                    .buttonStyle(.paper)
                Button("Continue", action: `continue`)
                    .buttonStyle(.paperProminent)
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }
}
#endif
