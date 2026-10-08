import AgentsKitCore
import SwiftUI

/// Open File… (#415): a field over the window that finds a file in the session's
/// folders by name and path, as it is typed, and opens the one chosen.
///
/// The search is the `@` search (`files/mention`), asked of the host the session is on,
/// so a server's project is searched where it is. Up and Down move through what was
/// found, Return opens it, Escape — or a click outside — closes the field and changes
/// nothing.
struct FileSearch: View {
    /// What the field says it is searching: the session's folder.
    let place: String
    let search: @MainActor (String) async -> [FileMention]
    let choose: (FileMention) -> Void
    let dismiss: () -> Void

    @State private var term = ""
    @State private var found: [FileMention] = []
    @State private var selected = 0
    /// Whether anything has come back for the term being shown, so "No files" is not
    /// said while the first search is still out.
    @State private var searched = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // A click anywhere else closes it, as a menu would.
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Open a file in \(place)", text: $term)
                    .textFieldStyle(.plain)
                    .appText(.reading)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit(openSelected)
                    .onKeyPress(.downArrow) {
                        guard !found.isEmpty else { return .ignored }
                        selected = min(selected + 1, found.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !found.isEmpty else { return .ignored }
                        selected = max(selected - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 12))
                if !found.isEmpty {
                    MentionList(mentions: found, selected: selected, choose: choose)
                } else if searched, !term.isEmpty {
                    Text("No files match “\(term)”.")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 16)
            .padding(.top, 48)
        }
        #if os(macOS)
        .onExitCommand(perform: dismiss)
        #endif
        .onAppear { focused = true }
        // What was typed since is the search that matters: a newer term cancels this one.
        .task(id: term) {
            let asked = term.trimmingCharacters(in: .whitespaces)
            guard !asked.isEmpty else {
                found = []
                searched = false
                return
            }
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let answer = await search(asked)
            guard !Task.isCancelled else { return }
            found = answer
            selected = 0
            searched = true
        }
    }

    private func openSelected() {
        guard found.indices.contains(selected) else { return }
        choose(found[selected])
    }
}
