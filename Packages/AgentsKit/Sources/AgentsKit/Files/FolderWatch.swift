#if canImport(CoreServices)
import CoreServices
#endif
import Foundation

/// Tells you when something under a folder changed.
///
/// FSEvents reports directories rather than files and coalesces bursts, which is what
/// this pane wants: a build that writes four thousand files produces a manageable
/// number of directory-level events rather than four thousand file-level ones. The pane
/// re-reads the directory it is showing and the file it has open, and ignores the rest.
#if canImport(CoreServices)
public final class FolderWatch: @unchecked Sendable {
    /// How long FSEvents may gather changes before telling us. Long enough to collapse
    /// a burst, short enough to stay inside SC-002's two seconds with room to spare.
    public static let coalescingInterval: CFTimeInterval = 0.2

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.alexecollins.agents.folderwatch")
    private let onChange: @Sendable ([URL]) -> Void

    /// FSEvents takes at most this many paths to leave out of a stream.
    public static let maximumExclusions = 8

    /// - Parameters:
    ///   - excluding: folders under `root` whose changes are never reported, such as build
    ///     output (#173). Dropped by FSEvents itself, so a build there does not wake us.
    ///     Only the first `maximumExclusions` reach FSEvents; a caller drops the rest
    ///     itself in `onChange` (#216).
    ///   - onChange: the directories that changed, on an arbitrary queue.
    public init(root: URL, excluding: [URL] = [], onChange: @escaping @Sendable ([URL]) -> Void) {
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

        // `paths` is whatever the flags below asked for. With `UseCFTypes` it is a
        // CFArray of CFStrings, which is why this may be read as an `NSArray`.
        //
        // Without that flag it is a plain C `char **`, and reading it as an object
        // sends messages to the bytes of a path. That crashed the app on the first
        // event, with a pointer made of the ASCII in a filename. The flag and this cast
        // belong together; changing one means changing the other.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
            guard let array = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            // One callback names the same directory many times: 500 files written into
            // one folder arrived as 19 callbacks carrying 501 entries between them. The
            // pane re-reads a directory once however often it is named, so the repeats
            // are pure waste and go here rather than in every caller.
            var seen = Set<String>()
            var changed: [URL] = []
            changed.reserveCapacity(min(count, array.count))
            for path in array where seen.insert(path).inserted {
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
            // UseCFTypes makes `paths` a CFArray of CFStrings instead of a C `char **`,
            // which is what the callback above reads. Not optional: see the note there.
            //
            // FileEvents would give us paths rather than directories and take the
            // coalescing away with them. Directory granularity is the point.
            //
            // No WatchRoot: it opens a descriptor on the root and on every folder above
            // it, to hear the root move — 16 per project at 50 projects under /tmp (#173),
            // for a move nobody here acts on.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                     | kFSEventStreamCreateFlagNoDefer))

        guard let stream else {
            // Nothing to release: the context's retain never happened.
            Unmanaged<FolderWatch>.fromOpaque(info).release()
            return
        }
        // In the spelling FSEvents compares against, which is the real one: an exclusion
        // under `/tmp` would never match the `/private/tmp` it reports.
        let real = Self.realPath(root.path)
        let excluded = excluding.prefix(Self.maximumExclusions).map { url in
            url.path.hasPrefix(root.path + "/") ? real + url.path.dropFirst(root.path.count) : url.path
        }
        if !excluded.isEmpty { FSEventStreamSetExclusionPaths(stream, excluded as CFArray) }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// The path with every link resolved, `/private` and all, as FSEvents reports it.
    /// Foundation's own `resolvingSymlinksInPath` takes `/private` back off.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
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
#endif
