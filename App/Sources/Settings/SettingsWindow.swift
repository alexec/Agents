import AgentsKitCore
import AppKit
import SwiftUI

/// The Settings window (055, look/ frames A–G): one rail down the left and the chosen pane
/// beside it. It opens at one size for every pane, so choosing another never makes the
/// window jump, and it can be resized larger than that. The rail has one row for each pane
/// (#1076); Agent Runtimes, Agent Configuration, Control plane and Channels list their own pages in
/// a column inside the pane.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsPane", store: WindowDefaults.store) private var paneRaw = SettingsPane.appearance.rawValue
    @AppStorage("settingsSharedPage", store: WindowDefaults.store) private var sharedPageRaw = AgentConfigurationPage.overview.rawValue
    @AppStorage("settingsRuntimeID", store: WindowDefaults.store) private var runtimeIDRaw = RuntimeCatalog.claude.id
    /// Agent Configuration's snapshot lives here, not in its pane, so it is kept while another
    /// pane is chosen. Asked for when the window appears, when it is chosen, and whenever the app comes
    /// back to the front, which is when an edit made elsewhere shows.
    @State private var sharedSnapshot: DaemonAPI.SharedSnapshot?
    @State private var controlPage: ControlPage = .overview
    @State private var channelPage: ChannelPage = .overview
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
            SettingsRail(pane: pane)
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
            if unpaired, [.controlPlane, .channels].contains(pane.wrappedValue) { pane.wrappedValue = .appearance }
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
        case .runtimes:
            HStack(spacing: 0) {
                RuntimePageList(runtimeID: runtimeID)
                FormColumn { AgentRuntimesSettingsView(runtimeID: runtimeID.wrappedValue) }
            }
        case .agentConfiguration: AgentConfigurationView(place: .you, snapshot: sharedSnapshot, page: sharedPage, refresh: { await refreshShared() })
        case .spending: FormColumn { CostSettingsView() }
        case .resources: FormColumn { ResourcesSettingsView() }
        case .controlPlane:
            if let control {
                HStack(spacing: 0) {
                    ControlPageList(control: control, page: $controlPage)
                    ControlSettingsView(control: control, page: $controlPage)
                }
            }
        case .channels:
            if let control {
                HStack(spacing: 0) {
                    ChannelPageList(control: control, page: $channelPage)
                    ChannelsSettingsView(control: control, page: $channelPage)
                }
            }
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
    /// Where agents' questions go when the person is away (#1109): Slack first.
    case channels
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
        case .channels: "Channels"
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
        case .channels: "bubble.left.and.bubble.right"
        }
    }

    /// The panes about this app and this Mac (#846); the panes about agents; Agent
    /// Configuration; the control plane, whose hosts are the servers and whose clients are
    /// the devices (058, frame D), and its channels (#1109).
    static var groups: [[SettingsPane]] {
        [[.appearance, .sidebar, .account, .mac], [.runtimes, .spending, .resources], [.agentConfiguration], [.controlPlane, .channels]]
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

/// One row for each pane (#1076). A pane with pages of its own lists them inside it, in a
/// `PageList` beside the page, so the rail stays the same length as runtimes and pages are added.
private struct SettingsRail: View {
    @Binding var pane: SettingsPane

    var body: some View {
        // Scrolls (#1077): the rows are taller than a small window or large text leaves room for.
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Spacer().frame(height: 10) }
                    ForEach(group, id: \.self) { paneItem($0) }
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
            ForEach(model.runtimes) { status in
                PageLine(title: status.runtime.name, lit: runtimeID == status.id,
                         action: { runtimeID = status.id }) {
                    RuntimeStatusIcon(availability: status.availability)
                }
            }
        }
    }
}

/// The control plane's pages (058, #1076). Providers only where the control plane can
/// run them (#691).
private struct ControlPageList: View {
    let control: ControlSettingsModel
    @Binding var page: ControlPage

    var body: some View {
        PageList {
            line(.overview, count: nil)
            line(.hosts, count: control.hosts.count)
            if control.providersHere {
                line(.providers, count: control.providers.count)
            }
            line(.clients, count: control.clients.count)
        }
    }

    private func line(_ target: ControlPage, count: Int?) -> some View {
        PageLine(title: target.title, lit: page == target, count: count, action: { page = target })
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
