// agents-watch --machine [locked|idle] (#1368): the Mac and the person at it, for the Go
// agentsd, which cannot reach IOKit or CoreGraphics without cgo. As the Swift host's
// IOKitMachineWatch: sleep and wake from IOKit's power messages, and the screen being locked
// or the person idle past five minutes read every ten seconds.
//
// The argument is how the person stood when the last host heard (#1219), so the first look
// neither says an away twice nor misses a return in the gap. It writes each change ended by a
// NUL byte (`sleep`, `wake`, `away:locked`, `back:idle`, …), and `\0ready\0` once the first
// look is done. It ends when its standard input closes.
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt

/// No input for this long is "away".
private let idleThreshold: TimeInterval = 5 * 60
private let lookEvery: TimeInterval = 10

private let machineQueue = DispatchQueue(label: "agents-watch.machine")
private var away: String?
private var rootPort: io_connect_t = 0
private var notifyPort: IONotificationPortRef?
private var notifier: io_object_t = 0

// IOKit's messages are C macros Swift does not import (IOMessage.h).
private let systemWillSleep: natural_t = 0xE000_0280
private let canSystemSleep: natural_t = 0xE000_0270
private let systemHasPoweredOn: natural_t = 0xE000_0300

private func tell(_ word: String) {
    var data = Data(word.utf8)
    data.append(0)
    FileHandle.standardOutput.write(data)
}

private func screenIsLocked() -> Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
}

private func idleSeconds() -> TimeInterval? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue(), let nanoseconds = (value as? NSNumber)?.uint64Value else { return nil }
    return TimeInterval(nanoseconds) / 1_000_000_000
}

private func look() {
    let idle = idleSeconds().map { $0 >= idleThreshold } ?? false
    // Locked outranks idle: somebody who locked the screen is not also "idle".
    let now: String? = screenIsLocked() ? "locked" : (idle ? "idle" : nil)
    guard now != away else { return }
    if let was = away { tell("back:\(was)") }
    if let now { tell("away:\(now)") }
    away = now
}

func watchMachine(assumingAway assumed: String?) -> Never {
    signal(SIGPIPE, SIG_IGN)
    machineQueue.sync {
        away = assumed == "locked" || assumed == "idle" ? assumed : nil
        rootPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, message, argument in
            switch message {
            case systemWillSleep:
                tell("sleep")
                // Said, then let go: holding a sleep up is not this watch's business.
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            case canSystemSleep:
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            case systemHasPoweredOn:
                tell("wake")
            default:
                break
            }
        }, &notifier)
        if rootPort != 0, let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, machineQueue) }
        look()
        tell("")
        tell("ready")
    }
    let timer = DispatchSource.makeTimerSource(queue: machineQueue)
    timer.schedule(deadline: .now() + lookEvery, repeating: lookEvery)
    timer.setEventHandler { look() }
    timer.resume()
    // The host lets go by closing our standard input; reading it to its end is the wait.
    _ = FileHandle.standardInput.readDataToEndOfFile()
    timer.cancel()
    exit(0)
}
