import Foundation

/// The app's tools, written out for runtimes that do not reliably discover them.
///
/// Grok never puts an MCP server's tools in the model's own list. They sit behind
/// `search_tool`, and the model is told not to call one until that search has returned
/// its schema. The tools this app needs used — ending a turn, showing a file, the rest
/// of the briefing — then wait on a search that often never happens.
///
/// Grok appends `_meta.rules` to the system prompt (`15-agent-mode.md`). This is that
/// text: each tool the server will actually offer this session, under the catalog name
/// Grok calls (`agents__finish_turn`), with the arguments it takes. The two older names
/// for `finish_turn` are left out, so a fresh agent is pointed at the one tool.
enum AppToolPreface {
    /// What a Grok session is told, for an agent that may or may not start others.
    static func rules(managesAgents: Bool) -> String {
        let offered = AppService.tools(
            managesAgents: managesAgents,
            movesItself: RuntimeCatalog.canMoveFolders(runtimeID: RuntimeCatalog.grok.id))
        let cards = offered.compactMap { card($0) }.joined(separator: "\n\n")
        return """
            These tools are fully specified. Call one with use_tool, setting tool_name \
            to the name given and tool_input to its arguments. Do not call search_tool \
            for these names. Tools from any other server still need a search.

            \(cards)
            """
    }

    /// Cursor receives these schemas from the `agents` MCP server itself. Point it to
    /// that live catalog without copying the schemas into every conversation's prompt.
    static let firstPrompt = "Call `agents` tools directly."

    /// The name Grok lists for a tool on the app's server. Two underscores, as in
    /// `agents__finish_turn`.
    static func catalogName(_ tool: String) -> String {
        "\(AppTool.serverName)__\(tool)"
    }

    private static func card(_ tool: JSONValue) -> String? {
        guard let name = tool["name"]?.stringValue else { return nil }
        let title = tool["title"]?.stringValue ?? name
        let arguments = tool["inputSchema"].map { fields($0, indent: "  ") } ?? ""
        let body = arguments.isEmpty ? "  (no arguments)" : arguments
        return "\(catalogName(name)) — \(title)\n\(body)"
    }

    /// One line per argument, required ones first. Nested objects and arrays of
    /// objects go one level further, which is as deep as any of these schemas go.
    private static func fields(_ schema: JSONValue, indent: String, depth: Int = 0) -> String {
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let properties = schema["properties"]?.objectValue ?? [:]
        let keys = properties.keys.sorted { lhs, rhs in
            let leftRequired = required.contains(lhs)
            let rightRequired = required.contains(rhs)
            if leftRequired != rightRequired { return leftRequired }
            return lhs < rhs
        }
        return keys.map { key in
            let property = properties[key] ?? .null
            var line = "\(indent)\(key): \(phrase(property, required: required.contains(key)))"
            guard depth < 2 else { return line }
            let type = property["type"]?.stringValue
            if type == "object" {
                let nested = fields(property, indent: indent + "  ", depth: depth + 1)
                if !nested.isEmpty { line += "\n" + nested }
            } else if type == "array", let items = property["items"],
                      items["type"]?.stringValue == "object" {
                let nested = fields(items, indent: indent + "  ", depth: depth + 1)
                if !nested.isEmpty { line += "\n" + nested }
            }
            return line
        }.joined(separator: "\n")
    }

    private static func phrase(_ property: JSONValue, required: Bool) -> String {
        var parts = [property["type"]?.stringValue ?? "value"]
        if required { parts.append("required") }
        if let values = property["enum"]?.arrayValue?.compactMap(\.stringValue), !values.isEmpty {
            parts.append("one of \(values.joined(separator: ", "))")
        }
        if let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue {
            parts.append("\(minimum)...\(maximum)")
        } else if let minimum = property["minimum"]?.intValue {
            parts.append("at least \(minimum)")
        }
        var text = parts.joined(separator: ", ")
        if let description = clipped(property["description"]?.stringValue) {
            text += ". \(description)"
        }
        return text
    }

    /// Long enough to keep a short example, short enough that a catalogue pasted into
    /// a description does not land in every Grok prompt.
    private static let descriptionLimit = 700

    private static func clipped(_ description: String?) -> String? {
        guard var text = description?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        if text.count > descriptionLimit {
            let end = text.index(text.startIndex, offsetBy: descriptionLimit)
            text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }
}

typealias GrokToolPreface = AppToolPreface
