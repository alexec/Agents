@testable import CodeText
import Testing

/// Which language a file or a fenced block is (041 FR-003, FR-005).
struct LanguageTests {
    @Test(arguments: [
        ("a.swift", CodeLanguage.swift), ("A.SWIFT", .swift),
        ("x.m", .c), ("x.mm", .cpp), ("x.h", .c), ("x.hpp", .cpp),
        ("x.tsx", .tsx), ("x.ts", .typescript), ("x.jsx", .javascript), ("x.mjs", .javascript),
        ("Dockerfile", .dockerfile), ("Makefile", .make), ("x.mk", .make),
        ("Gemfile", .ruby), (".zshrc", .bash), ("deploy.sh", .bash),
        ("config.yml", .yaml), ("Cargo.toml", .toml), ("README.md", .markdown),
        ("/Users/x/Project/Sources/App.swift", .swift),
    ])
    func aFileIsKnownByItsNameOrExtension(path: String, expected: CodeLanguage) {
        #expect(CodeLanguage.detect(path: path, firstLine: nil) == expected)
    }

    @Test(arguments: [
        ("#!/usr/bin/env python3", CodeLanguage.python),
        ("#!/usr/local/bin/python3.12", .python),
        ("#!/bin/zsh", .bash),
        ("#!/bin/sh -e", .bash),
        ("#!/usr/bin/env -S node --no-warnings", .javascript),
        ("#!/usr/bin/ruby", .ruby),
    ])
    func aScriptWithNoExtensionIsKnownByItsFirstLine(line: String, expected: CodeLanguage) {
        #expect(CodeLanguage.detect(path: "tools/run", firstLine: line[...]) == expected)
    }

    @Test(arguments: ["x.kt", "x.kts", "x.sql", "x.xyz", "notes", "LICENSE"])
    func anythingElseIsPlainNotGuessed(path: String) {
        #expect(CodeLanguage.detect(path: path, firstLine: nil) == nil)
        #expect(CodeLanguage.detect(path: path, firstLine: "let x = 1") == nil)
    }

    @Test func theExtensionBeatsTheFirstLine() {
        #expect(CodeLanguage.detect(path: "x.rb", firstLine: "#!/usr/bin/env python3") == .ruby)
    }

    @Test(arguments: [
        ("ts", CodeLanguage.typescript), ("py", .python), ("sh", .bash), ("shell", .bash),
        ("zsh", .bash), ("yml", .yaml), ("objc", .c), ("objective-c", .c), ("Swift", .swift),
        ("swift {.line-numbers}", .swift), ("js title=\"a.js\"", .javascript), ("c++", .cpp),
    ])
    func aFenceIsKnownByItsTag(tag: String, expected: CodeLanguage) {
        #expect(CodeLanguage.fence(tag: tag) == expected)
    }

    @Test(arguments: [nil, "", "text", "sql", "kotlin", "console", "{.x}"] as [String?])
    func anUnknownFenceIsPlain(tag: String?) {
        #expect(CodeLanguage.fence(tag: tag) == nil)
    }
}
