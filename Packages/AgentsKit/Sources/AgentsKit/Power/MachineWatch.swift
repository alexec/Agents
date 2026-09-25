import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Something about the Mac or the person at it changed (042 US5).
public enum MachineChange: Hashable, Sendable {
    case sleep
    case wake
    /// Locked, or idle past the threshold. `why` is "locked" or "idle".
    case away(why: String)
    case back(why: String)
}

/// What tells the daemon about the Mac: sleeping and waking, and the person locking the
/// screen or stepping away. A protocol so a test can sleep a Mac without closing a lid.
public protocol MachineWatch: AnyObject, Sendable {
    func start(_ report: @escaping @Sendable (MachineChange) -> Void)
    func stop()
}

/// The real one (042 research R10, as built).
///
/// `agentsd` is a helper with no AppKit and no run loop — `dispatchMain` parks its main
/// thread — so nothing here waits on a notification that needs one. Sleep and wake come
/// from IOKit's power messages, delivered on a dispatch queue. The screen being locked
/// and the person being idle are read, every few seconds, from the session dictionary
/// and the HID idle time, which answer to anyone asking and need nothing delivered.
public final class IOKitMachineWatch: MachineWatch, @unchecked Sendable {
    /// No input for this long is "away" (spec, Assumptions: fixed in this version).
    public static let idleThreshold: TimeInterval = 5 * 60
    static let lookEvery: TimeInterval = 10

    private let queue = DispatchQueue(label: "agents.machine-watch")
    private var report: (@Sendable (MachineChange) -> Void)?
    private var timer: DispatchSourceTimer?
    private var away: String?
    #if canImport(IOKit)
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    #endif

    public init() {}

    public func start(_ report: @escaping @Sendable (MachineChange) -> Void) {
        queue.sync {
            self.report = report
            startPower()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.lookEvery, repeating: Self.lookEvery)
            timer.setEventHandler { [weak self] in self?.look() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            report = nil
            #if canImport(IOKit)
            if notifier != 0 { IODeregisterForSystemPower(&notifier) }
            if let notifyPort { IONotificationPortDestroy(notifyPort) }
            if rootPort != 0 { IOServiceClose(rootPort) }
            notifier = 0; notifyPort = nil; rootPort = 0
            #endif
        }
    }

    // MARK: Locked or idle

    private func look() {
        let locked = Self.screenIsLocked()
        let idle = Self.idleSeconds().map { $0 >= Self.idleThreshold } ?? false
        let now: String? = locked ? "locked" : (idle ? "idle" : nil)
        guard now != away else { return }
        if let was = away { report?(.back(why: was)) }
        // Locked outranks idle: somebody who locked the screen is not also "idle".
        if let now { report?(.away(why: now)) }
        away = now
    }

    static func screenIsLocked() -> Bool {
        #if canImport(CoreGraphics)
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
        #else
        return false
        #endif
    }

    static func idleSeconds() -> TimeInterval? {
        #if canImport(IOKit)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = (value as? NSNumber)?.uint64Value else { return nil }
        return TimeInterval(nanoseconds) / 1_000_000_000
        #else
        return nil
        #endif
    }

    // MARK: Sleep and wake

    private func startPower() {
        #if canImport(IOKit)
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, message, argument in
            guard let context else { return }
            let watch = Unmanaged<IOKitMachineWatch>.fromOpaque(context).takeUnretainedValue()
            watch.power(message: message, argument: argument)
        }, &notifier)
        if rootPort != 0, let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, queue) }
        #endif
    }

    #if canImport(IOKit)
    // IOKit's messages are C macros Swift does not import: `iokit_common_msg(0x280)`
    // and its neighbours, from IOMessage.h.
    static let systemWillSleep: natural_t = 0xE000_0280
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemHasPoweredOn: natural_t = 0xE000_0300

    private func power(message: natural_t, argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.systemWillSleep:
            report?(.sleep)
            // Said, then let go: holding a sleep up is not this watch's business.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            report?(.wake)
        default:
            break
        }
    }
    #endif
}
