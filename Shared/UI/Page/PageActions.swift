import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
/// A picture, as each platform draws one.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// What a live page needs from the app it is in (034).
///
/// The page is one view on both devices. Where it has to touch the world, it comes
/// through here, the way the shared chat rows reach the world through `ChatActions`:
/// the Mac saves through its model and reads pictures off its own disk; a phone does
/// both by asking the Mac. The page decides nothing differently for either.
struct PageActions {
    /// Hand the whole document to the daemon to write. Answers why it did not, or nil.
    var save: @MainActor (_ path: String, _ document: String) async -> String?
    /// A picture beside the document, or nil to show its alternative text.
    var image: @MainActor (URL) async -> PlatformImage?
    /// What a picture's file is now, so a redrawn one is noticed (022 FR-020).
    var stamp: ImageStamps.Look
    /// Whether typing is possible now. A phone whose Mac has gone quiet says no, and
    /// the page keeps what is typed but takes no more (034 FR-028).
    var canEdit: Bool
    /// Told when a passage opens for typing and when it closes, so an agent asking to be
    /// looked at waits rather than taking the screen (034 FR-005).
    var typing: @MainActor (Bool) -> Void = { _ in }

    init(save: @escaping @MainActor (String, String) async -> String? = { _, _ in
             "Nothing here can save this page."
         },
         image: @escaping @MainActor (URL) async -> PlatformImage? = { _ in nil },
         stamp: @escaping ImageStamps.Look = { _ in nil },
         canEdit: Bool = false) {
        self.save = save
        self.image = image
        self.stamp = stamp
        self.canEdit = canEdit
    }
}

extension EnvironmentValues {
    @Entry var pageActions = PageActions()
}
