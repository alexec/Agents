import SwiftUI

/// Agents (#4224, #4225): the window and this Mac's host in one Developer ID app, which
/// isn't in the App Store, because it runs programs for the person's agents. The window,
/// the host's window (frame L, until #4227 moves its controls into Settings) and a menu bar
/// item; the work itself is in launch agents that keep running with the app closed.
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

/// This Mac's host in the one app (#4225): its window, and the menu bar item that says the
/// agents keep running with no window open.
struct HostScenes: Scene {
    static let windowID = "host"

    /// One for the app, made once: the scenes are made again on every change. None for a
    /// walk's window (run-app, `--walk`), which must not register the person's login items
    /// from a build in a checkout, nor draw a second menu bar item; unless the walk gives
    /// it a scratch root of its own (`AGENTS_ROOT`), whose jobs are that root's.
    @MainActor static let model: HostModel? = ControlConfig.walk == nil || HostPaths.current.scratch ? HostModel() : nil
    /// The first open (#4226), which the window runs while it has no control plane.
    @MainActor static let firstOpen: FirstOpen? = model.map { FirstOpen(host: $0) }

    var body: some Scene {
        Window("This Mac's Host", id: Self.windowID) {
            if let model = Self.model {
                HostWindow()
                    .environment(model)
            }
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)
        // The window opens with the app, not this one: the menu bar item or
        // agents-host://pair brings it.
        .defaultLaunchBehavior(.suppressed)

        MenuBarExtra(isInserted: .constant(Self.model != nil)) {
            if let model = Self.model { HostMenu(model: model) }
        } label: {
            // Always drawn, so it is what opens the host's window when asked to, from
            // anywhere: no view of that window is there to do it.
            if let model = Self.model { HostMenuLabel(model: model) }
        }
    }
}

/// The menu bar mark, and what opens the host's window for agents-host://pair.
private struct HostMenuLabel: View {
    let model: HostModel
    @Environment(\.openWindow) private var openWindow
    @State private var asked = false

    var body: some View {
        Image("MenuBarBlob")
            .task {
                AgentsAppDelegate.opened = { [model] url in
                    guard url.host == "pair" else { return }
                    asked = true
                    if model.settings.role == .runHere { model.showingPairing = true }
                }
            }
            .onChange(of: asked) {
                guard asked else { return }
                asked = false
                openWindow(id: HostScenes.windowID)
                NSApp.activate()
            }
    }
}

private struct HostMenu: View {
    let model: HostModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The window opens from the Dock and the Window menu; #4227 adds Open Agents here.
        Button("Open This Mac's Host") { openHost() }
        if model.settings.role == .runHere {
            Button("Pair a Window or Phone…") {
                openHost()
                model.showingPairing = true
            }
            // The page in a browser on this Mac, paired the first time (#109); why not,
            // in the window.
            Button("Open in Browser") {
                Task {
                    await model.openInBrowser()
                    if model.problem != nil { openHost() }
                }
            }
        }
        Divider()
        Button("Quit Agents") { NSApp.terminate(nil) }
        Text("Your agents keep running after quitting.").font(.caption)
    }

    private func openHost() {
        openWindow(id: HostScenes.windowID)
        NSApp.activate()
    }
}
