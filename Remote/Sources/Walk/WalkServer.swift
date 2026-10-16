#if DEBUG && targetEnvironment(simulator)
import Darwin
import Foundation
import os
import UIKit

/// The Remote's walk socket (#1182), as the Mac window's (#1172): the Remote in the walk
/// simulator (`-walk`, Debug only) looks at and presses itself, in its own process, for
/// run-app's `walk.py remote`. There is no Simulator GUI on this Mac, so nothing else can
/// tap it; nothing here goes through a window server, the AX server or HID.
///
/// One JSON object per line each way, at `tmp/walk.sock` in the app's data container, which
/// is a folder on the Mac. Only in the simulator: on a device the socket could not be
/// reached, and a walk never runs on the person's devices.
enum WalkServer {
    static let argument = "-walk"

    static func startIfWalking() {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }
        let folder = FileManager.default.temporaryDirectory
        Thread.detachNewThread { serve(in: folder) }
        assist()
    }

    /// SwiftUI makes its accessibility elements only once an assistive app is on, and the
    /// walk reads and presses through them. This turns application accessibility on, as
    /// XCUITest does, in the walk simulator only; it changes nothing that is drawn.
    private static func assist() {
        typealias SetEnabled = @convention(c) (Bool) -> Void
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else {
            return log("accessibility: \(String(cString: dlerror()))")
        }
        unsafeBitCast(symbol, to: SetEnabled.self)(true)
    }

    private static func serve(in folder: URL) {
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

    /// To the simulator's unified log (`simctl spawn … log show --predicate 'category == "walk"'`).
    static func log(_ text: String) {
        logger.notice("\(text, privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.alexecollins.agents.remote", category: "walk")
}
#endif
