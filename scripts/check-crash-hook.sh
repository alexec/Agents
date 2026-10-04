#!/bin/zsh
# The window's crash hook (#76, #178) names the exception that kills it. Builds
# App/Sources/CrashHook.swift into a small AppKit program of its own (never the app),
# lets it crash each way the window has, and checks the note it left:
#
#   layout       a view throws in layout(); AppKit traps (SIGTRAP), and the exception
#                reaches neither NSSetUncaughtExceptionHandler nor reportException:
#   runloop      a block on the main run loop throws; NSApplication reports it and goes
#                on, so the program must live and leave no note (a note is a crash)
#   displaylink  a display-link callback throws, as the window's 2026-10-01 17:08 crash
#                did, which ends in abort (SIGABRT)
#
#   scripts/check-crash-hook.sh [mode…]     (all three by default)

set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d /tmp/check-crash-hook.XXXXXX)
trap "${KEEP_WORK:+:} rm -rf $work" EXIT
modes=($@)
(( $#modes )) || modes=(layout runloop displaylink)

cat > $work/main.swift <<'SWIFT'
import AppKit
final class ThrowingInLayout: NSView {
    var armed = false
    override func layout() {
        super.layout()
        if armed { NSException(name: .internalInconsistencyException, reason: "thrown in layout", userInfo: nil).raise() }
    }
}
final class ThrowingOnFrame: NSObject {
    @objc func step(_ link: CADisplayLink) {
        NSException(name: .internalInconsistencyException, reason: "thrown from a display link", userInfo: nil).raise()
    }
}
func throwOnRunLoop() {
    NSException(name: .internalInconsistencyException, reason: "thrown on the main run loop", userInfo: nil).raise()
}
let mode = CommandLine.arguments[2]
CrashHook.install(in: URL(fileURLWithPath: CommandLine.arguments[1]))
NSApplication.shared.setActivationPolicy(.prohibited)
var kept: [AnyObject] = []
switch mode {
case "layout":
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    let view = ThrowingInLayout()
    window.contentView = view
    window.orderBack(nil)
    kept = [window]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.armed = true; view.needsLayout = true }
case "runloop":
    RunLoop.main.perform { throwOnRunLoop() }
case "displaylink":
    let target = ThrowingOnFrame()
    let link = NSScreen.screens[0].displayLink(target: target, selector: #selector(ThrowingOnFrame.step(_:)))
    link.add(to: .main, forMode: .common)
    kept = [target, link]
default:
    fatalError("no mode \(mode)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + (mode == "runloop" ? 2 : 10)) { exit(0) }
NSApplication.shared.run()
SWIFT

swiftc -swift-version 6 -warnings-as-errors $root/App/Sources/CrashHook.swift $work/main.swift -o $work/hook

for mode in $modes; do
    case $mode in
        layout) reason='thrown in layout'; frame='ThrowingInLayout.*layout' ;;
        runloop) reason='thrown on the main run loop'; frame='throwOnRunLoop' ;;
        displaylink) reason='thrown from a display link'; frame='ThrowingOnFrame.*step' ;;
        *) print -u2 "no mode $mode"; exit 2 ;;
    esac
    code=0
    $work/hook $work/$mode $mode 2>$work/$mode.err || code=$?
    if [[ $mode == runloop ]]; then
        (( code == 0 )) || { print -u2 "runloop: expected the program to go on after AppKit reported it, got $code"; exit 1 }
        notes=($work/$mode/crash-*.txt(N))
        (( ${#notes} == 0 )) || { print -u2 "runloop: a note for an exception that killed nothing"; exit 1 }
        print "runloop: AppKit caught it, the program went on, and there is no note."
        continue
    fi
    # 133 is SIGTRAP (AppKit's own trap), 134 SIGABRT (an uncaught exception's abort):
    # either way the signal was put back after the note was written.
    (( code == 133 || code == 134 )) || { print -u2 "$mode: expected the program to die of SIGTRAP or SIGABRT, got $code"; exit 1 }
    notes=($work/$mode/crash-*.txt(N))
    (( ${#notes} == 1 )) || { print -u2 "$mode: expected one crash note, found ${#notes}"; exit 1 }
    grep -q '^Name: NSInternalInconsistencyException$' $notes[1] || { print -u2 "$mode: the note has no name"; cat $notes[1]; exit 1 }
    grep -q "^Reason: $reason\$" $notes[1] || { print -u2 "$mode: the note has no reason"; cat $notes[1]; exit 1 }
    grep -q "$frame" $notes[1] || { print -u2 "$mode: the note does not name the code that threw"; cat $notes[1]; exit 1 }
    grep -q 'may not be what killed it' $notes[1] && { print -u2 "$mode: a fresh exception was written as stale"; exit 1 }
    print "$mode: died of $(( code - 128 )), and the note names the exception and the code that threw it."
done
