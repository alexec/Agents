import AgentsKitCore
import SwiftUI

/// A question from the agent that wants a particular shape of answer, on the phone.
///
/// The daemon has held these since 003 and only the Mac could ever answer one. That is
/// the wrong way round for the question channel this app is proudest of: the whole claim
/// is that a question reaches you wherever you are, and "wherever you are" was a desk.
///
/// Built on `PermissionSheet` rather than on the Mac's `ElicitationView`, deliberately.
/// What a phone is good at is the case that actually arrives — one question, a few
/// answers, one tap — which is what this app's own question tool sends and what every
/// runtime raising a choice sends. So that case gets the whole screen and one tap.
/// Anything more — several questions, text, a number, a list to tick — is paged one
/// question at a time by `FormPages`, the way the Mac pages it.
struct ElicitationSheet: View {
    @Environment(RemoteModel.self) private var model
    let request: ElicitationRequest

    /// What was tapped, while the answer is in flight — the same guard against a second
    /// tap that `PermissionSheet` makes, and for the same reason.
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .appText(.reading).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                // The question itself often lives here rather than in the schema: a
                // one-question form arrives with an untitled field and the whole
                // question in `message`.
                if let message = request.message, message != request.title {
                    Text(message)
                        .appText(.reading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let chosen {
                Sending(what: chosen)
            } else {
                answers
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .readableWidth()
        .animation(.snappy(duration: 0.2), value: chosen)
    }

    @ViewBuilder
    private var answers: some View {
        switch request.mode {
        case .form(let schema):
            if let choice = Self.oneTapChoice(in: schema) {
                oneTap(schema, choice)
            } else {
                FormPages(request: request, schema: schema) { what, action, content in
                    send(what, action: action, content: content)
                }
                .disabled(model.isStale)
            }
        case .url(let link):
            page(link)
        }
    }

    /// The one question this form is really asking, when it is only asking one.
    ///
    /// Deliberately more generous than `ElicitationSchema.singleChoice`, which wants a
    /// schema of exactly one property. The elicitation that actually arrives here is
    /// this app's own question tool's, and it sends *two*: `question_0` for the choices
    /// and an optional `question_0_custom` for a free-text "Other". Held to one property,
    /// the commonest question in the app would fall through to "this wants your Mac",
    /// which is the opposite of the point.
    ///
    /// So: one page — `pages` is what groups a note with the question it belongs to —
    /// a first property offering choices, and nothing else on the form that has to be
    /// filled in. The free text is what gets given up by answering from a phone, and
    /// giving up an optional box to answer in one tap is the trade this screen is for.
    static func oneTapChoice(in schema: ElicitationSchema)
        -> (property: ElicitationSchema.Property, choices: [ElicitationSchema.Property.Choice])? {
        guard schema.pages.count == 1, let asked = schema.pages[0].first,
              case .string(_, _, _, let choices) = asked.kind,
              let choices, !choices.isEmpty,
              // Anything else that must be answered cannot be, from here.
              !schema.properties.contains(where: { $0.name != asked.name && $0.isRequired })
        else { return nil }
        return (asked, choices)
    }

    /// One question, the agent's own answers, one tap each.
    ///
    /// Stacked rather than in a row, which is the rule `PermissionSheet` already
    /// follows: three buttons across a phone at the largest Dynamic Type sizes are
    /// three truncated words, and an answer nobody can read is one nobody can give.
    private func oneTap(_ schema: ElicitationSchema,
                        _ single: (property: ElicitationSchema.Property,
                                   choices: [ElicitationSchema.Property.Choice])) -> some View {
        VStack(spacing: 8) {
            if let description = schema.description {
                Text(description)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(single.choices) { choice in
                Button {
                    send(choice.title, action: .accept,
                         content: [single.property.name: .string(choice.value)])
                } label: {
                    label(choice.title, note: choice.description, onFill: true)
                }
                .buttonStyle(.paperProminent)
                .controlSize(.large)
            }
            // Answering with nothing, where the agent said the question may go
            // unanswered. Not the same as declining, and the daemon tells them apart.
            if !single.property.isRequired {
                Button {
                    send("No answer", action: .accept,
                         content: [single.property.name: .string("")])
                } label: {
                    label("No answer", note: nil)
                }
                .buttonStyle(.paper)
                .controlSize(.large)
            }
            declineButton
        }
        .disabled(model.isStale)
    }

    /// Go and look at something, then say how it went.
    private func page(_ link: String) -> some View {
        VStack(spacing: 8) {
            if let url = URL(string: link) {
                Link(destination: url) { label("Open", note: link, onFill: true) }
                    .buttonStyle(.paperProminent)
                    .controlSize(.large)
            }
            Button { send("Done", action: .accept) } label: { label("Done", note: nil) }
                .buttonStyle(.paper)
                .controlSize(.large)
            declineButton
        }
        .disabled(model.isStale)
    }

    private var declineButton: some View {
        Button { send("No thanks", action: .decline) } label: { label("No thanks", note: nil) }
            .buttonStyle(.paper)
            .controlSize(.large)
    }

    private func label(_ title: String, note: String?, onFill: Bool = false) -> some View {
        AnswerLabel(title: title, note: note, onFill: onFill)
    }

    private func send(_ what: String,
                      action: DaemonAPI.AnswerElicitationRequest.Action,
                      content: [String: JSONValue] = [:]) {
        chosen = what
        Task {
            // Left showing what was sent. What becomes of it arrives as the daemon
            // withdrawing the question, which takes this whole view away. An answer
            // that did not go gives the buttons back, so it can be given again.
            if !(await model.answer(request, action: action, content: content)) { chosen = nil }
        }
    }
}

/// What was sent, where the buttons were. Never a second answer.
private struct Sending: View {
    let what: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("\(what) — telling your Mac")
                .appText(.reading)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}
