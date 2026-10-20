import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the Simulator pane asks of the session's host (#842). Each app says where that goes.
struct SimulatorCalls {
    var list: @MainActor () async throws -> DaemonAPI.SimulatorList
    var boot: @MainActor (String) async throws -> Void
    var shutdown: @MainActor (String) async throws -> Void
    /// A booted simulator's screen, at most `maxHeight` pixels tall.
    var screen: @MainActor (_ udid: String, _ maxHeight: Int) async throws -> DaemonAPI.SimulatorScreen
    /// A touch at x and y, from 0 to 1 across and down, and the Home button.
    var tap: @MainActor (String, Double, Double) async throws -> Void
    var home: @MainActor (String) async throws -> Void
}

/// The iOS Simulator pane (#842): a simulator on the session's Mac, its screen shown and
/// read again each second while the pane is on screen and its window can be seen. Booting and shutting down are the
/// person's press only. A click or a tap on the screen is a touch there; Home is its button.
struct SimulatorPaneView: View {
    let calls: SimulatorCalls
    /// Whether the pane is on screen. The screen is asked for only then.
    var isVisible = true

    @State private var list: DaemonAPI.SimulatorList?
    @State private var chosen: String?
    @State private var screen: DaemonAPI.SimulatorScreen?
    @State private var problem: String?
    @State private var busy = false
    /// How big the screen is drawn, for where a touch lands on it.
    @State private var shown: CGSize = .zero
    /// Counts touches, so the screen is read again at once after one.
    @State private var touches = 0
    /// How tall the screen can be drawn, in points: the screen is asked for at that size (#1650).
    @State private var room: CGFloat = 0
    /// Whether the pane's window can be seen: not minimised, not covered, not in the background.
    @State private var windowVisible = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    /// The screen is read only while someone can see it (#1650).
    private var reading: Bool { isVisible && windowVisible && scenePhase != .background }

    /// The height to ask for: the room in pixels, up in steps of 100, so a resize asks again
    /// only when it matters. The host keeps it at most 1200.
    private var maxHeight: Int {
        max(100, Int((room * displayScale / 100).rounded(.up)) * 100)
    }

    private var simulator: DaemonAPI.Simulator? {
        list?.simulators.first { $0.udid == chosen } ?? list?.simulators.first
    }

    var body: some View {
        VStack(spacing: 10) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { room = $0 }
            if let problem {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        #if os(macOS)
        .background(WindowOcclusion(visible: $windowVisible))
        #endif
        .task { await reload() }
        // Read again each second, while seen and booted, and never two at once.
        .task(id: "\(reading)-\(simulator?.udid ?? "")-\(simulator?.booted == true)-\(touches)") {
            guard reading, let simulator, simulator.booted else {
                if simulator?.booted != true { screen = nil }
                return
            }
            while !Task.isCancelled {
                do {
                    screen = try await calls.screen(simulator.udid, maxHeight)
                    problem = nil
                } catch {
                    problem = describe(error)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if let list, !list.simulators.isEmpty {
                Picker("Simulator", selection: Binding(get: { simulator?.udid ?? "" }, set: { chosen = $0 })) {
                    ForEach(list.simulators) { sim in
                        Text("\(sim.name) · \(sim.os)\(sim.booted ? "" : " · Shut Down")").tag(sim.udid)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let simulator {
                if simulator.booted {
                    Button {
                        touch { try await calls.home(simulator.udid) }
                    } label: {
                        Image(systemName: "circle.circle")
                    }
                    .help("Home")
                    .accessibilityLabel("Home")
                }
                Button(simulator.booted ? "Shut Down" : "Boot") { toggle(simulator) }
                    .disabled(busy)
            }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("List the simulators again")
            .accessibilityLabel("List the simulators again")
        }
        .appText(.supporting)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var content: some View {
        if list == nil {
            ProgressView().controlSize(.small)
        } else if let simulator {
            if simulator.booted, let screen, let image = Self.image(screen.jpeg) {
                image
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(CGFloat(screen.width) / CGFloat(max(screen.height, 1)), contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary) }
                    .onGeometryChange(for: CGSize.self, of: \.size) { shown = $0 }
                    // A touch where it was clicked or tapped, as a share of the screen.
                    .onTapGesture { point in
                        guard shown.width > 0, shown.height > 0 else { return }
                        let x = min(max(point.x / shown.width, 0), 1)
                        let y = min(max(point.y / shown.height, 0), 1)
                        touch { try await calls.tap(simulator.udid, x, y) }
                    }
                    .accessibilityLabel("The screen of \(simulator.name)")
                    .accessibilityHint("A tap here is a tap on the simulator")
            } else if simulator.booted {
                ProgressView().controlSize(.small)
            } else {
                Text("\(simulator.name) is shut down. Boot it to see its screen.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            Text(list?.reason ?? "This Mac has no iOS simulators. Make one in Xcode.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// A touch or Home, then the screen read again at once to show what it did.
    private func touch(_ send: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await send()
                problem = nil
                try? await Task.sleep(for: .milliseconds(250))
                touches += 1
            } catch {
                problem = describe(error)
            }
        }
    }

    private func reload() async {
        do {
            list = try await calls.list()
            problem = nil
        } catch {
            list = DaemonAPI.SimulatorList(simulators: [])
            problem = describe(error)
        }
    }

    private func toggle(_ simulator: DaemonAPI.Simulator) {
        busy = true
        Task {
            do {
                if simulator.booted { try await calls.shutdown(simulator.udid) } else { try await calls.boot(simulator.udid) }
                problem = nil
            } catch {
                problem = describe(error)
            }
            chosen = simulator.udid
            await reload()
            busy = false
        }
    }

    private func describe(_ error: any Error) -> String {
        (error as? JSONRPCError)?.message ?? error.localizedDescription
    }

    private static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

#if os(macOS)
/// Says whether the window that holds it can be seen: a minimised or covered window cannot (#1650).
private struct WindowOcclusion: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Watcher { Watcher(visible: $visible) }
    func updateNSView(_ view: Watcher, context: Context) { view.visible = $visible }

    final class Watcher: NSView {
        var visible: Binding<Bool>
        private var observer: NSObjectProtocol?

        init(visible: Binding<Bool>) {
            self.visible = visible
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// The observer goes when the view leaves its window, and holds the view weakly.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            update()
        }

        private func update() {
            let seen = window?.occlusionState.contains(.visible) ?? true
            if visible.wrappedValue != seen { visible.wrappedValue = seen }
        }
    }
}
#endif
