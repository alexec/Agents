import AgentsKitCore
import SwiftUI

/// A blocked chat's wait lines (039, #341): any of or all of, one line an agent it waits
/// on, and when it checks again, under the chat's head where Carry on is. The row says
/// them too; the chat says them so a blocked chat opened from anywhere says what it is
/// waiting for, as the page's block strip does. The lines are `AgentsModel.blockLines`.
struct WaitLines: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}
