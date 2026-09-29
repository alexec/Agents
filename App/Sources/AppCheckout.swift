import Foundation

/// Which checkout this running app was built from. The window title leads with it,
/// so a copy built in a worktree is not mistaken for the one on main.
enum AppCheckout {
    /// `main` for the primary checkout. A linked worktree's directory name otherwise.
    /// Nil when the bundle is not inside a checkout.
    static let name: String? = locate()

    static func windowTitle(_ subject: String?) -> String {
        let base = subject.flatMap { $0.isEmpty ? nil : $0 } ?? "Agents"
        guard let name else { return base }
        return "\(name) · \(base)"
    }

    private static func locate() -> String? {
        var url = Bundle.main.bundleURL
        let files = FileManager.default
        while url.path != "/" {
            let git = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if files.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? "main" : url.lastPathComponent
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
