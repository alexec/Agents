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
                        .buttonStyle(.paperProminent)
                case .compare:
                    Button("Approve", action: approve)
                        .buttonStyle(.paperProminent)
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
/// their devices, and shows the digits to compare once that device sent its nonce. With no
/// other device left, Use Recovery Key adds it with the key the person kept, and Start a New
/// Lock, with no key either, starts the lock again (#3493, D4).
struct ThisDeviceLockCard: View {
    let place: LockState.Place
    let isBusy: Bool
    let askAgain: () -> Void
    let useRecovery: (String) async -> String?
    let startNewLock: () -> Void
    @State private var recovering = false
    @State private var typed = ""
    @State private var failure: String?
    @State private var confirmsNewLock = false

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
                recovery
            case .asking:
                Text(LockWords.openOther).fixedSize(horizontal: false, vertical: true)
                recovery
            case .ended:
                HStack(spacing: 8) {
                    if !recovering {
                        Button(LockWords.useRecovery) { recovering = true }
                            .buttonStyle(.bordered)
                    }
                    Button(LockWords.askAgain, action: askAgain)
                        .buttonStyle(.bordered)
                }
                .cardButtons()
                .padding(.top, 2)
                if recovering { form }
            case .broken, .member, .unknown:
                EmptyView()
            }
        }
        .confirmationDialog(LockWords.newLockTitle, isPresented: $confirmsNewLock, titleVisibility: .visible) {
            Button(LockWords.startNewLock, role: .destructive, action: startNewLock)
        } message: {
            Text(LockWords.newLockMessage)
        }
    }

    @ViewBuilder private var recovery: some View {
        if recovering {
            form
        } else {
            Button(LockWords.useRecovery) { recovering = true }
                .buttonStyle(.bordered)
                .cardButtons()
                .padding(.top, 2)
        }
    }

    /// The field for the recovery key, and its buttons.
    private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(LockWords.typeRecovery, text: $typed)
                .textFieldStyle(.roundedBorder)
                .monospaced()
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
                .onSubmit(use)
            if let failure {
                Text(failure)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(LockWords.use, action: use)
                    .buttonStyle(.paperProminent)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") {
                    recovering = false
                    failure = nil
                }
                .buttonStyle(.bordered)
                Button(LockWords.startNewLock) { confirmsNewLock = true }
                    .buttonStyle(.bordered)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .cardButtons()
            .disabled(isBusy)
        }
        .padding(.top, 2)
    }

    private func use() {
        let text = typed
        Task { failure = await useRecovery(text) }
    }

    private var title: String {
        switch place {
        case .ended(let denied): denied ? LockWords.denied : LockWords.expired
        case .broken(let failure): failure.isFork ? LockWords.forked : LockWords.broken(failure.why)
        default: LockWords.thisDevice
        }
    }
}

/// The recovery key on a device in the lock (#3493, D4): shown once after it is made, to keep
/// in a password manager; or an offer to make one while this is the lock's only client and it has
/// a machine other than this Mac's own host (#4248). The web
/// page's is `RecoveryKeyCard` in `Web/src/views/LockJoins.tsx`.
struct RecoveryKeyCard: View {
    let card: LockState.RecoveryCard
    let isBusy: Bool
    let make: () -> Void
    let dismiss: () -> Void
    @State private var copied = false

    var body: some View {
        switch card {
        case .none:
            EmptyView()
        case .offer:
            LockCardFrame(label: LockWords.makeRecovery) {
                Text(LockWords.makeRecovery).fontWeight(.semibold)
                Text(LockWords.recoveryWhy).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(LockWords.makeRecoveryButton, action: make)
                        .buttonStyle(.paperProminent)
                    Button(LockWords.skip, action: dismiss)
                        .buttonStyle(.bordered)
                    if isBusy { ProgressView().controlSize(.small) }
                }
                .cardButtons()
                .disabled(isBusy)
                .padding(.top, 2)
            }
        case .show(let text):
            LockCardFrame(label: LockWords.saveRecovery) {
                Text(LockWords.saveRecovery).fontWeight(.semibold)
                Text(text)
                    .monospaced()
                    .fontWeight(.semibold)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LockWords.recoveryShownOnce).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(LockWords.savedIt, action: dismiss)
                        .buttonStyle(.paperProminent)
                    Button(copied ? "Copied" : "Copy") {
                        Clipboard.copy(text)
                        copied = true
                    }
                    .buttonStyle(.bordered)
                    Button(LockWords.skip, action: dismiss)
                        .buttonStyle(.bordered)
                }
                .cardButtons()
                .padding(.top, 2)
            }
        }
    }
}

/// The card's look, as `SignInRequestCard`'s.
private struct LockCardFrame<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(icon: "lock.shield")
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
