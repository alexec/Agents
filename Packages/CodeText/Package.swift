// swift-tools-version: 6.2
import PackageDescription

// Code, coloured and diffed, for the two apps (041).
//
// A package of its own rather than part of AgentsKit, because `agentsd` links AgentsKit and
// the daemon has no business carrying seventeen megabytes of parsers: it moves text, it does
// not read it. The Mac app and the Remote link this; nothing else does.
//
// Each grammar is tree-sitter's generated C, vendored by `scripts/vendor-grammars.sh` at a
// pinned tag (research R2), and compiled as its own small C target. Adding a language is a
// name in `grammars` below, a row in the script's table, and a case in `CodeLanguage`.
//
// Written as a string rather than `.macOS(.v27)`: this tools version has no `.v27` case.

// Each grammar, and whether it has a hand-written scanner beside its generated parser.
// Said here rather than looked for on disk: a manifest cannot see files reliably, which is
// how tree-sitter-python's own manifest comes to lose its scanner.
let grammars: [(name: String, scanner: Bool)] = [
    ("swift", true), ("c", false), ("cpp", true), ("python", true), ("javascript", true),
    ("typescript", true), ("tsx", true), ("json", false), ("go", false), ("rust", true),
    ("java", false), ("ruby", true), ("bash", true), ("yaml", true), ("toml", true),
    ("html", true), ("css", true), ("markdown", true), ("dockerfile", true), ("make", false),
]

let grammarTargets: [Target] = grammars.map { grammar in
    .target(
        name: "TS_\(grammar.name)",
        path: "Grammars/TS_\(grammar.name)",
        // Only these are compiled. Anything else in the folder is there because one of
        // them includes it (yaml's schema tables), and compiling it again would clash.
        sources: grammar.scanner ? ["parser.c", "scanner.c"] : ["parser.c"],
        cSettings: [
            .headerSearchPath("."),
            // Generated code, not ours to tidy.
            .unsafeFlags(["-w"]),
        ])
}

let package = Package(
    name: "CodeText",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "CodeText", targets: ["CodeText"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
    ],
    targets: grammarTargets + [
        .target(
            name: "CodeText",
            dependencies: [.product(name: "SwiftTreeSitter", package: "swift-tree-sitter")]
                + grammars.map { .target(name: "TS_\($0.name)") },
            resources: [.copy("Queries")]),
        .testTarget(
            name: "CodeTextTests",
            dependencies: ["CodeText"],
            resources: [.copy("Samples")]),
    ]
)
