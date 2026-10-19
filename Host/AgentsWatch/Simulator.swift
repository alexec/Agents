// agents-watch --simulator tap <udid> <x> <y> | home <udid> (#842): a touch on a booted iOS
// simulator's screen, or its Home button, for the Simulator pane. simctl has no way to send a
// touch, and a click into Simulator.app would move the person's own pointer, so this sends it
// as Simulator.app does: an Indigo HID message through SimulatorKit's HID client, both private
// frameworks of the Xcode the Mac has selected. x and y are where on the screen, from 0 to 1.
// It exits 0 once the message is sent, and says why on standard error when it cannot be.
import AppKit
import Foundation

func touchSimulator(_ arguments: [String]) -> Never {
    func fail(_ why: String) -> Never {
        FileHandle.standardError.write(Data((why + "\n").utf8))
        exit(1)
    }
    let usage = "usage: agents-watch --simulator tap <udid> <x> <y> | home <udid>"
    guard arguments.count >= 2, let udid = UUID(uuidString: arguments[1]) else { fail(usage) }
    let verb = arguments[0]
    let developer = selectedDeveloperDir()
    let xcode = URL(fileURLWithPath: developer).deletingLastPathComponent().path
    guard dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != nil,
          let kit = dlopen(xcode + "/SharedFrameworks/SimulatorKit.framework/SimulatorKit", RTLD_NOW)
    else { fail("Xcode's simulator frameworks did not load.") }

    // The device, from CoreSimulator's own list.
    guard let contextClass = NSClassFromString("SimServiceContext") as? NSObject.Type,
          let context = contextClass.perform(NSSelectorFromString("sharedServiceContextForDeveloperDir:error:"),
                                             with: developer, with: nil)?.takeUnretainedValue(),
          let set = context.perform(NSSelectorFromString("defaultDeviceSetWithError:"), with: nil)?.takeUnretainedValue(),
          let devices = set.value(forKey: "devicesByUDID") as? [UUID: AnyObject],
          let device = devices[udid]
    else { fail("No simulator \(udid.uuidString) on this Mac.") }

    // SimulatorKit's HID client for it.
    guard let clientClass = NSClassFromString("SimulatorKit.SimDeviceLegacyHIDClient") as? NSObject.Type else {
        fail("This Xcode has no simulator HID client.")
    }
    typealias Make = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
    let makeSelector = NSSelectorFromString("initWithDevice:error:")
    guard let blank = clientClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
          let makeIMP = class_getMethodImplementation(clientClass, makeSelector) else { fail("No HID client.") }
    var error: NSError?
    guard let client = unsafeBitCast(makeIMP, to: Make.self)(blank, makeSelector, device, &error) else {
        fail("The simulator's HID client did not start: \(error?.localizedDescription ?? "no reason given")")
    }
    typealias Send = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue?,
                                     (@convention(block) (NSError?) -> Void)?) -> Void
    let sendSelector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
    guard let sendIMP = class_getMethodImplementation(clientClass, sendSelector) else { fail("No HID send.") }
    let send = unsafeBitCast(sendIMP, to: Send.self)
    let sent = DispatchSemaphore(value: 0)
    func post(_ message: UnsafeMutableRawPointer) {
        var failed: String?
        send(client, sendSelector, message, true, DispatchQueue.global()) { error in
            failed = error?.localizedDescription
            sent.signal()
        }
        sent.wait()
        if let failed { fail("The simulator did not take it: \(failed)") }
    }

    switch verb {
    case "tap":
        guard arguments.count == 4, let x = Double(arguments[2]), let y = Double(arguments[3]),
              (0...1).contains(x), (0...1).contains(y) else { fail(usage) }
        typealias Mouse = @convention(c) (UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>?, UInt32,
                                          UInt, Bool) -> UnsafeMutableRawPointer
        guard let symbol = dlsym(kit, "IndigoHIDMessageForMouseNSEvent") else { fail("No touch message here.") }
        let mouse = unsafeBitCast(symbol, to: Mouse.self)
        // Down, then up: the message holds two payloads, and the ratios it works out are not
        // the screen's, so both are set (xRatio and yRatio at 60 and 68 in each 160-byte one).
        for phase: UInt in [1, 2] {
            var point = CGPoint(x: x, y: y)
            let message = mouse(&point, nil, 0x32, phase, false)
            for payload in [0, 160] {
                message.storeBytes(of: x, toByteOffset: 60 + payload, as: Double.self)
                message.storeBytes(of: y, toByteOffset: 68 + payload, as: Double.self)
            }
            post(message)
            usleep(60_000)
        }
    case "home":
        typealias Button = @convention(c) (Int32, Int32, Int32) -> UnsafeMutableRawPointer
        guard let symbol = dlsym(kit, "IndigoHIDMessageForButton") else { fail("No button message here.") }
        let button = unsafeBitCast(symbol, to: Button.self)
        // The Home button (source 0), down then up, to the hardware buttons (0x33).
        for phase: Int32 in [1, 2] {
            post(button(0, phase, 0x33))
            usleep(60_000)
        }
    default:
        fail(usage)
    }
    exit(0)
}

/// The Xcode the Mac has selected, as `xcode-select -p` says.
private func selectedDeveloperDir() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let path = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? "/Applications/Xcode.app/Contents/Developer" : path
}
