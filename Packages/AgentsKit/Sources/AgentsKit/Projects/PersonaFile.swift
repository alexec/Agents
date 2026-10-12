import AgentsKitCore
import Foundation

/// Reading personas off disk (#760): `.agents/personas/*.md` in a project and in
/// `~/.agents`. The front matter is read by the workflow's rules, so a `model:` means
/// the same in both files.
public enum PersonaFile {
    /// The project's and the home's together, one per id with the project's winning, by
    /// name. Either folder may be missing.
    public static func list(project: URL?, home: URL?) -> [Persona] {
        var byID: [String: Persona] = [:]
        for persona in read(in: home, origin: .personal) { byID[persona.id] = persona }
        for persona in read(in: project, origin: .project) { byID[persona.id] = persona }
        return byID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The one a start names, with the prompt it brings: the project's, else the home's.
    /// Nil when there is none by that id, or it cannot be read.
    public static func find(_ id: String, project: URL?, home: URL?) -> (persona: Persona, prompt: String)? {
        // An id is a file name in one folder, never a path out of it.
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return nil }
        for (base, origin) in [(project, Persona.Origin.project), (home, .personal)] {
            guard let base else { continue }
            let url = Persona.folder(in: base).appending(path: "\(id).\(Persona.fileExtension)")
            guard let data = WorkflowFile.bytes(at: url), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let read = parse(text, id: id, origin: origin)
            guard read.persona.problem == nil else { return nil }
            return read
        }
        return nil
    }

    static func read(in base: URL?, origin: Persona.Origin) -> [Persona] {
        guard let base else { return [] }
        let folder = Persona.folder(in: base)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".\(Persona.fileExtension)") && !$0.hasPrefix(".") }.map { name in
            let id = String(name.dropLast(Persona.fileExtension.count + 1))
            guard let data = WorkflowFile.bytes(at: folder.appending(path: name)),
                  let text = String(data: data, encoding: .utf8) else {
                return Persona(id: id, origin: origin, problem: "This file could not be read")
            }
            return parse(text, id: id, origin: origin).persona
        }
    }

    /// The whole of the format, as a function of text. A file with no front matter is
    /// a persona that is all prompt.
    public static func parse(_ text: String, id: String, origin: Persona.Origin) -> (persona: Persona, prompt: String) {
        let body = FrontMatter.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (Persona(id: id, origin: origin), body)
        }
        guard let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return (Persona(id: id, origin: origin, problem: "The metadata block is never closed"), body)
        }
        do {
            let mapping = try YAMLNode.mapping(from: Array(lines[1..<closing]))
            let name = mapping["name"]?.scalar.flatMap { $0.isEmpty ? nil : $0 }
            let description = mapping["description"]?.scalar.flatMap { $0.isEmpty ? nil : $0 }
            let settings = try WorkflowFile.settings(from: mapping)
            return (Persona(id: id, name: name, description: description, origin: origin, settings: settings), body)
        } catch let error as YAMLNode.Failure {
            return (Persona(id: id, origin: origin, problem: error.message), body)
        } catch {
            return (Persona(id: id, origin: origin, problem: "The metadata could not be read"), body)
        }
    }
}
