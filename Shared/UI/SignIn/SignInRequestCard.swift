import AgentsKitCore
import SwiftUI

/// A new client that signed in with GitHub, waiting for this person's Approve (#995, spec 736
/// FR-010): its name, the GitHub account, the code it shows, and Approve / Deny. A GitHub
/// token carries no nonce, so only the person's own client says the new one is theirs. At the
/// top of the sidebar on the Mac and the Remote, beside the machine cards; the web page's is
/// `Web/src/views/SignInRequests.tsx`. A browser that asked by an account (#2097) has no code on
/// the card: the person types the one the browser shows, so nobody approves it by habit.
struct SignInRequestCard: View {
    let request: DaemonAPI.SignInRequest
    /// Answered from here and not decided yet.
    let isAnswering: Bool
    /// Approve or Deny, with the code typed for a browser.
    let answer: (_ approve: Bool, _ code: String?) -> Void

    @State private var typed = ""

    private var typedCode: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "person.badge.key")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(StateTint.attention.style(or: .primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Text(request.name).fontWeight(.semibold)) \(SignInWords.wants)")
                    .fixedSize(horizontal: false, vertical: true)
                Text(SignInWords.account(request))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                if request.needsCode {
                    Text(SignInWords.typeCode)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(SignInWords.codePlaceholder, text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .frame(maxWidth: 160)
                        .onSubmit { if !typedCode.isEmpty { answer(true, typedCode) } }
                } else {
                    // The code once, in the code face, as the new client shows it.
                    Text("Check that it shows \(Text(request.code).monospaced().fontWeight(.semibold)).")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        // One element, so the label does not stack on the selectable Text's (#1724).
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(SignInWords.code(request))
                }
                HStack(spacing: 8) {
                    Button("Approve") { answer(true, request.needsCode ? typedCode : nil) }
                        .buttonStyle(.borderedProminent)
                        .disabled(request.needsCode && typedCode.isEmpty)
                    Button("Deny") { answer(false, nil) }
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
        .accessibilityLabel(SignInWords.title(request))
    }
}
