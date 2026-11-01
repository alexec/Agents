import AgentsKitCore
import SwiftUI

/// Where this comes from (#2957, FR-020, frame B): every layer of one rule from the top down,
/// with its value or "Not set", the layer that decides lit, a capped value marked "Kept, not
/// used", and a folder's layer named by its file, committed with the folder's code. The web
/// page's is `Web/src/views/settings/PolicySource.tsx`.
struct PolicySourcePopover: View {
    let row: PolicyLayersWords.Row
    let rule: DaemonAPI.EffectiveRule

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.title).appText(.reading).fontWeight(.semibold)
            ForEach(Array(rule.layers.enumerated()), id: \.offset) { _, layer in
                let decides = rule.decides == layer.layer
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: OrgPolicyWords.layerSymbol(layer.layer.kind))
                        .frame(width: 18)
                        .foregroundStyle(decides ? AnyShapeStyle(Paper.accent) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PolicyLayersWords.layerLine(layer.layer)).fontWeight(decides ? .semibold : .regular)
                        if layer.layer.kind == "folder" {
                            Text(PolicyLayersWords.folderFile).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(layer.words)
                            .foregroundStyle(layer.value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        if decides {
                            Text(PolicyLayersWords.decides).appText(.fine).foregroundStyle(Paper.accent)
                        } else if layer.kept {
                            Text(PolicyLayersWords.keptNotUsed).appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(decides ? Paper.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Paper.Radius.control))
                .accessibilityElement(children: .combine)
            }
            if rule.decides == nil {
                Text("No layer sets this: \(row.unset).").appText(.fine).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(Paper.ground)
    }
}
