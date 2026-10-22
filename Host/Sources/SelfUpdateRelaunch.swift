import AppKit

/// Agents Host's window and menu bar item, opened again from the new copy once this Mac's
/// host has put an update in its place (#2178). The host does the update, between turns,
/// and restarts the launch agents; this process still runs the old copy, which the host
/// moved aside into `.Agents Host.update-*` beside the bundle.
@MainActor
enum SelfUpdateRelaunch {
    /// Looks every 30 seconds, for as long as the app runs.
    static func watch() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if replaced(Bundle.main.bundleURL) { relaunch(); return }
            }
        }
    }

    /// The copy at this app's path is another version, and the host's update put it there.
    /// A build made in place (DerivedData, a scratch copy) leaves no update folder, so it is
    /// never taken for one.
    static func replaced(_ app: URL, running: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) -> Bool {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let running,
              let dict = NSDictionary(contentsOf: info),
              let onDisk = dict["CFBundleShortVersionString"] as? String, onDisk != running else { return false }
        let folder = app.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix(".Agents Host.update-") }
    }

    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
