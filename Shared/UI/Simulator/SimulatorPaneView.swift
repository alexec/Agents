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
    var screen: @MainActor (String) async throws -> DaemonAPI.SimulatorScreen
}

/// The iOS Simulator pane (#842): a simulator on the session's Mac, its screen shown and
/// read again each second while the pane is on screen. Booting and shutting down are the
/// person's press only. It shows the screen; it does not take taps yet.
struct SimulatorPaneView: View {
    let calls: SimulatorCalls
    /// Whether the pane is on screen. The screen is asked for only then.
    var isVisible = true

    @State private var list: DaemonAPI.SimulatorList?
    @State private var chosen: String?
    @State private var screen: DaemonAPI.SimulatorScreen?
    @State private var problem: String?
    @State private var busy = false

    private var simulator: DaemonAPI.Simulator? {
        list?.simulators.first { $0.udid == chosen } ?? list?.simulators.first
    }

    var body: some View {
        VStack(spacing: 10) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let problem {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .task { await reload() }
        // Read again each second, while on screen and booted, and never two at once.
        .task(id: "\(isVisible)-\(simulator?.udid ?? "")-\(simulator?.booted == true)") {
            guard isVisible, let simulator, simulator.booted else {
                screen = nil
                return
            }
            while !Task.isCancelled {
                do {
                    screen = try await calls.screen(simulator.udid)
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
                    .accessibilityLabel("The screen of \(simulator.name)")
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
