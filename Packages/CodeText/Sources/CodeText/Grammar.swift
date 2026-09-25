import Foundation
import os
import SwiftTreeSitter
import TS_bash
import TS_c
import TS_cpp
import TS_css
import TS_dockerfile
import TS_go
import TS_html
import TS_java
import TS_javascript
import TS_json
import TS_make
import TS_markdown
import TS_python
import TS_ruby
import TS_rust
import TS_swift
import TS_toml
import TS_tsx
import TS_typescript
import TS_yaml

/// Each language's parser and highlight query (041 research R2, R8).
enum Grammar {
    /// The parser for a language. Optional so a language can be listed before its grammar is
    /// vendored; all twenty are vendored now.
    static func language(for code: CodeLanguage) -> Language? {
        let pointer: OpaquePointer? = switch code {
        case .swift: tree_sitter_swift()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .json: tree_sitter_json()
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .java: tree_sitter_java()
        case .ruby: tree_sitter_ruby()
        case .bash: tree_sitter_bash()
        case .yaml: tree_sitter_yaml()
        case .toml: tree_sitter_toml()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .markdown: tree_sitter_markdown()
        case .dockerfile: tree_sitter_dockerfile()
        case .make: tree_sitter_make()
        }
        return pointer.map { Language(language: $0) }
    }

    /// The compiled query for a language: built on first use, off the main actor, and kept
    /// for the life of the process. Swift's takes a tenth of a second or more to compile,
    /// so it is done once, and most sessions never open most languages (R8).
    static func query(for code: CodeLanguage) async -> Query? {
        await cache.query(for: code)
    }

    /// The query's source, as vendored.
    static func queryText(for code: CodeLanguage) -> String? {
        guard let url = queryURL(for: code) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func queryURL(for code: CodeLanguage) -> URL? {
        Bundle.module.url(forResource: code.rawValue, withExtension: "scm", subdirectory: "Queries")
    }

    private static let cache = QueryCache()
    static let log = Logger(subsystem: "com.alexecollins.Agents", category: "CodeText")
}

private actor QueryCache {
    private var compiled: [CodeLanguage: Query] = [:]
    /// Languages whose query would not compile: tried once, then shown plain, never retried.
    private var failed: Set<CodeLanguage> = []

    func query(for code: CodeLanguage) -> Query? {
        if let query = compiled[code] { return query }
        guard !failed.contains(code), let language = Grammar.language(for: code) else {
            return nil
        }
        do {
            guard let url = Grammar.queryURL(for: code) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let query = try Query(language: language, data: Data(contentsOf: url))
            compiled[code] = query
            return query
        } catch {
            // A query that does not match its grammar's version. Plain is the right answer
            // for the person; the log is for whoever vendors the next one.
            Grammar.log.error("The \(code.rawValue, privacy: .public) query did not compile: \(String(describing: error), privacy: .public)")
            failed.insert(code)
            return nil
        }
    }
}
