import AgentsKit
import SwiftUI

/// Session labels as small chips, with the person's add and remove actions.
struct SessionLabelEditor: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(agent.labels, id: \.normalizedValue) { label in
                Menu {
                    Button("Remove \(label.value)") {
                        Task { await model.setLabels(on: agent.id, remove: [label.value]) }
                    }
                } label: {
                    Text(label.value)
                        .appText(.fine)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(label.owner == .person ? Color.accentColor.opacity(0.16) : Color.clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(label.value), \(label.owner.rawValue) label")
            }
            if agent.labels.count < SessionLabelPolicy.maximumCount {
                Menu {
                    ForEach(suggestions, id: \.self) { value in
                        Button(value) { Task { await model.setLabels(on: agent.id, add: [value]) } }
                    }
                    Button("New label…") { adding = true }
                } label: {
                    Image(systemName: "plus.circle")
                        .accessibilityLabel("Add label")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .alert("Add label", isPresented: $adding) {
            TextField("Label", text: $draft)
            Button("Add") {
                let value = draft
                draft = ""
                Task { await model.setLabels(on: agent.id, add: [value]) }
            }
            Button("Cancel", role: .cancel) { draft = "" }
        } message: {
            Text("Use 1–24 characters. A session can have up to five labels.")
        }
    }

    private var suggestions: [String] {
        let existing = Set(agent.labels.map(\.normalizedValue))
        return model.labelSuggestions(in: agent.projectFolder, on: agent.host)
            .filter { !existing.contains(SessionLabelPolicy.key($0)) }
    }
}
