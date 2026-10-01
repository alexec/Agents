import Foundation
import SwiftParser
import SwiftSyntax

/// Makes Web/src/protocol/generated.ts from AgentsKitCore's source (071, research R6,
/// contracts/generated-types.md).
///
/// The roots are the rows of `DaemonAPI.WebSignatures`; every type they reach is emitted,
/// from wherever in AgentsKitCore it is declared. The same source always gives the same
/// bytes: types sorted by name, and no date or commit in the header.
public struct Generator: Sendable {
    /// Where the output goes, from the repository root.
    public static let output = "Web/src/protocol/generated.ts"
    /// Every Swift file under here is read. Types reach across the module freely.
    public static let sources = "Packages/AgentsKit/Sources/AgentsKitCore"
    /// The method table, inside `sources`.
    public static let signatures = "Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Web.swift"
    /// Hand-written TypeScript for types whose encoding is written by hand in Swift.
    public static let overrides = "Packages/WebTypes/Overrides"

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public let root: URL

    public init(root: URL) { self.root = root }

    /// The repository paths of every input file, sorted.
    public func inputFiles() throws -> [String] {
        let folder = root.appending(path: Self.sources)
        guard let walker = FileManager.default.enumerator(atPath: folder.path) else {
            throw Failure("\(Self.sources) is an input but does not exist")
        }
        let paths = walker.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.map { Self.sources + "/" + $0 }
        guard !paths.isEmpty else { throw Failure("\(Self.sources) has no Swift files") }
        guard paths.contains(Self.signatures) else { throw Failure("\(Self.signatures) is missing") }
        return paths.sorted()
    }

    /// Every input file, parsed.
    public func parse() throws -> [(path: String, syntax: SourceFileSyntax)] {
        try inputFiles().map { path in
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            return (path, Parser.parse(source: text))
        }
    }

    /// generated.ts, as it should be now.
    public func generate() throws -> String {
        var overrides: [String: String] = [:]
        let folder = root.appending(path: Self.overrides)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".ts") {
            overrides[String(name.dropLast(3))] = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
        }
        return try Self.generate(files: try parse(), signatures: Self.signatures, overrides: overrides)
    }

    /// The emitter on parsed sources: what `generate()` runs, and what the tests run on
    /// sources of their own.
    static func generate(files: [(path: String, syntax: SourceFileSyntax)], signatures: String,
                         overrides: [String: String]) throws -> String {
        var declarations = Declarations()
        for file in files { declarations.read(file.syntax, file: file.path) }
        declarations.finish()
        guard let table = files.first(where: { $0.path == signatures }) else { throw Failure("\(signatures) is missing") }
        do {
            let rows = try SignatureReader.read(table.syntax, file: table.path, constants: declarations.constants)
            var emitter = Emitter(declarations: declarations, overrides: overrides, signatures: rows,
                                  signatureScope: ["DaemonAPI", "WebSignatures"])
            return try emitter.render()
        } catch let failure as Emitter.Failure {
            throw Failure(failure.description)
        } catch let failure as TypeRef.Failure {
            throw Failure(failure.description)
        }
    }

    static func generate(sources: [String: String], signatures: String, overrides: [String: String] = [:]) throws -> String {
        try generate(files: sources.sorted { $0.key < $1.key }.map { ($0.key, Parser.parse(source: $0.value)) },
                     signatures: signatures, overrides: overrides)
    }
}
