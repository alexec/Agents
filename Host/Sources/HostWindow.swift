import AgentsKitCore
import AppKit
import SwiftUI

/// Frame L (058, T058): the host app's one window. It says what this Mac is doing and
/// holds the choices only a machine can make: whether the control plane runs here or this
/// Mac joins one elsewhere, where the control plane keeps its store, relaying for the
/// person's devices, and the code to pair a window or phone.
struct HostWindow: View {
    @Environment(HostModel.self) private var model
    @State private var joinCode = ""
    @State private var confirmingSwitch = false
    @State private var moving = false
    @State private var movingMachine = false
    @State private var confirmingStop = false
    @State private var returning = false
    @State private var confirmingReturnStop = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if HostMove.offered(model.paths) { MoveStrip(moving: $moving) }
                thisMac
                if model.settings.role == .none {
                    firstChoice
                } else {
                    Text("CONTROL PLANE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 6)
                    controlPlane
                    if model.settings.role == .runHere {
                        Text("The keys stay in this Mac’s keychain. In a bucket, what the control plane remembers outlives this Mac, and a copy elsewhere can share it later.")
                            .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    relay
                }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Problem: \(problem)")
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showingPairing) { PairingSheet().environment(model) }
        .sheet(isPresented: $moving) { MoveSheet().environment(model) }
        .sheet(isPresented: $movingMachine) { MachineMoveSheet().environment(model) }
        .sheet(isPresented: $returning) { MachineReturnSheet().environment(model) }
        .confirmationDialog("Stop forwarding?", isPresented: $confirmingReturnStop) {
            Button("Stop Forwarding", role: .destructive) { Task { await model.stopReturnForwarding() } }
        } message: {
            Text(returnStopMessage)
        }
        .confirmationDialog("Stop forwarding?", isPresented: $confirmingStop) {
            Button("Stop Forwarding", role: .destructive) { Task { await model.stopForwarding() } }
        } message: {
            Text(stopMessage)
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Switch where the control plane keeps its store?", isPresented: $confirmingSwitch) {
            Button("Switch Store") { Task { await model.switchStore() } }
        } message: {
            Text("The control plane stops for a moment while every record is copied across. Windows, phones and hosts reconnect by themselves. The old store is kept.")
        }
    }

    // MARK: This Mac

    private var thisMac: some View {
        card {
            HStack(alignment: .center, spacing: 12) {
                Circle().fill(model.daemonRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This Mac").font(.headline)
                    Text(thisMacLine).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.settings.role == .runHere {
                    Button("Pair a Window or Phone…") { model.showingPairing = true }
                        .disabled(!model.controlRunning)
                }
            }
            .padding(16)
            if model.settings.role == .runHere {
                Divider()
                // The web remote (071 FR-002): on unless turned off, and only ever on loopback.
                // Its line says what the control plane says: never the address of a page it
                // isn't serving (071 R3).
                HStack(spacing: 12) {
                    Toggle(isOn: Binding(get: { model.settings.servesWebRemote },
                                         set: { on in Task { await model.setServeWebRemote(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Serve Agents to browsers on this Mac")
                            Text(model.webRemoteLine)
                                .font(.callout)
                                .foregroundStyle(model.webRemoteFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        }
                    }
                    .toggleStyle(.switch)
                    if model.webRemoteFailed {
                        Button("Try Again") { Task { await model.retryWebRemote() } }
                    }
                }
                .disabled(model.busy != nil)
                .padding(16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This Mac")
    }

    private var thisMacLine: String {
        guard model.daemonRunning else {
            return model.settings.role == .none ? "Not running agents yet · Agents Host \(model.version)" : "Starting… · Agents Host \(model.version)"
        }
        var parts = ["Running your agents"]
        if let working = model.working { parts.append("\(working) working") }
        if let projects = model.projects { parts.append("\(projects) project\(projects == 1 ? "" : "s")") }
        parts.append("Agents Host \(model.version)")
        return parts.joined(separator: " · ")
    }

    // MARK: Nothing chosen yet

    private var firstChoice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where should this Mac’s agents report?").font(.title3.weight(.semibold))
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Run the control plane here").font(.headline)
                    Text("This Mac runs your agents and the control plane your windows and phones connect to. It keeps running with every window closed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Run It Here") { Task { await model.runHere() } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(model.busy != nil)
                }
                .padding(16)
            }
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Join one elsewhere").font(.headline)
                    Text("You already run a control plane on another Mac or a server. Paste a host code from it: this Mac then runs only its own agents for it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    joinField
                }
                .padding(16)
            }
            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
        }
    }

    private var joinField: some View {
        HStack {
            TextField("agents-control:2:h:…", text: $joinCode).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityLabel("Host code")
            Button("Join") { Task { await model.joinElsewhere(code: joinCode) } }
                .disabled(joinCode.isEmpty || model.busy != nil)
        }
    }

    // MARK: Control plane

    private var controlPlane: some View {
        @Bindable var model = model
        return card {
            VStack(spacing: 0) {
                row {
                    Text("Where")
                    Spacer()
                    Picker("Where", selection: Binding(
                        get: { model.settings.role == .joinElsewhere ? 1 : 0 },
                        set: { chosen in
                            if chosen == 0, model.settings.role != .runHere { Task { await model.runHere() } }
                            if chosen == 1, model.settings.role != .joinElsewhere { joinCode = ""; model.problem = nil; pickingJoin = true }
                        })) {
                        Text("Run it here").tag(0)
                        Text("Join one elsewhere").tag(1)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .disabled(model.settings.movedTo != nil && model.settings.role == .joinElsewhere)
                }
                Divider()
                if model.settings.role == .joinElsewhere, let place = model.settings.movedTo, !pickingJoin {
                    movedRows(place)
                } else if model.settings.role == .runHere && !pickingJoin {
                    running
                    Divider()
                    if let place = model.settings.returnedFrom {
                        returnRow(place)
                        Divider()
                    }
                    storeRows
                } else {
                    row {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.settings.role == .joinElsewhere && !pickingJoin
                                 ? (model.daemonRunning ? "This Mac runs its agents for a control plane elsewhere." : "Joining…")
                                 : "Paste a host code from the other control plane.")
                                .font(.callout).foregroundStyle(.secondary)
                            if pickingJoin || model.settings.role != .joinElsewhere { joinField }
                        }
                    }
                }
            }
        }
    }

    @State private var pickingJoin = false

    private var running: some View {
        row {
            Circle().fill(model.controlRunning ? Color.green : Color.orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                if model.controlRunning {
                    Text("Running at \(Text(model.controlURL).font(.system(.body, design: .monospaced)))")
                } else {
                    Text(model.busy ?? "Not running")
                }
                Text(runningLine).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            // Frame O: the control plane moved off this Mac, everyone kept (T126).
            Button("Move to Another Machine…") { movingMachine = true }
                .disabled(!model.controlRunning || model.busy != nil)
            Button("Restart") { Task { await model.restartControl() } }.disabled(model.busy != nil)
        }
    }

    // MARK: Moved (frame T)

    @ViewBuilder
    private func movedRows(_ place: String) -> some View {
        row {
            Circle().fill(model.daemonRunning ? Color.green : Color.orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Joined \(Text(place).font(.system(.body, design: .monospaced)))")
                Text(movedLine).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            // Frame U: the way back (T127).
            Button("Run It Here Again…") { returning = true }.disabled(model.busy != nil)
        }
        if let until = model.settings.forwardingUntil {
            Divider()
            row {
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forwarding from \(Text(model.controlURL).font(.system(.body, design: .monospaced)))")
                    Text(forwardingLine(until)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Stop Forwarding…") { confirmingStop = true }
            }
        }
    }

    // MARK: Came back (frame Y)

    private func returnRow(_ place: String) -> some View {
        let name = URL(string: place)?.host ?? place
        return row {
            Circle().fill(model.returnForwardingDone ? Color.green : Color.orange).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                if model.returnForwardingDone {
                    Text("Everyone has heard. You can take \(name) down.")
                } else {
                    Text("\(name) forwards here\(model.settings.returnForwardingUntil.map { " until \($0.formatted(date: .long, time: .omitted))" } ?? "")")
                    Text(returnLine(name)).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if model.returnForwardingDone {
                Button("Dismiss") { model.dismissReturn() }
            } else {
                Button("Stop Forwarding…") { confirmingReturnStop = true }
            }
        }
    }

    private func returnLine(_ name: String) -> String {
        guard let left = model.returnForwarding?.stillToHear, !left.isEmpty else { return "Then you can take that machine down." }
        let names = left.map { member in
            var said = member.id == HostID.mac.rawValue ? "This Mac" : member.name
            if member.online != true, let seen = member.lastSeen {
                said += ", last connected \(seen.formatted(.relative(presentation: .named)))"
            }
            return said
        }
        return "\(left.count) still to hear: \(names.joined(separator: "; ")). Then you can take that machine down."
    }

    private var returnStopMessage: String {
        let left = model.returnForwarding?.stillToHear.map(\.name) ?? []
        guard !left.isEmpty else { return "Everyone has heard where the control plane went." }
        return "\(ListFormatter.localizedString(byJoining: left)) will need pairing again."
    }

    private var movedLine: String {
        var parts: [String] = []
        if let at = model.settings.movedAt { parts.append("moved \(at.formatted(date: .omitted, time: .shortened))") }
        parts.append("this Mac is a host there")
        return parts.joined(separator: " · ")
    }

    private func forwardingLine(_ until: Date) -> String {
        let date = "until \(until.formatted(date: .long, time: .omitted))"
        guard let status = model.forwarding else { return date }
        let left = status.stillToHear
        guard !left.isEmpty else { return "\(date) · everyone has heard" }
        let names = left.map { member in
            var name = member.id == HostID.mac.rawValue ? "This Mac" : member.name
            if member.online != true, let seen = member.lastSeen {
                name += ", last connected \(seen.formatted(.relative(presentation: .named)))"
            }
            return name
        }
        return "\(date) · \(left.count) still to hear: \(names.joined(separator: "; "))"
    }

    private var stopMessage: String {
        let left = model.forwarding?.stillToHear.map(\.name) ?? []
        guard !left.isEmpty else { return "Everyone has heard where the control plane went." }
        return "\(ListFormatter.localizedString(byJoining: left)) will need pairing again."
    }

    private var runningLine: String {
        var parts: [String] = []
        if let since = model.runningSince { parts.append("since \(since.formatted(date: .omitted, time: .shortened))") }
        if let clients = model.clients { parts.append("\(clients) client\(clients == 1 ? "" : "s")") }
        if let hosts = model.hosts { parts.append("\(hosts) host\(hosts == 1 ? "" : "s")") }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var storeRows: some View {
        @Bindable var model = model
        row {
            Text("Keeps its store")
            Spacer()
            Picker("Keeps its store", selection: $model.storeDraft) {
                Text("On this Mac").tag(StoreChoice.thisMac)
                Text("In a bucket").tag(StoreChoice.bucket)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        if model.storeDraft == .bucket {
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                field("Endpoint", text: $model.bucketDraft.endpoint, prompt: "https://s3.eu-west-2.amazonaws.com")
                field("Bucket", text: $model.bucketDraft.bucket, prompt: "my-agents")
                field("Prefix", text: $model.bucketDraft.prefix, prompt: "control")
                field("Region", text: $model.bucketDraft.region, prompt: "us-east-1")
                field("Access key", text: $model.accessKeyDraft, prompt: "")
                GridRow {
                    Text("Secret").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    SecureField("", text: $model.secretDraft).textFieldStyle(.roundedBorder).accessibilityLabel("Secret")
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack {
                        Button("Check") { Task { await model.checkBucket() } }
                            .disabled(!model.bucketDraft.isComplete || model.check == .checking)
                        checkLine
                        Spacer()
                        switchButton
                    }
                }
            }
            .padding(16)
        } else if !model.storeIsSaved {
            Divider()
            row { Spacer(); switchButton }
        }
    }

    private var switchButton: some View {
        Button("Switch Store…") { confirmingSwitch = true }
            .buttonStyle(.link)
            .disabled(model.storeIsSaved || model.busy != nil || (model.storeDraft == .bucket && model.check != .works))
    }

    @ViewBuilder
    private var checkLine: some View {
        switch model.check {
        case .checking?: ProgressView().controlSize(.small)
        case .works?: Label("Works, with safe concurrent writes", systemImage: "checkmark").foregroundStyle(.green)
        case .failed(let why)?: Text(why).foregroundStyle(.red).lineLimit(2).help(why)
        case nil: EmptyView()
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            TextField(label, text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder).labelsHidden()
                .accessibilityLabel(label)
        }
    }

    // MARK: Relay

    private var relay: some View {
        card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Relay for my devices").font(.headline)
                    Text("Your iPhone and iPad reach your agents through your iCloud when away, and are told when an agent needs you. Not in this build yet.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Relay for my devices", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).disabled(true)
            }
            .padding(16)
        }
    }

    // MARK: Pieces

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.2)) }
    }

    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) { content() }
            .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// The code to pair a window or phone (frame L's *Pair a Window or Phone…*, and K2's Pair).
struct PairingSheet: View {
    @Environment(HostModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair a Window or Phone").font(.title3.weight(.semibold))
            Picker("For", selection: $model.pairingTarget) {
                Text("A window on a Mac").tag(HostModel.PairingTarget.window)
                Text("An iPhone or iPad").tag(HostModel.PairingTarget.phone)
                Text("A browser on this Mac").tag(HostModel.PairingTarget.browser)
            }
            .pickerStyle(.segmented)
            .onChange(of: model.pairingTarget) { Task { await model.makeCode() } }
            if let code = model.pairing {
                if code.target == .phone {
                    // What the Remote's Scan the Code reads; the text below is for Paste.
                    QRCode(text: code.text)
                        .frame(width: 220, height: 220)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Pairing code to scan")
                }
                Text(code.text)
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Pairing code")
                Text(instructions(for: code))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.pairing?.text ?? "", forType: .string)
                }
                .disabled(model.pairing == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.makeCode() }
    }

    private func instructions(for code: HostModel.PairingCode) -> String {
        switch code.target {
        case .window:
            "Paste it into Agents under Connect to a control plane. It works once, for five minutes, and lets that window do everything."
        case .phone:
            "In Agents on the iPhone or iPad, tap Scan the Code and point it at this, or copy the text and tap Paste there. It works once, for five minutes, and lets that device do everything."
        case .browser:
            "Paste it into Agents in a browser on this Mac, at localhost. It works once, for five minutes, and lets that browser do everything."
        }
    }
}
