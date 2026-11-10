import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ This Mac ▸ Recovery key (#4299): whether the person's lock has a
/// recovery key now, and Make Recovery Key, also after the sidebar's card was skipped or before
/// it shows (#4248). The key is shown here once, in the card's words (#3493, D4). Only while this
/// Mac is in its lock. The web page's is `RecoveryKeySection` in `Web/src/views/settings/RecoveryKey.tsx`.
struct RecoveryKeySettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.lock.place == .member, let state = model.lock.checked {
            Section {
                if case .show = model.lock.recoveryCard {
                    RecoveryKeyCard(card: model.lock.recoveryCard, isBusy: model.lock.recoveryBusy,
                                    make: {}, dismiss: { model.dismissLockRecovery() })
                } else {
                    HStack(spacing: 8) {
                        Text(state.recovery == nil ? Self.none : Self.has)
                        Spacer(minLength: 0)
                        if model.lock.recoveryBusy { ProgressView().controlSize(.small) }
                        Button(LockWords.makeRecoveryButton) { Task { await model.makeLockRecovery() } }
                            .disabled(model.lock.recoveryBusy)
                    }
                }
            } header: {
                Text("Recovery key")
            } footer: {
                Text(state.recovery == nil ? LockWords.recoveryWhy : Self.replaces)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }

    static let has = "Your lock has a recovery key."
    static let none = "Your lock has no recovery key."
    static let replaces = "A new recovery key takes the old one’s place: the old one stops working."
}
