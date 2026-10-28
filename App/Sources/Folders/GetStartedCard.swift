import AgentsKitCore
import SwiftUI

/// The top of the sidebar for a newcomer (#982): from a fresh install to a first agent at
/// work, and on to a paired phone or browser. It blocks nothing, ticks each step from
/// what is really so, and goes once every step is done or it is dismissed.
///
/// Before pairing, the window shows `FirstRunView` and nothing else, so the first step
/// is always ticked here: it says how far the person has come.
struct GetStartedCard: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Binding var isChoosingFolder: Bool
    /// Its own view of the control plane, for its list of clients: held only while the
    /// card shows, as File ▸ Add a Machine… holds one only while its sheet is open.
    @State private var control: ControlSettingsModel?
    @State private var pairingDevice = false

    private var pairedDevice: Bool {
        control?.clients.contains(where: GetStarted.isDeviceOrBrowser) == true
    }

    var body: some View {
        let facts = model.getStartedFacts(pairedDevice: pairedDevice)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Get started").fontWeight(.semibold)
                Text("\(facts.doneCount) of \(GetStarted.Step.allCases.count)")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 0)
                Button {
                    model.dismissGetStarted()
                } label: {
                    Image(systemName: "xmark")
                        // Decorative: the button's label is said below.
                        .glyph(size: 10, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss Get started")
                .accessibilityLabel("Dismiss Get started")
            }
            ForEach(GetStarted.Step.allCases) { step in
                ChecklistRow(title: step.title, how: step.how, isDone: facts.isDone(step)) {
                    action(for: step)
                }
            }
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Get started")
        .onChange(of: facts) { _, now in model.reweighGetStarted(pairedDevice: now.pairedDevice) }
        .task {
            guard control == nil, let endpoint = ControlConfig.endpoint,
                  let made = ControlSettingsModel(endpoint: endpoint) else { return }
            control = made
            await made.start()
        }
        .onDisappear {
            control?.stop()
            control = nil
        }
        .sheet(isPresented: $pairingDevice) {
            if let control { PairDeviceSheet(control: control) }
        }
    }

    @ViewBuilder private func action(for step: GetStarted.Step) -> some View {
        switch step {
        case .host:
            // Always ticked here: before pairing, the window is `FirstRunView`.
            EmptyView()
        case .runtime:
            Button("Install") { model.isOfferingInstall = true }
                .buttonStyle(.paper)
                .help("Install an agent runtime on this Mac")
        case .folder:
            Button("Add Folder…") { isChoosingFolder = true }
                .buttonStyle(.paper)
        case .firstAgent:
            Button("New Agent") { newAgent() }
                .buttonStyle(.paper)
                .disabled(model.newSessionFolder == nil)
        case .device:
            Button("Pair a Device…") { pairingDevice = true }
                .buttonStyle(.paper)
                .disabled(control == nil)
        }
    }

    /// As the sidebar's New Session row does: the new session page of the folder last
    /// started in, with the prompt ready to type in.
    private func newAgent() {
        guard let folder = model.newSessionFolder else { return }
        model.showFolder(folder)
        requests.focusPrompt()
    }
}
