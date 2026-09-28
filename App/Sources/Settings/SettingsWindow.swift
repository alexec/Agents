import AgentsKit
import AppKit
import SwiftUI

/// The Settings window (055, look/ frames A–G): one rail down the left and the chosen pane
/// beside it. It opens at one size for every pane, so choosing another never makes the
/// window jump, and it can be resized larger than that. Shared's pages are listed in the
/// rail under a heading of their own rather than in a column of their own, so there is
/// one place to choose from.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settingsPane") private var paneRaw = SettingsPane.general.rawValue
    @AppStorage("settingsSharedPage") private var sharedPageRaw = SharedPage.overview.rawValue
    /// Shared's snapshot lives here, not in its pane, because the rail shows its counts.
    /// Asked for when the window appears, when Shared is chosen, and whenever the app comes
    /// back to the front, which is when an edit made elsewhere shows.
    @State private var sharedSnapshot: DaemonAPI.SharedSnapshot?

    /// The size it opens at, and the smallest it will go. A larger window gives the extra
    /// room to the detail on Shared, and to the empty space beside a form pane, which
    /// stays one column.
    static let size = CGSize(width: 1_000, height: 640)

    private var pane: Binding<SettingsPane> {
        Binding(
            get: { SettingsPane(rawValue: paneRaw) ?? .general },
            set: { paneRaw = $0.rawValue })
    }

    private var sharedPage: Binding<SharedPage> {
        Binding(
            get: { SharedPage(rawValue: sharedPageRaw) ?? .overview },
            set: { sharedPageRaw = $0.rawValue })
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsRail(pane: pane, sharedPage: sharedPage, snapshot: sharedSnapshot)
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
        // The Settings scene draws a window with no grow box, and ignores
        // windowResizability, so the mask is set on the window itself.
        .background(SettingsGrowBox())
        .navigationTitle(pane.wrappedValue.title)
        .task { await refreshShared() }
        // Asked for from elsewhere in the app: the Pool page's "Edit the pool" (052).
        .onChange(of: model.settingsPaneAsked, initial: true) { _, asked in
            guard let asked else { return }
            pane.wrappedValue = asked
            model.settingsPaneAsked = nil
        }
        .onChange(of: pane.wrappedValue) { _, chosen in
            if chosen == .shared { Task { await refreshShared() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshShared() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.wrappedValue {
        case .general: FormColumn { GeneralSettingsView() }
        case .runtimes: FormColumn { AgentRuntimesSettingsView() }
        case .shared: SharedSettingsView(snapshot: sharedSnapshot, page: sharedPage, refresh: { await refreshShared() })
        case .spending: FormColumn { CostSettingsView() }
        case .pool: FormColumn { PoolSettingsView() }
        case .devices: FormColumn { DevicesPane() }
        case .servers: FormColumn { ServersSettingsView() }
        }
    }

    private func refreshShared() async {
        if let fresh = await model.sharedSnapshot() { sharedSnapshot = fresh }
    }
}

enum SettingsPane: String, Hashable, CaseIterable {
    case general, runtimes, shared, spending, pool, devices, servers

    var title: String {
        switch self {
        case .general: "General"
        case .runtimes: "Agent Runtimes"
        case .shared: "Shared"
        case .spending: "Spending"
        case .pool: "Pool"
        case .devices: "Devices"
        case .servers: "Servers"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .runtimes: "cpu"
        case .shared: "square.on.square"
        case .spending: "dollarsign.circle"
        case .pool: "arrow.triangle.swap"
        case .devices: "iphone"
        case .servers: "server.rack"
        }
    }

    /// General on its own; the panes about agents; Shared, drawn as a heading over its
    /// pages; the ways in from elsewhere.
    static let groups: [[SettingsPane]] = [[.general], [.runtimes, .spending, .pool], [.shared], [.devices, .servers]]
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
        guard let window else {
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
/// picker keeps it beside its label in a window sized for Shared's list and detail.
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
    @Binding var pane: SettingsPane
    @Binding var sharedPage: SharedPage
    let snapshot: DaemonAPI.SharedSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsPane.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Spacer().frame(height: 10) }
                ForEach(group, id: \.self) { each in
                    if each == .shared { sharedGroup } else { paneItem(each) }
                }
            }
            Spacer()
            if pane == .shared {
                Text("Your own set, for every project. A project’s own .agents folder is under Project configuration.")
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
            }
        }
        .padding(12)
        .frame(width: 200)
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
                Text(each.title)
                Spacer()
            }
        }
    }

    /// Shared is a heading, not a button: its pages are always listed under it, so none is
    /// hidden behind a click. Which page is lit only shows while Shared is the pane.
    @ViewBuilder
    private var sharedGroup: some View {
        HStack(spacing: 8) {
            Image(systemName: SettingsPane.shared.symbol)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(SettingsPane.shared.title)
        }
        .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        page("Overview", .overview, count: nil, warns: false)
        if let snapshot, snapshot.laidOut, !snapshot.isEmpty {
            page("Instructions", .instructions, count: snapshot.instructions?.exists == true ? 1 : 0,
                 warns: snapshot.warns(.instructions))
            page("Skills", .skills, count: snapshot.skills.count, warns: snapshot.warns(.skills))
            page("MCP servers", .mcp, count: snapshot.mcp.problem == nil ? snapshot.mcp.servers.count : nil,
                 warns: snapshot.warns(.mcp))
            page("Plugins", .plugins, count: snapshot.plugins.count, warns: snapshot.warns(.plugins))
            page("Other files", .other, count: snapshot.otherFiles.count, warns: false)
        }
    }

    private func page(_ title: String, _ target: SharedPage, count: Int?, warns: Bool) -> some View {
        let chosen = pane == .shared && sharedPage == target
        return RailButton(lit: chosen,
                          label: title + (count.map { ", \($0)" } ?? "") + (warns ? ", needs a look" : ""),
                          selected: chosen, action: { pane = .shared; sharedPage = target }) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if warns {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(chosen ? .white : SharedInk.attention)
                }
                if let count { Text("\(count)").monospacedDigit()
                        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary)) }
            }
            .padding(.leading, 28)
        }
    }
}

/// One line of the rail. The whole line is the button (memory: a tap on a card never fires),
/// lit in the accent when chosen, as Shared's own column was.
private struct RailButton<Content: View>: View {
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
                .background(lit ? Paper.ink : .clear, in: RoundedRectangle(cornerRadius: Paper.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: Paper.Radius.control))
        }
        .buttonStyle(.plain)
        // A button is already one element: `children: .ignore` would swap it for one
        // that cannot be pressed. No Text inside carries a label of its own (memory).
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
