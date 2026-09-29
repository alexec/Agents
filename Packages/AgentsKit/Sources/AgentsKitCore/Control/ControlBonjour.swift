import Foundation

/// The Bonjour type a control plane on this network is advertised under (058, R8). In
/// Core so the sandboxed window can browse for it.
public enum ControlBonjour {
    public static let serviceType = "_agents-control._tcp"
}
