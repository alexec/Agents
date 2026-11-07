import Foundation
import Testing
@testable import AgentsKitCore

/// What a client keeps by folder and by control plane goes with the folder, the machine or
/// the control plane (#3750).
@MainActor
@Suite("Client defaults are pruned")
struct ClientDefaultsTests {
    private let devbox = MachineRef(rawValue: "devbox01")
    private let api = URL(filePath: "/tmp/work/api")
    private let gone = URL(filePath: "/tmp/work/gone")

    @Test func foldsWidthsAndPanesOfAGoneFolderGo() {
        let defaults = MemoryDefaults()
        let live = FolderKey(folder: api)
        let left = FolderKey(folder: gone)
        let elsewhere = FolderKey(host: devbox, folder: gone)
        for scope in ["", ".folderWindow"] {
            let folds = SidebarFolds(defaults: defaults, scope: scope)
            for key in [live, left, elsewhere] {
                folds.set(key, open: true)
                folds.set(key, .group(.finished), open: false)
            }
            folds.set(.needsYou, open: false)
        }
        for key in [live, left, elsewhere] {
            defaults.set(500.0, forKey: "sidebar.folder.\(key.stored).width")
            defaults.set("files", forKey: "sidebar.folder.\(key.stored).pane")
        }
        defaults.set(480.0, forKey: "sidebar.width")

        ClientDefaults.pruneFolders(defaults, host: .mac, listed: [live])

        for scope in ["", ".folderWindow"] {
            let folds = SidebarFolds(defaults: defaults, scope: scope)
            #expect(folds.isOpen(live) && !folds.isOpen(live, .group(.finished)), "a listed folder keeps its folds")
            #expect(!folds.isOpen(left) && folds.isOpen(left, .group(.finished)), "a folder not listed loses them")
            #expect(folds.isOpen(elsewhere) && !folds.isOpen(elsewhere, .group(.finished)),
                    "another machine's stay: it did not list")
            #expect(!folds.isOpen(.needsYou), "a smart row is no folder's")
        }
        #expect(defaults.object(forKey: "sidebar.folder.\(live.stored).width") != nil)
        #expect(defaults.object(forKey: "sidebar.folder.\(left.stored).width") == nil)
        #expect(defaults.object(forKey: "sidebar.folder.\(left.stored).pane") == nil)
        #expect(defaults.object(forKey: "sidebar.folder.\(elsewhere.stored).pane") != nil)
        #expect(defaults.object(forKey: "sidebar.width") != nil, "the main window's own")

        ClientDefaults.pruneFolders(defaults, host: devbox, listed: [])
        #expect(!SidebarFolds(defaults: defaults, scope: "").isOpen(elsewhere), "a machine that left takes its own")
        #expect(defaults.object(forKey: "sidebar.folder.\(elsewhere.stored).width") == nil)
    }

    @Test func aTrailingSlashIsTheSameFolder() {
        let defaults = MemoryDefaults()
        defaults.set(["mac|/tmp/work/api/"], forKey: "sidebar.folds")
        ClientDefaults.pruneFolders(defaults, host: .mac, listed: [FolderKey(folder: api)])
        #expect(defaults.stringArray(forKey: "sidebar.folds") == ["mac|/tmp/work/api/"])
    }

    @Test func aLiveSidebarDoesNotWriteAPrunedFoldBack() {
        let defaults = MemoryDefaults()
        let folds = SidebarFolds(defaults: defaults, scope: "")
        folds.set(FolderKey(folder: gone), open: true)
        ClientDefaults.pruneFolders(defaults, host: .mac, listed: [])
        folds.set(FolderKey(folder: api), open: true)
        #expect(defaults.stringArray(forKey: "sidebar.folds") == [FolderKey(folder: api).stored])
    }

    @Test func aProjectsLastFolderGoesWithItsFolder() {
        let map = ["p1": FolderKey(folder: api).stored, "p2": FolderKey(folder: gone).stored,
                   "p3": FolderKey(host: devbox, folder: gone).stored]
        #expect(ClientDefaults.pruneProjectFolders(map, host: .mac, listed: [FolderKey(folder: api)])
                == ["p1": map["p1"]!, "p3": map["p3"]!])
        #expect(ClientDefaults.pruneProjectFolders(map, host: devbox, listed: []).keys.sorted() == ["p1", "p2"])
    }

    @Test func anotherControlPlanesLockPinsGo() {
        let defaults = MemoryDefaults()
        let mine = "machineLockPin.0011223344556677"
        let theirs = "machineLockPin.8899aabbccddeeff"
        for name in [mine, theirs, "machineLockPin"] {
            for key in [name, "\(name).lock", "\(name):p1", "\(name).recoveryDone.p1"] { defaults.set(Data([1]), forKey: key) }
        }
        defaults.set(true, forKey: "machineLockPinned")

        ClientDefaults.pruneLockPins(defaults, keeping: "machineLockPin")
        #expect(defaults.dictionaryRepresentation().count == 13, "unpaired, nothing goes")

        ClientDefaults.pruneLockPins(defaults, keeping: mine)
        #expect(Set(defaults.dictionaryRepresentation().keys)
                == [mine, "\(mine).lock", "\(mine):p1", "\(mine).recoveryDone.p1", "machineLockPinned"])
    }
}
