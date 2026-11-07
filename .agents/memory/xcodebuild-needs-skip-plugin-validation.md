---
name: xcodebuild-needs-skip-plugin-validation
description: Command-line xcodebuild of the Agents/Remote schemes fails silently on SwiftTerm's plugin validation unless -skipPackagePluginValidation is passed.
metadata:
  type: reference
---

Building from the shell in this repo needs:

```
xcodebuild -scheme Agents -configuration Debug -skipPackagePluginValidation -skipMacroValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation -skipMacroValidation build
```

**Why:** Without the flags the build fails with "Validate plug-in SwiftTermBuildInfoPlugin"
and no compiler error at all, which looks like a broken source change. The two schemes
also share one DerivedData build database, so run them one after the other, never in
parallel. `xcodegen generate` must run first if project.yml changed.

**How to apply:** Use these exact invocations for any build check; the "No macOS
settings found" lines from xcodegen are normal.

Related: [[agents-app-hosts-this-session]].

`xcodebuild -list` does **not** list the `Remote` scheme even though
`Agents.xcodeproj/xcshareddata/xcschemes/Remote.xcscheme` exists — check that directory
rather than `-list`. Falling back to `-target Remote` builds `RemoteNotify` without the
package graph and fails with "Unable to resolve module dependency: 'AgentsKitCore'".
