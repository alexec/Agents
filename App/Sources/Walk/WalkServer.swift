#if DEBUG
import AppKit
import Darwin
import Foundation
import os

/// The walk socket (#1172): a scratch copy of the window (`--walk <name>`, Debug only) looks
/// at and presses itself, in its own process, for run-app's `walk.py`. Nothing goes through
/// the window server, the AX server, focus or HID, so a locked screen does not stop a walk
/// and nothing can reach the person's own window.
///
/// One JSON object per line each way, at `walk.sock` in the walk's folder in the container.
/// The person's window never has `--walk`, and a Release or Live build has none of this.
enum WalkServer {
    static func startIfWalking() {
        guard let folder = ControlConfig.walkFolder else { return }
        Thread.detachNewThread { serve(in: folder) }
        // SwiftUI makes its accessibility elements only once an assistive app has asked, and
        // the walk reads and presses through them. This is the attribute an assistive app
        // sets; it changes nothing that is drawn.
        DispatchQueue.main.async {
            _ = (NSApp as NSObject).perform(NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"),
                                            with: NSNumber(value: true))
        }
    }

    private static func serve(in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)  // store-ok: the walk's folder in the container
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return log("socket: \(errno)") }
        // Bound by a name relative to the folder: the container's path is longer than the
        // 104 bytes a socket's address may hold. Once, at launch, before anything else is
        // opened by a relative path.
        let bound: Int32 = folder.path.withCString { path in
            let previous = open(".", O_RDONLY)
            defer { if previous >= 0 { _ = fchdir(previous); close(previous) } }
            guard chdir(path) == 0 else { return -1 }
            unlink("walk.sock")
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { raw in
                "walk.sock".utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { close(fd); return log("bind: \(errno)") }
        log("listening at \(folder.path)/walk.sock")
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { session(client) }
        }
    }

    private static func session(_ client: Int32) {
        defer { close(client) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { return }
            pending += buffer[0..<count]
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                var reply = DispatchQueue.main.sync { MainActor.assumeIsolated { WalkCommands.run(Data(line)) } }
                reply.append(0x0A)
                let written = reply.withUnsafeBytes { raw -> Bool in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                        guard n > 0 else { return false }
                        offset += n
                    }
                    return true
                }
                guard written else { return }
            }
        }
    }

    /// To the unified log, in the clear (`log show --predicate 'category == "walk"'`): a
    /// walk's window is opened by `open`, which keeps no stderr.
    static func log(_ text: String) {
        logger.notice("\(text, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.alexecollins.agents", category: "walk")
}
#endif
