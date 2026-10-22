import AgentsKitCore
import SwiftUI

/// A machine that asks to join the control plane with no code (#994, spec 736 FR-017),
/// waiting for this person's approval: its name, who it is to belong to, the code it
/// shows, and Approve / Deny. At the top of the sidebar on the Mac and the Remote, so it
/// is seen without opening Settings; the web page's is `Web/src/views/JoinRequest.tsx`.
struct JoinRequestCard: View {
    let request: DaemonAPI.JoinRequest
    /// This person's user id, so a machine for them says "as you".
    let you: String?
    /// Answered from here and not decided yet.
    let isAnswering: Bool
    let answer: (_ approve: Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "desktopcomputer")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(StateTint.attention.style(or: .primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(request.name).fontWeight(.semibold)) \(PeopleWords.joinWants(request, you: you))")
                    .fixedSize(horizontal: false, vertical: true)
                Text(PeopleWords.platform(request.platform))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                // The code once, in the code face, as the machine prints it.
                Text("Check that the machine shows \(Text(request.code).monospaced().fontWeight(.semibold)).")
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    // One element, so the label does not stack on the selectable Text's (#1724).
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(PeopleWords.joinCode(request))
                HStack(spacing: 8) {
                    Button("Approve") { answer(true) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny") { answer(false) }
                        .buttonStyle(.bordered)
                    if isAnswering { ProgressView().controlSize(.small) }
                }
                .cardButtons()
                .disabled(isAnswering)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PeopleWords.joinTitle(request, you: you))
    }
}
