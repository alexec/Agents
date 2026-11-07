import Foundation

/// What the Mac window and the Remote keep in defaults by folder and by control plane, kept to
/// the folders, machines and control planes that exist (#3750). The web page's are
/// `Web/src/model/prune.ts`.
///
/// By folder: the sidebar's folds (`sidebar.folds…`, `sidebar.folded…`, every scope), a folder
/// window's inspector width and pane (`sidebar.folder.<host|path>.width`, `.pane`), and New
/// Session's last folder for each project. They are pruned one machine at a time: when that
/// machine lists its folders, a folder it does not list goes; when the control plane no longer
/// lists the machine, all of its go. An offline machine lists nothing, so its keys stay.
///
/// By control plane: the machine-lock pins (`machineLockPin.<key>`, #3651). Once a client is
/// paired, another control plane's pins go.
public enum ClientDefaults {
    /// Drops every fold, width and pane of a folder on `host` that `listed` does not name.
    public static func pruneFolders(_ defaults: UserDefaults, host: MachineRef, listed: some Sequence<FolderKey>) {
        let kept = Set(listed.filter { $0.host == host }.map { name($0.stored) })
        let gone = { (stored: String) in isOn(host, stored) && !kept.contains(name(stored)) }
        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix("sidebar.folds") || key.hasPrefix("sidebar.folded"), let names = value as? [String] {
                let left = names.filter { fold in folder(ofFold: fold).map { !gone($0) } ?? true }
                if left.count != names.count { defaults.set(left, forKey: key) }
            } else if let stored = folder(ofWidthKey: key), gone(stored) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// New Session's last folder for each project (#3279), less those of a folder on `host`
    /// that `listed` does not name.
    public static func pruneProjectFolders(_ map: [String: String], host: MachineRef,
                                           listed: some Sequence<FolderKey>) -> [String: String] {
        let kept = Set(listed.filter { $0.host == host }.map { name($0.stored) })
        return map.filter { !isOn(host, $0.value) || kept.contains(name($0.value)) }
    }

    /// Drops the machine-lock pins kept under another name than `name`: another control
    /// plane's, and the unpaired name's. Nothing goes while `name` is the unpaired one.
    public static func pruneLockPins(_ defaults: UserDefaults, keeping name: String, base: String = "machineLockPin") {
        guard name != base else { return }
        let under = { (key: String, name: String) in key == name || key.hasPrefix(name + ".") || key.hasPrefix(name + ":") }
        for key in defaults.dictionaryRepresentation().keys where under(key, base) && !under(key, name) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The folder a fold is named by (`host|path`, or `<fold>:host|path`); nil for one named
    /// by no folder (a smart row).
    static func folder(ofFold name: String) -> String? {
        guard let bar = name.firstIndex(of: "|") else { return nil }
        guard let colon = name[..<bar].firstIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    /// The folder a folder window's width or pane is kept by (#1089).
    static func folder(ofWidthKey key: String) -> String? {
        let prefix = "sidebar.folder."
        guard key.hasPrefix(prefix) else { return nil }
        for suffix in [".width", ".pane"] where key.hasSuffix(suffix) {
            let stored = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            return stored.contains("|") ? stored : nil
        }
        return nil
    }

    private static func isOn(_ host: MachineRef, _ stored: String) -> Bool { stored.hasPrefix(host.rawValue + "|") }

    /// `host|path` without a trailing slash, so a folder kept with one matches one listed without.
    private static func name(_ stored: String) -> String {
        var name = Substring(stored)
        while name.hasSuffix("/"), !name.hasSuffix("|/") { name = name.dropLast() }
        return String(name)
    }
}
