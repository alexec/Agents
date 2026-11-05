import AgentsKitCore
import SwiftUI

/// Another of the person's clients asks to join their machine lock (#3490, D2): Compare
/// Digits sends this device's nonce, and once the other shows its own, both screens show six
/// digits; Approve signs its addClient. A machine that asks (#3491, D3) has the same card,
/// asked as "Approve the new machine …?", and Approve signs its addMachine. At the top of the
/// sidebar on the Mac and the Remote, beside the sign-in cards; the web page's is
/// `Web/src/views/LockJoins.tsx`.
struct LockJoinCard: View {
    let request: DaemonAPI.LockJoinRequest
    let step: LockState.Step
    /// Answered from here and not decided yet.
    let isAnswering: Bool
    let failure: String?
    let compare: () -> Void
    let approve: () -> Void
    let deny: () -> Void

    private var isMachine: Bool { request.machine != nil }

    var body: some View {
        LockCardFrame(label: isMachine ? LockWords.newMachine(request.name) : "\(request.name) \(LockWords.asks)") {
            Group {
                if isMachine {
                    Text("Approve the new machine \(Text(request.name).fontWeight(.semibold))?")
                } else {
                    Text("\(Text(request.name).fontWeight(.semibold)) \(LockWords.asks)")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            line
            if let failure {
                Text(failure)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                switch step {
                case .waiting:
                    Button(LockWords.compare, action: compare)
                        .buttonStyle(.borderedProminent)
                case .compare:
                    Button("Approve", action: approve)
                        .buttonStyle(.borderedProminent)
                case .elsewhere, .revealing, .mismatch:
                    EmptyView()
                }
                Button("Deny", action: deny)
                    .buttonStyle(.bordered)
                if isAnswering { ProgressView().controlSize(.small) }
            }
            .cardButtons()
            .disabled(isAnswering)
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var line: some View {
        switch step {
        case .waiting:
            Text(isMachine ? LockWords.compareMachine : LockWords.compareFirst).fixedSize(horizontal: false, vertical: true)
        case .elsewhere:
            Text(LockWords.elsewhere).fixedSize(horizontal: false, vertical: true)
        case .revealing:
            Text(LockWords.revealing(request.name)).fixedSize(horizontal: false, vertical: true)
        case .mismatch:
            Text(LockWords.mismatch(request.name)).fixedSize(horizontal: false, vertical: true)
        case .compare(let digits):
            // The digits in the code face, as the other screen (or the machine's log) shows them.
            let shown = Text(MachineLock.shown(digits)).monospaced().fontWeight(.semibold)
            Group {
                if isMachine {
                    Text("Approve only if the log of \(request.name) shows \(shown).")
                } else {
                    Text("Approve only if \(request.name) shows \(shown).")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isMachine ? LockWords.approveMachineOnly(request.name, digits) : LockWords.approveOnly(request.name, digits))
        }
    }
}

/// This device is not in the person's lock yet (#3490): it waits for approval on another of
/// their devices, and shows the digits to compare once that device sent its nonce.
struct ThisDeviceLockCard: View {
    let place: LockState.Place
    let askAgain: () -> Void

    var body: some View {
        LockCardFrame(label: title) {
            Text(title)
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            switch place {
            case .asking(_, let digits?):
                Text("Check that the other device shows \(Text(MachineLock.shown(digits)).monospaced().fontWeight(.semibold)), then approve it there.")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(LockWords.checkOther(digits))
            case .asking:
                Text(LockWords.openOther).fixedSize(horizontal: false, vertical: true)
            case .ended:
                Button(LockWords.askAgain, action: askAgain)
                    .buttonStyle(.bordered)
                    .cardButtons()
                    .padding(.top, 2)
            case .broken, .member, .unknown:
                EmptyView()
            }
        }
    }

    private var title: String {
        switch place {
        case .ended(let denied): denied ? LockWords.denied : LockWords.expired
        case .broken(let failure): failure.isFork ? LockWords.forked : LockWords.broken(failure.why)
        default: LockWords.thisDevice
        }
    }
}

/// The card's look, as `SignInRequestCard`'s.
private struct LockCardFrame<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.shield")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(StateTint.attention.style(or: .primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) { content }
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

extension LockState {
    /// Whether this device shows its own card: asking, ended or broken.
    var showsThisDevice: Bool {
        switch place {
        case .asking, .ended, .broken: true
        case .member, .unknown: false
        }
    }
}
