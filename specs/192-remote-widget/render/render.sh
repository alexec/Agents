#!/bin/zsh
# Draws the Needs you widget's sizes to PNGs in specs/192-remote-widget/ (#192).
#
# Builds a throwaway Mac package in $TMPDIR from the widget's real view files, the real
# AgentsKitCore, Paper and StateTint, and TypeScaleShim.swift in place of the type scale.
# No simulator: these are drawn by ImageRenderer on this Mac at the phone's type sizes.
set -euo pipefail
here=${0:A:h}
root=${here:h:h:h}
work=${TMPDIR:-/tmp}/widget-render-192
rm -rf "$work"
mkdir -p "$work/Sources/Render"
ln -s "$root/Packages/AgentsKit/Sources/AgentsKitCore" "$work/Sources/AgentsKitCore"
for f in RemoteWidget/Sources/AttentionEntryView.swift RemoteWidget/Sources/AttentionProvider.swift \
         Shared/UI/Paper.swift Shared/UI/StateTint.swift; do
  ln -s "$root/$f" "$work/Sources/Render/${f:t}"
done
ln -s "$here/TypeScaleShim.swift" "$work/Sources/Render/TypeScaleShim.swift"
ln -s "$here/main.swift" "$work/Sources/Render/main.swift"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "WidgetRender",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "AgentsKitCore"),
        .executableTarget(name: "Render", dependencies: ["AgentsKitCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ])
PKG
swift build --package-path "$work" -c debug
"$work/.build/debug/Render" "${here:h}"
