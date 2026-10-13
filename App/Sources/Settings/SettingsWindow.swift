import AgentsKitCore
import AppKit
import SwiftUI

/// The Settings window (055, look/ frames A–G): one rail down the left and the chosen pane
/// beside it. It opens at one size for every pane, so choosing another never makes the
/// window jump, and it can be resized larger than that. Agent Configuration's pages are listed in the
/// rail under a heading of their own rather than in a column of their own, so there is
/// one place to choose from.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.appearance.rawValue
    @AppStorage("settingsSharedPage") private var sharedPageRaw = AgentConfigurationPage.overview.rawValue
    @AppStorage("settingsRuntimeID") private var runtimeIDRaw = RuntimeCatalog.claude.id
    /// Agent Configuration's snapshot lives here, not in its pane, because the rail shows its
    /// counts. Asked for when the window appears, when it is chosen, and whenever the app comes
    /// back to the front, which is when an edit made elsewhere shows.
    @State private var sharedSnapshot: DaemonAPI.SharedSnapshot?
    @State private var controlPage: ControlPage = .overview
    /// Settings ▸ Control plane's own view of the control plane, while the window has one
    /// (058). Without one, Devices and Servers are listed as they always were.
    @State private var control: ControlSettingsModel? = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }

    /// The size it opens at, and the smallest it will go. A larger window gives the extra
    /// room to the detail on Agent Configuration, and to the empty space beside a form pane, which
    /// stays one column.
    static let size = CGSize(width: 1_000, height: 640)

    private var pane: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: paneRaw) ?? .appearance },
            set: { paneRaw = $0.rawValue })
    }

    private var sharedPage: Binding<AgentConfigurationPage> {
        Binding(
            get: { AgentConfigurationPage(rawValue: sharedPageRaw) ?? .overview },
            set: { sharedPageRaw = $0.rawValue })
    }

    private var runtimeID: Binding<String> {
        Binding(
            get: {
                let known = Set(model.runtimes.map(\.id))
                if known.contains(runtimeIDRaw) { return runtimeIDRaw }
                return model.runtimes.first?.id ?? RuntimeCatalog.claude.id
            },
            set: { runtimeIDRaw = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsRail(pane: pane, sharedPage: sharedPage, runtimeID: runtimeID,
                         snapshot: sharedSnapshot, controlPage: $controlPage, control: control)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: Self.size.width, idealWidth: Self.size.width,
               maxWidth: .infinity,
               minHeight: Self.size.height, idealHeight: Self.size.height,
               maxHeight: .infinity)
        .background(Paper.ground)
        // Links in the accent, not macOS's link blue, as in the main window (#156).
        .tint(Paper.accent)
        // The Settings scene draws a window with no grow box, and ignores
        // windowResizability, so the mask is set on the window itself.
        .background(SettingsGrowBox())
        .navigationTitle(pane.wrappedValue.title)
        .navigationTitle(title)
        .task {
            await model.refreshRuntimes()
            await refreshShared()
        }
        .task { await control?.start() }
        .onDisappear { control?.stop() }
        // Forget This Mac (#344) leaves no control plane to show; a new pairing brings one.
        .onChange(of: model.needsFirstRun) { _, unpaired in
            control?.stop()
            control = unpaired ? nil : ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
            if unpaired, pane.wrappedValue == .controlPlane { pane.wrappedValue = .appearance }
            if let control { Task { await control.start() } }
        }
        // Asked for from elsewhere in the app: a link that names a Settings pane.
        .onChange(of: model.settingsPaneAsked, initial: true) { _, asked in
            guard let asked else { return }
            pane.wrappedValue = asked
            model.settingsPaneAsked = nil
        }
        .onChange(of: pane.wrappedValue) { _, chosen in
            if chosen == .agentConfiguration { Task { await refreshShared() } }
            if chosen == .runtimes { Task { await model.refreshRuntimes() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshShared()
                if pane.wrappedValue == .runtimes { await model.refreshRuntimes() }
            }
        }
    }

    private var title: String {
        guard pane.wrappedValue == .runtimes else { return pane.wrappedValue.title }
        return model.runtimes.first { $0.id == runtimeID.wrappedValue }?.runtime.name
            ?? SettingsPane.runtimes.title
    }

    @ViewBuilder
    private var content: some View {
        switch pane.wrappedValue {
        case .appearance: FormColumn { Form { AppearanceSettingsView() }.paperForm() }
        case .sidebar: FormColumn { Form { SidebarSettingsSection() }.paperForm() }
        case .account: FormColumn { AccountSettingsView() }
        case .mac: FormColumn { MacSettingsView() }
        case .runtimes: FormColumn { AgentRuntimesSettingsView(runtimeID: runtimeID.wrappedValue) }
        case .agentConfiguration: AgentConfigurationView(place: .you, snapshot: sharedSnapshot, page: sharedPage, refresh: { await refreshShared() })
        case .spending: FormColumn { CostSettingsView() }
        case .resources: FormColumn { ResourcesSettingsView() }
        case .controlPlane:
            if let control { ControlSettingsView(control: control, page: $controlPage) }
        }
    }

    private func refreshShared() async {
        if let fresh = await model.sharedSnapshot() { sharedSnapshot = fresh }
    }
}

enum SettingsPane: String, Hashable, CaseIterable {
    /// Was General (#846), split in four: its raw value is what a window left open on it kept.
    case appearance = "general"
    case sidebar, account, mac
    case runtimes, spending, resources, controlPlane
    /// Was Shared (#754): the raw value is what a window left open on it kept.
    case agentConfiguration = "shared"

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .sidebar: "Sidebar"
        case .account: "Account"
        case .mac: "Mac"
        case .runtimes: "Agent Runtimes"
        case .agentConfiguration: "Agent Configuration"
        case .spending: "Cost"
        case .resources: "Resources"
        case .controlPlane: "Control plane"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .sidebar: "sidebar.left"
        case .account: "person.crop.circle"
        case .mac: "desktopcomputer"
        case .runtimes: "cpu"
        case .agentConfiguration: "square.on.square"
        case .spending: "dollarsign.circle"
        case .resources: "lock"
        case .controlPlane: "point.3.connected.trianglepath.dotted"
        }
    }

    /// The panes about this app and this Mac (#846); the panes about agents; Agent
    /// Configuration, drawn as a heading over its pages; the control plane, whose hosts are
    /// the servers and whose clients are the devices (058, frame D).
    static var groups: [[SettingsPane]] {
        [[.appearance, .sidebar, .account, .mac], [.runtimes, .spending, .resources], [.agentConfiguration], [.controlPlane]]
    }
}

/// The Settings scene's window has no grow box, and `windowResizability` on that
/// scene does not give it one. SwiftUI also takes the resizable mask off again
/// after the window appears and whenever it is resized. The mask is put back at
/// the end of each turn of the run loop, which is after SwiftUI has set it, and
/// the content is kept from going below the size the window opens at.
private struct SettingsGrowBox: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SettingsGrowView() }
    func updateNSView(_ view: NSView, context: Context) { (view as? SettingsGrowView)?.apply() }
}

private final class SettingsGrowView: NSView {
    private var observer: CFRunLoopObserver?

    override var intrinsicContentSize: NSSize { NSSize(width: 0, height: 0) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            if let observer {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                self.observer = nil
            }
            return
        }
        apply()
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            self?.apply()
        }
        guard let created else { return }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    }

    override func layout() {
        super.layout()
        apply()
    }

    func apply() {
        guard let window else { return }
        if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        let floor = SettingsWindow.size
        if window.contentMinSize.width < floor.width || window.contentMinSize.height < floor.height {
            window.contentMinSize = floor
        }
    }
}

/// A form pane: one column, left-aligned, never stretched past 560, so a pane with one
/// picker keeps it beside its label in a window sized for Agent Configuration's list and detail.
private struct FormColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: 560)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - The rail

private struct SettingsRail: View {
    @Environment(AppModel.self) private var model
    @Binding var pane: SettingsPane
    @Binding var sharedPage: AgentConfigurationPage
    @Binding var runtimeID: String
    let snapshot: DaemonAPI.SharedSnapshot?
    @Binding var controlPage: ControlPage
    let control: ControlSettingsModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Spacer().frame(height: 10) }
                ForEach(group, id: \.self) { each in
                    switch each {
                    case .agentConfiguration:
                        AgentConfigurationRailGroup(snapshot: snapshot, chosen: pane == .agentConfiguration ? sharedPage : nil,
                                                    choose: { pane = .agentConfiguration; sharedPage = $0 })
                    case .runtimes: runtimesGroup
                    case .controlPlane: controlGroup
                    default: paneItem(each)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
    }

    @ViewBuilder
    private var runtimesGroup: some View {
        HStack(spacing: 8) {
            Image(systemName: SettingsPane.runtimes.symbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(SettingsPane.runtimes.title)
        }
        .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        ForEach(model.runtimes) { status in
            let chosen = pane == .runtimes && runtimeID == status.id
            RailButton(lit: chosen, label: status.runtime.name,
                       selected: chosen,
                       action: { pane = .runtimes; runtimeID = status.id }) {
                HStack(spacing: 6) {
                    Text(status.runtime.name)
                    Spacer()
                }
                .padding(.leading, 28)
            }
        }
    }

    /// The control plane, drawn as Agent Configuration is: a heading always open over its pages (058).
    @ViewBuilder
    private var controlGroup: some View {
        heading(.controlPlane)
        controlItem(.overview, count: nil)
        controlItem(.hosts, count: control?.hosts.count)
        // Workspace providers (#691): only where the control plane can run them.
        if control?.providersHere != false {
            controlItem(.providers, count: control.map { $0.providers.count })
        }
        controlItem(.clients, count: control.map { $0.clients.count })
    }

    private func heading(_ each: SettingsPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: each.symbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(each.title)
        }
        .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func controlItem(_ target: ControlPage, count: Int?) -> some View {
        let chosen = pane == .controlPlane && controlPage == target
        return RailButton(lit: chosen, label: target.title + (count.map { ", \($0)" } ?? ""),
                          selected: chosen, action: { pane = .controlPlane; controlPage = target }) {
            HStack(spacing: 6) {
                Text(target.title)
                Spacer()
                if let count { Text("\(count)").monospacedDigit()
                        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)) }
            }
            .padding(.leading, 28)
        }
    }

    private func paneItem(_ each: SettingsPane) -> some View {
        let lit = pane == each
        return RailButton(lit: lit, label: each.title,
                          selected: lit, action: { pane = each }) {
            HStack(spacing: 8) {
                Image(systemName: each.symbol)
                    .frame(width: 20)
                    .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
                Text(each.title)
                Spacer()
            }
        }
    }
}

/// One line of the rail. The whole line is the button (memory: a tap on a card never fires),
/// lit in the accent when chosen, as Agent Configuration's own column was.
struct RailButton<Content: View>: View {
    let lit: Bool
    let label: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(lit ? AnyShapeStyle(Paper.ground) : AnyShapeStyle(.primary))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(lit ? Paper.accent : .clear, in: RoundedRectangle(cornerRadius: Paper.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Paper.Radius.control))
        }
        .buttonStyle(.plain)
        // A button is already one element: `children: .ignore` would swap it for one
        // that cannot be pressed. No Text inside carries a label of its own (memory).
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
