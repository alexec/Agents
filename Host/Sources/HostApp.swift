import SwiftUI

/// Agents (#4224, #4225): the window and this Mac's host in one Developer ID app, which
/// isn't in the App Store, because it runs programs for the person's agents. The window
/// and a menu bar item; the work itself is in launch agents that keep running with the app
/// closed.
///
/// The same program is the control plane's launcher: started by launchd with
/// `--launch-control`, it hands the key over and becomes `agents-control`. With
/// `--launch-daemon` it becomes this Mac's `agentsd` (#1138).
@main
enum HostEntry {
    static func main() {
        if CommandLine.arguments.contains(ControlLauncher.argument) { ControlLauncher.run() }
        if CommandLine.arguments.contains(DaemonLauncher.argument) { DaemonLauncher.run() }
        // What's wrong with the login items, for a bug report, with no window (#678).
        if CommandLine.arguments.contains(HostDiagnostics.argument) { HostDiagnostics.runFromCommandLine() }
        // ship.sh: the login items again from this copy, so launchd runs it (#4130).
        if CommandLine.arguments.contains(LocalServices.registerArgument) { LocalServices.registerFromCommandLine() }
        // With no window server to reach (an agent's sandbox, ssh, a launchd job outside
        // the login session), AppKit aborts in _RegisterApplication (#505): say why and stop.
        guard CGSessionCopyCurrentDictionary() != nil else {
            FileHandle.standardError.write(Data("Agents: no window server to draw on (a sandbox, ssh or no login session); start it from the logged-in desktop.\n".utf8))
            exit(78) // EX_CONFIG
        }
        AgentsApp.main()
    }
}

/// This Mac's host in the one app (#4225): the menu bar item, which says the agents keep
/// running with no window open. Its controls are in Settings since #4227.
struct HostScenes: Scene {
    let app: AppModel

    /// One for the app, made once: the scenes are made again on every change. None for a
    /// walk's window (run-app, `--walk`), which must not register the person's login items
    /// from a build in a checkout, nor draw a second menu bar item; unless the walk gives
    /// it a scratch root of its own (`AGENTS_ROOT`), whose jobs are that root's.
    @MainActor static let model: HostModel? = ControlConfig.walk == nil || HostPaths.current.scratch ? HostModel() : nil
    /// The first open (#4226), which the window runs while it has no control plane.
    @MainActor static let firstOpen: FirstOpen? = model.map { FirstOpen(host: $0) }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(Self.model != nil)) {
            if let model = Self.model { HostMenu(host: model, app: app) }
        } label: {
            Image("MenuBarBlob")
        }
    }
}

/// The menu bar item's menu (#4227): the window's counts, then what Agents Host's menu had.
private struct HostMenu: View {
    let host: HostModel
    let app: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(HostMenuWords.counts(working: working, needsYou: app.needsPersonCount))
        Divider()
        Button("Open Agents") {
            NSApp.activate()
            app.bringMainWindowForward(opening: openWindow)
        }
        if host.settings.role == .runHere {
            Button("Pair a Phone or iPad…") {
                app.settingsPaneAsked = .clients
                app.pairDeviceAsked = true
                showSettings()
            }
            // The page in a browser on this Mac, paired the first time (#109); why not, in
            // an alert.
            Button("Open in Browser") {
                Task {
                    await host.refresh()
                    await host.openInBrowser()
                    guard let why = host.problem else { return }
                    NSApp.activate()
                    let alert = NSAlert()
                    alert.messageText = "Agents can’t open in a browser"
                    alert.informativeText = why
                    alert.runModal()
                }
            }
        }
        Divider()
        Button("Settings…") { showSettings() }
        Button("Quit Agents") { NSApp.terminate(nil) }
        Text("Your agents keep running after quitting.").font(.caption)
    }

    /// Sessions working, in every folder, as the sidebar counts them.
    private var working: Int {
        app.liveFolders.reduce(0) { $0 + (app.counts(in: $1.key)[.running] ?? 0) }
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}

enum HostMenuWords {
    /// "2 working · 1 needs you", or that nothing is.
    static func counts(working: Int, needsYou: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        return parts.isEmpty ? "No agents working" : parts.joined(separator: " · ")
    }
}
