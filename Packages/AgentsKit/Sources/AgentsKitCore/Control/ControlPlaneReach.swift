import Foundation

/// What the Remote says when it can't reach its control plane (#4916).
///
/// The phone and the iPad always connect to the control plane, never to the Mac itself.
/// When the control plane runs in Agents on the Mac (the default), "your Mac" is the right
/// name for it, and waking the Mac is the useful hint. When it runs in the cloud or on
/// hosting of the person's own, the Mac can be awake while the control plane can't be
/// reached, so the words name the control plane and its address instead, as the Mac
/// window's strip does (`HostProblem.controlPlaneUnreachable`).
public struct ControlPlaneReach: Sendable, Hashable {
    /// The control plane runs on the home Mac. True until the control plane says
    /// otherwise: it is the default set-up.
    public var onHomeMac: Bool
    /// Where the device dials it, such as `control.example.com`.
    public var address: String?

    public init(onHomeMac: Bool = true, address: String? = nil) {
        self.onHomeMac = onHomeMac
        self.address = address
    }

    /// The control plane runs on the home host's machine: the home host is listed, and
    /// its machine is the control plane's. A host with no machine id, or no home host,
    /// is not the Mac.
    public static func onHomeMac(_ status: DaemonAPI.ControlStatus, hosts: [DaemonAPI.ControlMachine]) -> Bool {
        guard let home = status.homeHost,
              let machine = hosts.first(where: { $0.id == home })?.machineID, !machine.isEmpty
        else { return false }
        return machine == status.machineID
    }

    /// The host of a membership's `url`, for the words; nil for none.
    public static func address(of url: String?) -> String? {
        guard let url, let host = URLComponents(string: url)?.host, !host.isEmpty else { return nil }
        return host
    }

    /// The page's title while nothing has answered yet.
    public var title: String {
        onHomeMac ? "Can't reach your Mac" : "Can't reach the control plane"
    }

    /// What to do about it, under the title.
    public var detail: String {
        if onHomeMac {
            return "It needs to be awake and on a network. This screen fills in as soon as it answers."
        }
        let at = address.map { " at \($0)" } ?? ""
        return "The control plane\(at) does not answer. Your agents are still working there. "
            + "This screen fills in as soon as it answers."
    }

    /// The banner on every screen: that it can't be reached and how old what is shown is
    /// (#5141), or that it has not been reached yet and nothing was read.
    public func banner(read: Date?, now: Date = Date()) -> String {
        let name = onHomeMac ? "your Mac" : "the control plane"
        guard read != nil else { return "Not connected to \(name) yet" }
        return LastUpdate.banner("Can't reach \(name).", read: read, now: now)
    }

    /// A save that did not go because nothing answers.
    public var notAnswering: String {
        "\(onHomeMac ? "Your Mac" : "The control plane") is not answering. What you typed is kept here."
    }
}
