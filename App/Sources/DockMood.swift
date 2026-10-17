import AgentsKitCore
import AppKit

/// The Blob's mood on the Dock tile (#1317). The happy Blob is the bundle's icon, so
/// happy hands the tile back to it; the others are drawn by design/logo/blob/final/make.sh.
/// Finder, Launchpad and ⌘-Tab keep the bundle's icon: macOS gives the app only the Dock.
@MainActor
enum DockMood {
    static func show(_ mood: IconMood) {
        switch mood {
        case .happy: NSApp.applicationIconImage = nil
        case .asleep: NSApp.applicationIconImage = NSImage(named: "DockAsleep")
        case .quizzical: NSApp.applicationIconImage = NSImage(named: "DockQuizzical")
        }
    }
}
