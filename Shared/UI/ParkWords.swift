import AgentsKitCore
import Foundation

/// The words and the symbol for parking, once for both apps (040, FR-018).
///
/// Which button a chat offers is `Agent.parkAction`'s to decide; this only says what
/// that button is called and what it does.
enum ParkWords {
    static let symbol = "parkingsign.circle"
    static let unparkSymbol = "arrow.uturn.backward.circle"

    static func label(_ action: ParkAction) -> String {
        switch action {
        case .park: return "Park"
        case .unpark: return "Unpark"
        }
    }

    static func symbol(_ action: ParkAction) -> String {
        switch action {
        case .park: return symbol
        case .unpark: return unparkSymbol
        }
    }

    /// The tooltip and the accessibility label: what the button does.
    static func help(_ action: ParkAction, isMarkedOnly: Bool = false) -> String {
        switch action {
        case .park: return "Put this chat down to come back to later"
        case .unpark where isMarkedOnly: return "Don't park this chat when its turn ends"
        case .unpark: return "Put this chat back where it was"
        }
    }

    /// "Parked 3 days ago", or "Parks when this turn ends", or nil for a chat that is
    /// neither.
    static func line(_ parking: Parking?) -> String? {
        switch parking {
        case .none: return nil
        case .whenTurnEnds: return "Parks when this turn ends"
        case .parked(let at):
            guard Date().timeIntervalSince(at) >= 60 else { return "Parked just now" }
            return "Parked " + at.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        }
    }
}
