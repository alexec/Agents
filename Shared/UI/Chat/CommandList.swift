import AgentsKitCore
import SwiftUI

/// What the runtime takes after a slash, offered while it is being typed.
///
/// The list is the runtime's, not ours: Copilot advertises thirty-odd commands, the
/// Claude adapter advertises the skills that happen to be installed, and both change
/// while a session is running.
struct CommandList: View {
    let commands: [SlashCommand]
    let selected: Int
    let choose: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        row(command, isSelected: index == selected)
                            .id(index)
                            .onTapGesture { choose(command) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            .onChange(of: selected) { scroller.scrollTo(selected, anchor: .center) }
        }
        .paperRaised(in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ command: SlashCommand, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("/" + command.name)
                .appText(.code)
            if let hint = command.inputHint, !hint.isEmpty {
                Text(hint)
                    .appText(.code)
                    .foregroundStyle(.tertiary)
            }
            if let description = command.description, !description.isEmpty {
                Text(description)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? AnyShapeStyle(Paper.wash) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Files under the agent's folders, offered while `@` is being typed.
struct MentionList: View {
    let mentions: [FileMention]
    let selected: Int
    let choose: (FileMention) -> Void

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(mentions.enumerated()), id: \.element.id) { index, mention in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(mention.name).appText(.supporting)
                            Text(mention.relativePath)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(index == selected ? AnyShapeStyle(Paper.wash) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 7))
                        .id(index)
                        .onTapGesture { choose(mention) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 220)
            .onChange(of: selected) { scroller.scrollTo(selected, anchor: .center) }
        }
        .paperRaised(in: RoundedRectangle(cornerRadius: 14))
    }
}
