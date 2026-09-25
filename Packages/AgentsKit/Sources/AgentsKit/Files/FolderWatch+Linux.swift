#if os(Linux)
#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The same promise as the Mac's `FolderWatch`, kept with inotify on a server (037).
///
/// inotify watches one directory at a time and says nothing about the ones below it, so
/// every directory under the root gets a watch of its own, and a directory that appears
/// later gets one when it does. Changes are gathered for `coalescingInterval` and handed
/// on as the set of directories they happened in, which is what FSEvents gives the Mac
/// and what every caller already expects.
public final class FolderWatch: @unchecked Sendable {
    public static let coalescingInterval: TimeInterval = 0.2

    private let fd: Int32
    private let onChange: @Sendable ([URL]) -> Void
    private let lock = NSLock()
    private var directories: [Int32: String] = [:]
    private var pending: Set<String> = []
    private var flushScheduled = false
    private var stopped = false
    private let queue = DispatchQueue(label: "com.alexecollins.agents.folderwatch")

    private static let mask = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO
                                     | IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF)

    public init(root: URL, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.onChange = onChange
        fd = inotify_init1(Int32(IN_CLOEXEC))
        guard fd >= 0 else { return }
        addTree(root.path)
        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "AgentsKit.FolderWatch"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    public var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 && !directories.isEmpty && !stopped
    }

    public func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        if fd >= 0 { _ = close(fd) }
    }

    deinit { stop() }

    /// A watch on `path` and on every directory below it. Hidden `.git` internals are
    /// watched like anything else: a commit is a change a pane may be showing.
    private func addTree(_ path: String) {
        add(path)
        guard let walker = FileManager.default.enumerator(atPath: path) else { return }
        while let relative = walker.nextObject() as? String {
            let full = (path as NSString).appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue {
                add(full)
            }
        }
    }

    private func add(_ path: String) {
        let wd = inotify_add_watch(fd, path, Self.mask)
        guard wd >= 0 else { return }
        lock.lock()
        directories[wd] = path
        lock.unlock()
    }

    private func readLoop() {
        let size = 64 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        while true {
            let n = read(fd, buffer, size)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return }
            var offset = 0
            while offset + MemoryLayout<inotify_event>.size <= n {
                let event = buffer.load(fromByteOffset: offset, as: inotify_event.self)
                let nameStart = offset + MemoryLayout<inotify_event>.size
                var name = ""
                if event.len > 0 {
                    name = String(cString: buffer.advanced(by: nameStart).assumingMemoryBound(to: CChar.self))
                }
                handle(wd: event.wd, mask: event.mask, name: name)
                offset = nameStart + Int(event.len)
            }
        }
    }

    private func handle(wd: Int32, mask: UInt32, name: String) {
        lock.lock()
        let directory = directories[wd]
        if mask & UInt32(IN_IGNORED) != 0 { directories[wd] = nil }
        lock.unlock()
        guard let directory else { return }
        if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0, !name.isEmpty {
            addTree((directory as NSString).appendingPathComponent(name))
        }
        note(directory)
    }

    private func note(_ directory: String) {
        lock.lock()
        pending.insert(directory)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + Self.coalescingInterval) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let changed = pending.map { URL(filePath: $0) }
        pending.removeAll()
        flushScheduled = false
        let stopped = self.stopped
        lock.unlock()
        guard !stopped, !changed.isEmpty else { return }
        onChange(changed)
    }
}
#endif
