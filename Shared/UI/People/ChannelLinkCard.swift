import AgentsKitCore
import SwiftUI

/// A channel identity waiting to be linked (#1762, spec 736 US7): "Link Slack user @sam
/// to you?" with Approve / Deny. For an admin, a request that names nobody has a person to
/// send it on to instead: only that person approves it. At the top of the sidebar on the
/// Mac and the Remote, beside the join card, and in Control plane ▸ Channels; the web
/// page's is `Web/src/views/ChannelLinks.tsx`.
struct ChannelLinkCard: View {
    let request: DaemonAPI.ChannelLinkRequest
    /// Whom an admin may send a request that names nobody on to.
    let people: [DaemonAPI.PersonRow]
    /// Answered from here and not decided yet.
    let isAnswering: Bool
    /// Approve (true) or Deny; with a person, Send to them.
    let answer: (_ approve: Bool, _ to: String?) -> Void

    @State private var sendTo = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: request.channel == "email" ? "envelope" : "bubble.left")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(StateTint.attention.style(or: .primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(ChannelLinkWords.ask(request))
                    .fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = ChannelLinkWords.detail(request) {
                    Text(detail)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                if request.forUser == nil {
                    Picker("Person", selection: $sendTo) {
                        Text("Choose…").tag("")
                        ForEach(people) { person in Text(person.name).tag(person.id) }
                    }
                    .pickerStyle(.menu)
                }
                HStack(spacing: 8) {
                    if request.forUser == nil {
                        Button("Send") { answer(true, sendTo) }
                            .buttonStyle(.borderedProminent)
                            .disabled(sendTo.isEmpty)
                    } else {
                        Button("Approve") { answer(true, nil) }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Deny") { answer(false, nil) }
                        .buttonStyle(.bordered)
                    if isAnswering { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                .disabled(isAnswering)
                .padding(.top, 2)
                Text(ChannelLinkWords.explanation(request))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ChannelLinkWords.ask(request))
    }
}
