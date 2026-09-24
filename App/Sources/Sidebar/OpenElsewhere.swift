import AppKit
import SwiftUI

/// A file the pane will not draw, and the way out to something that will.
///
/// A PDF, an archive, a database, a picture AppKit could not decode: its bytes are never
/// shown (FR-014), so what is shown instead is the file's own icon, the kit's words for
/// it, and a button named for the app the Mac would open it with. "Open in Preview" is a
/// button the reader can predict; "Open" is one they have to try. When no app on this
/// Mac claims the file, the button is not drawn at all, because a button that cannot do
/// what it says is worse than none, and Finder is still offered.
struct OpenElsewhere: View {
    let url: URL
    let description: String

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 64, height: 64)
            Text(url.lastPathComponent)
                .appText(.reading).fontWeight(.semibold)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(description)
                .appText(.supporting)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let app = defaultApp {
                    Button("Open in \(app)") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 10)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The app Launch Services would hand this file to, by the name the Dock shows for
    /// it. Asked on every pass rather than cached: it is a cheap lookup, and the answer
    /// changes when the user changes it in Finder, which is exactly when a cached one
    /// would be wrong.
    private var defaultApp: String? {
        guard let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: application.path)
    }
}
