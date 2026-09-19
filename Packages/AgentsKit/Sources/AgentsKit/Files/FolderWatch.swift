import CoreServices
import Foundation

/// Tells you when something under a folder changed.
///
/// FSEvents reports directories rather than files and coalesces bursts, which is what
/// this pane wants: a build that writes four thousand files produces a manageable
/// number of directory-level events rather than four thousand file-level ones. The pane
/// re-reads the directory it is showing and the file it has open, and ignores the rest.
public final class FolderWatch: @unchecked Sendable {
    /// How long FSEvents may gather changes before telling us. Long enough to collapse
    /// a burst, short enough to stay inside SC-002's two seconds with room to spare.
    public static let coalescingInterval: CFTimeInterval = 0.2

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.alexecollins.agents.folderwatch")
    private let onChange: @Sendable ([URL]) -> Void

    /// - Parameter onChange: the directories that changed, on an arbitrary queue.
    public init(root: URL, onChange: @escaping @Sendable ([URL]) -> Void) {
        self.onChange = onChange

        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<FolderWatch>.fromOpaque(info).release()
            },
            copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var changed: [URL] = []
            changed.reserveCapacity(count)
            for index in 0..<count {
                guard let path = array[index] as? String else { continue }
                changed.append(URL(filePath: path))
            }
            guard !changed.isEmpty else { return }
            watch.onChange(changed)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.coalescingInterval,
            // FileEvents would give us paths rather than directories and take the
            // coalescing away with them. Directory granularity is the point.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot))

        guard let stream else {
            // Nothing to release: the context's retain never happened.
            Unmanaged<FolderWatch>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// Started watching successfully. False when the folder could not be watched, which
    /// the pane says out loud rather than quietly never updating.
    public var isWatching: Bool { stream != nil }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
