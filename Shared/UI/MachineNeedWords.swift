import AgentsKitCore
import Foundation

/// The grey line under a machine's row (#3764), on the Mac and the Remote (#4034), in the
/// words the rest of the app says them in: the sidebar foot's (OfflineWords), set-up's
/// (HostProblem) and updates' (UpdateWords).
enum MachineNeedWords {
    static func line(_ need: MachineNeed, name: String, row: DaemonAPI.ControlMachine?) -> String {
        switch need {
        case .offline, .stopped: OfflineWords.footLine(name: name, row: row)
        case .setupFailed: HostProblem.installFailed("").sentence(name: name, label: name)
        case .disk(let disk): DiskSpace.needWords(disk)
        case .update: row.map(UpdateWords.state) ?? "Needs an update"
        case .signIn(let runtimes):
            "\(ListFormatter.localizedString(byJoining: runtimes)) \(runtimes.count == 1 ? "needs" : "need") sign-in"
        }
    }
}
