import AgentsKitCore
import SwiftUI

extension ListKey {
    /// The key with no modifier (#4796), so a row's menu and the command menu show it: `E`.
    var shortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(rawValue), modifiers: []) }
}
