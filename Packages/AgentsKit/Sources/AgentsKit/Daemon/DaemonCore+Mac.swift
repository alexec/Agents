import AgentsKitCore
import Foundation

/// The window's Finder, other apps and Terminal, done by this Mac's host for a sandboxed
/// window (058, R12), and text files by path for its settings pages. Operator only: the
/// device role's allowlist does not name them.
extension DaemonCore {
    func macOpen(_ arguments: [String]) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "This Mac could not open that: \(error.localizedDescription)")
        }
        #else
        throw JSONRPCError(code: DaemonAPI.Failure.notSupported, message: "Only a Mac host can open Finder or another app.")
        #endif
    }

    func macReveal(_ request: DaemonAPI.MacPathRequest) throws {
        guard FileManager.default.fileExists(atPath: request.path) else { throw Self.gone(URL(fileURLWithPath: request.path)) }
        try macOpen(["-R", request.path])
    }

    func macOpenPath(_ request: DaemonAPI.MacPathRequest) throws {
        guard FileManager.default.fileExists(atPath: request.path) else { throw Self.gone(URL(fileURLWithPath: request.path)) }
        if let app = request.app, !app.isEmpty {
            try macOpen(["-a", app, request.path])
        } else {
            try macOpen([request.path])
        }
    }

    func macTerminal(_ request: DaemonAPI.MacTerminalRequest) throws {
        if let path = request.path { try macOpen(["-a", "Terminal", path]) } else { try macOpen(["-a", "Terminal"]) }
    }

    func readText(_ request: DaemonAPI.FilesTextRequest) throws -> DaemonAPI.FilesText {
        let url = URL(fileURLWithPath: request.path)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
            return DaemonAPI.FilesText(text: nil)
        }
        guard size <= DaemonAPI.textFileLimit else {
            throw JSONRPCError(code: DaemonAPI.Failure.fileNotReadable, message: "That file is too large to show here.")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Self.notReadable(url) }
        return DaemonAPI.FilesText(text: text)
    }

    func saveText(_ request: DaemonAPI.FilesSaveTextRequest) throws {
        let url = URL(fileURLWithPath: request.path)
        guard request.text.utf8.count <= DaemonAPI.textFileLimit else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is too much text for one file here.")
        }
        if request.onlyIfAbsent == true, FileManager.default.fileExists(atPath: url.path) { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(request.text.utf8).write(to: url, options: .atomic)
    }
}
