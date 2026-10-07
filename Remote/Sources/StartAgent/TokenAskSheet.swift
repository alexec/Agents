import AgentsKitCore
import SwiftUI

extension View {
    /// A server's key ask (#344), the window's card, over whichever screen is in front: the
    /// start sheet while it is open, else the app itself. `shown` is false on the one
    /// behind, so the ask is never presented twice.
    func tokenAskSheet(_ model: RemoteModel, shown: Bool = true) -> some View {
        sheet(item: Binding(get: { shown ? model.tokenAsk : nil },
                            set: { if $0 == nil { model.finishTokenAsk(lent: false) } })) { ask in
            TokenAskCard(ask: ask, save: { secret in await model.lend(secret, for: ask) },
                         cancel: { model.finishTokenAsk(lent: false) })
                .paperSheet()
                .presentationDetents([.medium, .large])
        }
    }
}
