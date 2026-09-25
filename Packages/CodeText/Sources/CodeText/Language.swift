import Foundation

/// A kind of code the app can colour (041 FR-002, research R2).
///
/// Twenty, each with a vendored grammar. Kotlin and SQL are not here on purpose: their
/// grammars cost more app size than the rest together, so they are shown plain. Objective-C
/// has no case of its own and is coloured as C.
public enum CodeLanguage: String, CaseIterable, Sendable {
    case swift, c, cpp, python, javascript, typescript, tsx, json, go, rust, java,
         ruby, bash, yaml, toml, html, css, markdown, dockerfile, make

    /// The language of a file, from its name, then its extension, then a `#!` first line.
    /// Nil when none of them say: never a guess from what the text looks like (FR-005).
    public static func detect(path: String, firstLine: Substring?) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent
        if let byName = byFileName[name] ?? byFileName[name.lowercased()] {
            return byName
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let byExt = byExtension[ext] {
            return byExt
        }
        if let firstLine, let program = interpreter(in: firstLine) {
            return byInterpreter[program]
        }
        return nil
    }

    /// The language of a fenced block, from its tag: `ts`, `py`, `swift {.numbered}`.
    public static func fence(tag: String?) -> CodeLanguage? {
        guard let tag else { return nil }
        let word = tag.lowercased()
            .prefix { !$0.isWhitespace && $0 != "{" }
        return word.isEmpty ? nil : byFence[String(word)]
    }

    // MARK: Tables

    private static let byExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "c": .c, "h": .c, "m": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp,
        "mm": .cpp,
        "py": .python, "pyi": .python, "pyw": .python,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "json": .json, "jsonc": .json, "json5": .json, "jsonl": .json,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby,
        "sh": .bash, "bash": .bash, "zsh": .bash, "command": .bash,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "html": .html, "htm": .html, "xhtml": .html,
        "css": .css,
        "md": .markdown, "markdown": .markdown,
        "dockerfile": .dockerfile,
        "mk": .make, "mak": .make,
    ]

    private static let byFileName: [String: CodeLanguage] = [
        "Dockerfile": .dockerfile, "Containerfile": .dockerfile,
        "Makefile": .make, "makefile": .make, "GNUmakefile": .make,
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Fastfile": .ruby,
        "Brewfile": .ruby,
        ".zshrc": .bash, ".zprofile": .bash, ".zshenv": .bash, ".bashrc": .bash,
        ".bash_profile": .bash, ".profile": .bash,
        "Package.resolved": .json, ".babelrc": .json, ".eslintrc": .json,
        "Cargo.lock": .toml, "Pipfile": .toml,
    ]

    private static let byInterpreter: [String: CodeLanguage] = [
        "sh": .bash, "bash": .bash, "zsh": .bash, "dash": .bash, "ksh": .bash,
        "python": .python, "python3": .python, "python2": .python,
        "node": .javascript, "deno": .typescript, "bun": .javascript,
        "ruby": .ruby,
        "swift": .swift,
        "make": .make,
    ]

    private static let byFence: [String: CodeLanguage] = [
        "swift": .swift,
        "c": .c, "h": .c, "objc": .c, "objective-c": .c, "objectivec": .c,
        "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "objective-c++": .cpp,
        "objc++": .cpp,
        "python": .python, "py": .python, "python3": .python,
        "javascript": .javascript, "js": .javascript, "jsx": .javascript, "node": .javascript,
        "mjs": .javascript,
        "typescript": .typescript, "ts": .typescript,
        "tsx": .tsx,
        "json": .json, "jsonc": .json, "json5": .json,
        "go": .go, "golang": .go,
        "rust": .rust, "rs": .rust,
        "java": .java,
        "ruby": .ruby, "rb": .ruby,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash,
        "yaml": .yaml, "yml": .yaml,
        "toml": .toml,
        "html": .html, "htm": .html, "xhtml": .html,
        "css": .css,
        "markdown": .markdown, "md": .markdown,
        "dockerfile": .dockerfile, "docker": .dockerfile,
        "make": .make, "makefile": .make, "mk": .make,
    ]

    /// The program a `#!` line runs, with any directory and version stripped:
    /// `#!/usr/bin/env python3` and `#!/usr/local/bin/python3.12` both give `python3`.
    private static func interpreter(in line: Substring) -> String? {
        guard line.hasPrefix("#!") else { return nil }
        var words = line.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard var program = words.first.map({ ($0 as NSString).lastPathComponent }) else {
            return nil
        }
        if program == "env" {
            words.removeFirst()
            // `env -S python3 -u`: skip env's own flags.
            guard let next = words.first(where: { !$0.hasPrefix("-") }) else { return nil }
            program = next
        }
        // python3.12 → python3; ruby2.7 → ruby
        if let dot = program.firstIndex(of: "."), byInterpreter[program] == nil {
            program = String(program[..<dot])
        }
        while byInterpreter[program] == nil, let last = program.last, last.isNumber {
            program.removeLast()
        }
        return program
    }
}
