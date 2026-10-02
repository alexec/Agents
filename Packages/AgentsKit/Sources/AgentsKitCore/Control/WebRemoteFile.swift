import Foundation

/// `web.json` in the control plane's home (071 R3): whether this run of `serve --home`
/// serves the web remote, for Agents Host, which isn't a client and can't ask
/// `control/status`. Written by the process it names, so one left by an earlier run is
/// told apart by its pid.
public struct WebRemoteFile: Codable, Sendable, Equatable {
    public static let name = "web.json"

    public var pid: Int32
    public var status: DaemonAPI.WebRemoteStatus

    public init(pid: Int32, status: DaemonAPI.WebRemoteStatus) {
        self.pid = pid
        self.status = status
    }

    /// The status in `home`, if the copy running as `pid` wrote it.
    public static func read(in home: URL, pid: Int32) -> DaemonAPI.WebRemoteStatus? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(name)),
              let file = try? JSONDecoder().decode(WebRemoteFile.self, from: data), file.pid == pid else { return nil }
        return file.status
    }
}
