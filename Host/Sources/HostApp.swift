import SwiftUI

/// Agents Host (058, US2): the app from us that isn't in the App Store, because it runs
/// programs for the person's agents. One window (frame L) and a menu bar item; the work
/// itself is in launch agents that keep running with the app closed.
///
/// The same program is the control plane's launcher: started by launchd with
/// `--launch-control`, it hands the key over and becomes `agents-control`.
@main
enum HostEntry {
    static func main() {
        if CommandLine.arguments.contains(ControlLauncher.argument) { ControlLauncher.run() }
        // With no window server to reach (an agent's sandbox, ssh, a launchd job outside
        // the login session), AppKit aborts in _RegisterApplication (#505): say why and stop.
        guard CGSessionCopyCurrentDictionary() != nil else {
            FileHandle.standardError.write(Data("Agents Host: no window server to draw on (a sandbox, ssh or no login session); start it from the logged-in desktop.\n".utf8))
            exit(78) // EX_CONFIG
        }
        AgentsHostApp.main()
    }
}

/// agents-host://pair, from the App Store window's K2: show a code. A `Window` scene is
/// never handed a URL by `onOpenURL`, so the app delegate takes it.
final class HostDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var opened: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach { Self.opened?($0) } }
    }
}

struct AgentsHostApp: App {
    @NSApplicationDelegateAdaptor(HostDelegate.self) private var delegate
    @State private var model = HostModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Agents Host", id: "host") {
            HostWindow()
                .environment(model)
                .onAppear {
                    HostDelegate.opened = { [model] url in
                        if url.host == "pair", model.settings.role == .runHere { model.showingPairing = true }
                    }
                }
        }
        .defaultSize(width: 680, height: 640)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Agents Host", systemImage: "point.3.connected.trianglepath.dotted") {
            Button("Open Agents Host") {
                openWindow(id: "host")
                NSApp.activate()
            }
            if model.settings.role == .runHere {
                Button("Pair a Window or Phone…") {
                    openWindow(id: "host")
                    NSApp.activate()
                    model.showingPairing = true
                }
                // The page in a browser on this Mac, paired the first time (#109); why not,
                // in the window.
                Button("Open in Browser") {
                    Task {
                        await model.openInBrowser()
                        if model.problem != nil {
                            openWindow(id: "host")
                            NSApp.activate()
                        }
                    }
                }
            }
            Divider()
            Button("Quit Agents Host") { NSApp.terminate(nil) }
            Text("Your agents keep running after quitting.").font(.caption)
        }
    }
}
