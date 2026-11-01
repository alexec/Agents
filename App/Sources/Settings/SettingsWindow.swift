import AgentsKitCore
import AppKit
import SwiftUI

/// The Settings window (055, look/ frames A–G): one rail down the left and the chosen pane
/// beside it. It opens at one size for every pane, so choosing another never makes the
/// window jump, and it can be resized larger than that. The rail has one row for each pane
/// (#1076), grouped by subject (#2157): This app, Agents (#2957), Machines and Control plane. Agent Runtimes,
/// Agent Configuration and Machines list their own pages in a column inside the pane.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsPane", store: WindowDefaults.store) private var paneRaw = SettingsPane.appearance.rawValue
    @AppStorage("settingsSharedPage", store: WindowDefaults.store) private var sharedPageRaw = AgentConfigurationPage.overview.rawValue
    @AppStorage("settingsRuntimeID", store: WindowDefaults.store) private var runtimeIDRaw = RuntimeCatalog.claude.id
    /// Agent Configuration's snapshot lives here, not in its pane, so it is kept while another
    /// pane is chosen. Asked for when the window appears, when it is chosen, and whenever the app comes
    /// back to the front, which is when an edit made elsewhere shows.
    @State private var sharedSnapshot: DaemonAPI.SharedSnapshot?
    @State private var machinesPage: MachinesPage = .list
    /// A Skills, Personas or Workflows file has edits not saved: another pane asks first (#2745).
    @State private var unsaved = false
    @State private var leaving: UnsavedLeave?
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
                let known = Set(model.runtimes.map(\.id)).union([LevelWords.autoID])
                if known.contains(runtimeIDRaw) { return runtimeIDRaw }
                return model.runtimes.first?.id ?? RuntimeCatalog.claude.id
            },
            set: { runtimeIDRaw = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsRail(pane: Binding(get: { pane.wrappedValue },
                                       set: { next in
                                           guard next != pane.wrappedValue else { return }
                                           $leaving.leave(unsaved: unsaved) { pane.wrappedValue = next }
                                       }),
                         shows: shows)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                // A pane of this Mac's own things, with no host on this Mac (#1503): what is
                // true, and what to do, over a pane that has nothing to show.
                if model.noHostOnThisMac, isThisMacs {
                    NoMacHostNotice {
                        machinesPage = .list
                        pane.wrappedValue = .machines
                    }
                    Divider()
                }
                // Each setting states its fixed scope (#2410).
                if let scope = scopeOnEveryMachine {
                    ScopeLine(onEveryMachine: scope)
                    Divider()
                }
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .discardUnsavedQuestion($leaving)
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
            if unpaired, pane.wrappedValue.needsControlPlane { pane.wrappedValue = .appearance }
            if let control { Task { await control.start() } }
        }
        // Asked for from elsewhere in the app: a link that names a Settings pane.
        .onChange(of: model.settingsPaneAsked, initial: true) { _, asked in
            guard let asked else { return }
            pane.wrappedValue = asked
            model.settingsPaneAsked = nil
            // A file for the editor (#2803): its page, unless edits not saved hold this one.
            if asked == .agentConfiguration, let file = model.agentConfigFileAsked, file.folder == nil {
                let wanted = AgentConfigurationPage(file.kind)
                if sharedPage.wrappedValue == wanted || !unsaved {
                    sharedPage.wrappedValue = wanted
                } else {
                    model.agentConfigFileAsked = nil
                }
            }
            if asked == .machines { machinesPage = .list }
        }
        .onChange(of: pane.wrappedValue) { _, chosen in
            if chosen == .agentConfiguration { Task { await refreshShared() } }
            // Leaving a pane whose edits may change a part that follows the person (#1760).
            Task { await model.keepFollowingParts() }
            if chosen == .runtimes { Task { await model.refreshRuntimes() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshShared()
                if pane.wrappedValue == .runtimes { await model.refreshRuntimes() }
            }
        }
    }

    /// A pane of this Mac's own things is showing: one of them, or Machines ▸ This Mac.
    private var isThisMacs: Bool {
        pane.wrappedValue.isThisMacs || (pane.wrappedValue == .machines && (control == nil || machinesPage == .thisMac))
    }

    /// Whether the rail lists a pane: those of the control plane need one, and Workspace
    /// Providers one that can run them (#691).
    private func shows(_ each: SettingsPane) -> Bool {
        switch each {
        // A person's own sign-ins (#995), a pane of its own as on the Remote (#2197).
        // People with no control plane would say it can't be reached: it lists Account only (#2258).
        case .controlPlane, .clients, .secrets, .people, .channels, .signIns, .policy: control != nil
        // An admin's, and a member's in a group, who sees the groups they are in (#1761, #2076).
        case .groups: control != nil && model.people.showsGroups
        // An admin's: which providers people sign in with (#995).
        case .signIn: control != nil && model.people.you?.isAdmin == true
        // An admin's: a member sees only themselves, so no bots (#2132).
        case .bots: control != nil && model.people.you?.isAdmin == true
        case .providers: control?.providersHere ?? false
        default: true
        }
    }

    /// The part this pane edits, so it can state its fixed scope (#2410).
    private var scopeOnEveryMachine: Bool? {
        return switch pane.wrappedValue {
        case .agentsPolicy, .spending, .runtimes: true
        case .resources: false
        case .agentConfiguration: nil
        default: nil
        }
    }

    private var title: String {
        guard pane.wrappedValue == .runtimes else { return pane.wrappedValue.title }
        if runtimeID.wrappedValue == LevelWords.autoID { return LevelWords.auto }
        return model.runtimes.first { $0.id == runtimeID.wrappedValue }?.runtime.name
            ?? SettingsPane.runtimes.title
    }

    @ViewBuilder
    private var content: some View {
        switch pane.wrappedValue {
        case .appearance: FormColumn { Form { AppearanceSettingsView() }.paperForm() }
        // The archive switch is a rule of Agents ▸ Policy now (#2957, FR-023).
        case .sidebar: FormColumn { Form { SidebarSettingsSection(showsArchiveSwitch: false) }.paperForm() }
        case .agentsPolicy:
            FormColumn {
                PolicyPane(host: model.policyHost, revision: model.policyRevision,
                           openOrganisationPolicy: control == nil ? nil : { pane.wrappedValue = .policy })
            }
        case .voice: FormColumn { Form { VoiceSettingsSection() }.paperForm() }
        case .account: FormColumn { AccountSettingsView() }
        case .signIns:
            FormColumn {
                Form {
                    SignInsSection(control: model.controlRequests, controlKey: ControlConfig.controlKey, people: model.people)
                }
                .paperForm()
            }
        case .machines:
            if let control {
                HStack(spacing: 0) {
                    MachinesPageList(control: control, page: $machinesPage)
                    switch machinesPage {
                    case .list: ControlSettingsView(control: control, page: .hosts)
                    case .thisMac: FormColumn { MacSettingsView() }
                    }
                }
            } else {
                FormColumn { MacSettingsView() }
            }
        case .runtimes:
            HStack(spacing: 0) {
                RuntimePageList(runtimeID: runtimeID)
                // Auto's own page, first (#2658).
                if runtimeID.wrappedValue == LevelWords.autoID {
                    FormColumn { AutoSettingsView() }
                } else {
                    FormColumn { AgentRuntimesSettingsView(runtimeID: runtimeID.wrappedValue) }
                }
            }
        case .agentConfiguration: AgentConfigurationView(place: .you, snapshot: sharedSnapshot, page: sharedPage, refresh: { await refreshShared() },
                                                         unsaved: $unsaved)
        case .spending: FormColumn { CostSettingsView() }
        case .resources: FormColumn { ResourcesSettingsView() }
        case .controlPlane:
            if let control { ControlSettingsView(control: control, page: .overview) }
        case .providers:
            if let control { ControlSettingsView(control: control, page: .providers) }
        case .clients:
            if let control { ControlSettingsView(control: control, page: .clients) }
        case .secrets:
            // Through the window's own connection, which hears when they change (#1760).
            FormColumn { SecretsPane(control: model.controlRequests, state: model.userScope) }
        case .people:
            // Through the window's own connection to the control plane, which hears when
            // people change (#994).
            FormColumn { PeoplePane(control: model.controlRequests, people: model.people) }
        case .bots:
            FormColumn { PeoplePane(control: model.controlRequests, people: model.people, kind: .bot) }
        case .groups:
            FormColumn { GroupsPane(control: model.controlRequests, state: model.people) }
        case .channels:
            // Through the window's own connection, which hears links change (#1762).
            FormColumn { ChannelsPane(control: model.controlRequests, people: model.people) }
        case .signIn:
            FormColumn { SignInPane(control: model.controlRequests, revision: model.people.revision) }
        case .policy:
            FormColumn { OrgPolicyPane(control: model.controlRequests, people: model.people) }
        }
    }

    private func refreshShared() async {
        if let fresh = await model.sharedSnapshot() { sharedSnapshot = fresh }
    }
}

/// The panes in each of the rail's groups (#1759).
extension SettingsScope {
    var panes: [SettingsPane] {
        switch self {
        // How this app draws: Sidebar is kept on the Mac's host so every client draws the
        // same (#1033, #2079), but its subject is the app (#2157).
        // Notifications' limits are rules of Agents ▸ Policy now (#2957, FR-023).
        case .thisApp: [.appearance, .sidebar, .voice]
        // What agents may do, what they spend and what they take (#2957, FR-018).
        case .agents: [.agentsPolicy, .spending, .resources]
        case .machines: [.machines, .runtimes, .agentConfiguration, .secrets]
        // The person's account first, shown with no control plane too (#2157).
        case .controlPlane: [.account, .signIns, .people, .bots, .groups, .channels, .signIn, .policy, .providers, .clients, .controlPlane]
        }
    }
}

enum SettingsPane: String, Hashable, CaseIterable {
    /// Was General (#846), split in four: its raw value is what a window left open on it kept.
    case appearance = "general"
    case sidebar, account
    /// Agents ▸ Policy (#2957): the person's own layer of what agents may do. Took in
    /// Notifications' limits (#2805), whose window left open on it opens Appearance.
    case agentsPolicy
    /// Voice mode, its voice and its sounds (Alex, 2026-10-29): was in Appearance.
    case voice
    /// Every machine, and this Mac's own settings (#1759). Was the Mac pane: its raw value is
    /// what a window left open on it kept.
    case machines = "mac"
    case runtimes, spending, resources
    /// The control plane's Overview.
    case controlPlane
    /// The control plane's machine providers (#691) and its clients, pages of Control plane
    /// before #1759.
    case providers, clients
    /// Who uses the control plane, and the machines and clients that belong to them (#994).
    case people
    /// The bots that run the team's workflows (#1761), apart from the people (#2132).
    case bots
    /// Groups own machine providers (#1761).
    case groups
    /// Channel identities linked to people (#1762).
    case channels
    /// Which providers people sign in with (#995).
    case signIn
    /// Organisation Policy (#998, FR-024): the organisation's rules, read only, and the kill
    /// switch for an admin.
    case policy
    /// How this person signs in on their other clients (#995): Control plane ▸ Sign-ins, as
    /// the Remote and the page have it and every client's words name it (#2197, #2256). Was
    /// in Account.
    case signIns
    /// Was Shared (#754): the raw value is what a window left open on it kept.
    case agentConfiguration = "shared"
    /// The secrets the control plane keeps for the person (#1760). Was On Every Machine, whose
    /// settings moved into their own panes (#2157): its raw value is what a window left open
    /// on it kept.
    case secrets = "onEveryMachine"

    /// A pane of what this Mac's host keeps: its runtimes, settings, cost and resources.
    /// Machines is one only on its This Mac page.
    var isThisMacs: Bool {
        switch self {
        case .runtimes, .agentConfiguration, .spending, .resources: true
        case .appearance, .sidebar, .agentsPolicy, .voice, .account, .machines, .controlPlane, .providers, .clients, .people, .bots, .groups,
             .channels, .signIn, .signIns, .secrets, .policy: false
        }
    }

    /// A pane drawn only with a control plane to show: a window left on one moves away when
    /// the Mac is forgotten (#2258).
    var needsControlPlane: Bool {
        [.controlPlane, .providers, .clients, .secrets, .signIns, .people, .bots, .groups, .channels, .signIn, .policy]
            .contains(self)
    }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .sidebar: "Sidebar"
        case .agentsPolicy: PolicyLayersWords.title
        case .voice: "Voice"
        case .account: "Account"
        case .machines: "Machines"
        case .runtimes: "Agent Runtimes"
        case .agentConfiguration: "Agent Configuration"
        case .spending: "Spending"
        case .resources: "Resources"
        case .controlPlane: "Overview"
        case .providers: "Machine Providers"
        case .clients: "Clients"
        case .people: "People"
        case .bots: BotWords.title
        case .groups: GroupWords.title
        case .channels: ChannelLinkWords.title
        case .signIn: SignInWords.paneTitle
        case .policy: OrgPolicyWords.title
        case .signIns: SignInWords.signInsTitle
        case .secrets: UserScopeWords.secretsTitle
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .sidebar: "sidebar.left"
        case .agentsPolicy: PolicyLayersWords.symbol
        case .voice: "waveform"
        case .account: "person.crop.circle"
        case .machines: "desktopcomputer"
        case .runtimes: "cpu"
        case .agentConfiguration: "square.on.square"
        case .spending: "dollarsign.circle"
        case .resources: "lock"
        case .controlPlane: "point.3.connected.trianglepath.dotted"
        case .providers: "cloud"
        case .clients: "iphone"
        case .people: "person.2"
        case .bots: "gearshape.2"
        case .groups: "person.3"
        case .channels: "bubble.left.and.bubble.right"
        case .signIn: SignInWords.paneSymbol
        case .policy: OrgPolicyWords.symbol
        case .signIns: "person.badge.key"
        case .secrets: "key"
        }
    }
}

/// Machines' pages (#1759): every machine, as Control plane ▸ Hosts listed them, and this
/// Mac's own settings, as the Mac pane had them.
enum MachinesPage: Hashable {
    case list, thisMac

    var title: String {
        switch self {
        case .list: "All Machines"
        case .thisMac: "This Mac"
        }
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

/// No host on this Mac (#1503): the control plane is elsewhere and lists only servers as
/// hosts, so this Mac's runtimes and settings have nobody to keep them.
private struct NoMacHostNotice: View {
    let showHosts: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This Mac is not one of your machines", systemImage: "exclamationmark.triangle")
                .appText(.supporting).fontWeight(.semibold)
                .tinted(.attention)
            Text("This Mac’s runtimes and settings are kept only when it is one of your machines, and the control plane does not have it. Agents on your servers are not changed. To add this Mac, make a code in Machines ▸ Add by Code…, then paste it in Agents Host under Join one elsewhere.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show Machines", action: showHosts)
                .controlSize(.small)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .contain)
    }
}

/// The top of a settings pane: its scope is fixed (#2410).
private struct ScopeLine: View {
    let onEveryMachine: Bool

    var body: some View {
        Text(onEveryMachine ? UserScopeWords.yoursOnEveryMachine : UserScopeWords.thisMacOnly)
            .appText(.supporting).fontWeight(.semibold)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(16)
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

/// One row for each pane (#1076). A pane with pages of its own lists them inside it, in a
/// `PageList` beside the page, so the rail stays the same length as runtimes and pages are added.
private struct SettingsRail: View {
    @Binding var pane: SettingsPane
    let shows: (SettingsPane) -> Bool

    var body: some View {
        // Scrolls (#1077): the rows are taller than a small window or large text leaves room for.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SettingsScope.allCases.enumerated()), id: \.offset) { index, scope in
                    let panes = scope.panes.filter(shows)
                    if !panes.isEmpty {
                        Text(scope.title)
                            .appText(.fine).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, index > 0 ? 12 : 0)
                            .padding(.bottom, 2)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(panes, id: \.self) { paneItem($0) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
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
                Text(each.title).lineLimit(1)
                Spacer()
            }
        }
    }
}

/// A pane's own pages, in a column inside the pane beside the chosen page (#1076): Agent
/// Runtimes' runtimes, Agent Configuration's pages and the control plane's. Each line is a
/// `PageLine`.
struct PageList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) { content }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 180)
            .frame(maxHeight: .infinity)
            Divider()
        }
    }
}

/// One line of a `PageList`: the page's name, then what it has to say at the end of the
/// line (its count, a mark), which the label also says.
struct PageLine<Trailing: View>: View {
    let title: String
    let lit: Bool
    var label: String? = nil
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        RailButton(lit: lit, label: label ?? title, selected: lit, action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer()
                trailing
            }
        }
    }
}

extension PageLine where Trailing == PageCount {
    init(title: String, lit: Bool, count: Int?, action: @escaping () -> Void) {
        self.init(title: title, lit: lit, label: title + (count.map { ", \($0)" } ?? ""), action: action) {
            PageCount(count: count, lit: lit)
        }
    }
}

/// A page's count at the end of its line, white on the lit line.
struct PageCount: View {
    let count: Int?
    let lit: Bool

    var body: some View {
        if let count {
            Text("\(count)").monospacedDigit()
                .foregroundStyle(lit ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
    }
}

/// Agent Runtimes' list (#1076): each runtime, with its status at the end of its line.
private struct RuntimePageList: View {
    @Environment(AppModel.self) private var model
    @Binding var runtimeID: String

    var body: some View {
        PageList {
            // Auto first: the runtime choice that is not a runtime (#2658, Story 3).
            PageLine(title: LevelWords.auto, lit: runtimeID == LevelWords.autoID,
                     action: { runtimeID = LevelWords.autoID }) {
                EmptyView()
            }
            ForEach(model.runtimes) { status in
                PageLine(title: status.runtime.name, lit: runtimeID == status.id,
                         action: { runtimeID = status.id }) {
                    RuntimeStatusIcon(availability: status.availability)
                }
            }
        }
    }
}

/// Machines' pages (#1759): every machine, with its count, and this Mac's own settings.
private struct MachinesPageList: View {
    let control: ControlSettingsModel
    @Binding var page: MachinesPage

    var body: some View {
        PageList {
            PageLine(title: MachinesPage.list.title, lit: page == .list, count: control.hosts.count,
                     action: { page = .list })
            PageLine(title: MachinesPage.thisMac.title, lit: page == .thisMac, count: nil,
                     action: { page = .thisMac })
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
