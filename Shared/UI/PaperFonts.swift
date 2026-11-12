import CoreText
import Foundation

/// Paper v2's two faces (#4975; specs/4926-paper-v2/spec.md, "Fonts"): Atkinson
/// Hyperlegible Next for every word a person reads, and Atkinson Hyperlegible Mono for
/// code. Both are SIL OFL 1.1, from the Braille Institute, and live in `design/fonts/`
/// with their licence; the app carries them in its bundle's `fonts` folder.
///
/// Only the Mac draws in them so far. The Remote follows in #4992; until then its
/// `TypeScale` branch stays on the system faces, and its bundle has no `fonts` folder.
enum PaperFonts {
    /// The family names `TypeScale` asks for. A face that is not registered (a test, a
    /// preview, a bundle with no `fonts` folder) falls back to the system's, so the
    /// worst a missing file does is look like Paper v1.
    static let text = "Atkinson Hyperlegible Next"
    static let mono = "Atkinson Hyperlegible Mono"

    /// Registers the faces for this process, once, before the first window draws.
    /// Process scope: nothing is installed on the Mac, and nothing outlives the app.
    static func register(from bundle: Bundle = .main) {
        guard !registered else { return }
        registered = true
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: "fonts") ?? []
        for url in urls {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered is not a failure; anything else is logged once and the
                // system face stands in.
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown"
                FileHandle.standardError.write(Data("Agents: font \(url.lastPathComponent) not registered: \(reason)\n".utf8))
            }
        }
    }

    nonisolated(unsafe) private static var registered = false
}
