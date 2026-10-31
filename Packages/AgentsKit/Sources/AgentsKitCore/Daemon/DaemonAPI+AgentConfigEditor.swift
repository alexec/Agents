import Foundation

public extension DaemonAPI.Method {
    static let agentConfigEditorFiles = "agentConfig/editorFiles"
    static let agentConfigEditorSave = "agentConfig/editorSave"
}

public extension DaemonAPI {
    enum AgentConfigEditorKind: String, Codable, Sendable, CaseIterable {
        case skills, personas, workflows

        public var title: String { rawValue.capitalized }
    }

    struct AgentConfigEditorFile: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var content: String
        public var id: String { path }

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }
    }

    struct AgentConfigEditorRequest: Codable, Sendable {
        public var folder: URL?
        public var kind: AgentConfigEditorKind

        public init(folder: URL? = nil, kind: AgentConfigEditorKind) {
            self.folder = folder
            self.kind = kind
        }
    }

    struct AgentConfigEditorSaveRequest: Codable, Sendable {
        public var folder: URL?
        public var kind: AgentConfigEditorKind
        public var path: String
        public var content: String
        public var delete: Bool?

        public init(folder: URL? = nil, kind: AgentConfigEditorKind, path: String, content: String, delete: Bool = false) {
            self.folder = folder
            self.kind = kind
            self.path = path
            self.content = content
            self.delete = delete ? true : nil
        }
    }
}
