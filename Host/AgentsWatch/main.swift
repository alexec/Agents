// agents-watch (#1138): the Go agentsd's folder watch on a Mac. FSEvents needs CoreServices,
// which Go cannot reach without cgo, so the Go host runs this beside it in Agents Host's
// Helpers, one for each folder it watches.
//
//   agents-watch <folder>
//
// It writes `\0ready\0` once FSEvents is watching, then every path under the folder that
// changed, each ended by a NUL byte, as FSEvents
// says them (resolved: /tmp is /private/tmp), a quarter of a second at a time, and `\0gone\0`
// if the folder itself goes. It ends when its standard input closes, which is when the host
// that started it lets it go or is gone.
//
//   agents-watch --machine [locked|idle]
//
// watches the Mac and the person at it instead (#1368, Machine.swift).
//
//   agents-watch --simulator tap <udid> <x> <y> | home <udid>
//
// touches a booted simulator's screen, or presses its Home button (#842, Simulator.swift).
import CoreServices
import Foundation

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--simulator" {
    touchSimulator(Array(CommandLine.arguments.dropFirst(2)))
}
if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--machine" {
    watchMachine(assumingAway: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: agents-watch <folder> | --machine [locked|idle]\n".utf8))
    exit(64)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
signal(SIGPIPE, SIG_IGN)

let out = FileHandle.standardOutput
func say(_ path: String) {
    var data = Data(path.utf8)
    data.append(0)
    out.write(data)
}

let callback: FSEventStreamCallback = { _, _, count, paths, flags, _ in
    let all = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
    for index in 0..<min(count, all.count) {
        let flag = flags[index]
        if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
            say("")
            say("gone")
            continue
        }
        say(all[index])
    }
}

let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
    kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
guard let stream = FSEventStreamCreate(nil, callback, nil, [folder] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags) else {
    FileHandle.standardError.write(Data("agents-watch: FSEvents would not watch \(folder)\n".utf8))
    exit(1)
}
let queue = DispatchQueue(label: "agents-watch")
FSEventStreamSetDispatchQueue(stream, queue)
guard FSEventStreamStart(stream) else {
    FileHandle.standardError.write(Data("agents-watch: FSEvents would not start on \(folder)\n".utf8))
    exit(1)
}
// Said on the stream's own queue, so it is never interleaved with a path.
queue.sync {
    say("")
    say("ready")
}

// The host lets go by closing our standard input; reading it to its end is the wait.
_ = FileHandle.standardInput.readDataToEndOfFile()
FSEventStreamStop(stream)
FSEventStreamInvalidate(stream)
FSEventStreamRelease(stream)
exit(0)
