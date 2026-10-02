#!/bin/zsh
# The window's crash hook (#76) names the exception AppKit traps on during layout, which
# reaches neither NSSetUncaughtExceptionHandler nor reportException:. Builds
# App/Sources/CrashHook.swift into a small AppKit program whose view throws in layout(),
# lets it crash, and checks the note it left: the reason and the view that threw.
#
#   scripts/check-crash-hook.sh

set -euo pipefail
root=${0:A:h:h}
work=$(mktemp -d /tmp/check-crash-hook.XXXXXX)
trap 'rm -rf $work' EXIT

cat > $work/main.swift <<'SWIFT'
import AppKit
final class ThrowingInLayout: NSView {
    var armed = false
    override func layout() {
        super.layout()
        if armed { NSException(name: .internalInconsistencyException, reason: "thrown in layout", userInfo: nil).raise() }
    }
}
CrashHook.install(in: URL(fileURLWithPath: CommandLine.arguments[1]))
NSApplication.shared.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
let view = ThrowingInLayout()
window.contentView = view
window.orderBack(nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.armed = true; view.needsLayout = true }
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
NSApplication.shared.run()
SWIFT

swiftc -swift-version 6 -warnings-as-errors $root/App/Sources/CrashHook.swift $work/main.swift -o $work/hook
code=0
$work/hook $work/notes || code=$?
# 133 is SIGTRAP: AppKit's own trap, put back after the note was written.
(( code == 133 )) || { print -u2 "expected the program to die of SIGTRAP (133), got $code"; exit 1 }
notes=($work/notes/crash-*.txt(N))
(( ${#notes} == 1 )) || { print -u2 "expected one crash note, found ${#notes}"; exit 1 }
grep -q '^Name: NSInternalInconsistencyException$' $notes[1] || { print -u2 "the note has no name"; cat $notes[1]; exit 1 }
grep -q '^Reason: thrown in layout$' $notes[1] || { print -u2 "the note has no reason"; cat $notes[1]; exit 1 }
grep -q 'ThrowingInLayout.*layout' $notes[1] || { print -u2 "the note does not name the view"; cat $notes[1]; exit 1 }
print "The crash hook names the exception and the view that threw it."
