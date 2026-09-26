import AgentsKit
import SwiftUI

/// Update an added skill (059, US3): fetch its source at the current commit, show what that
/// changes in the copy there, and replace it only when the person says so.
struct UpdateSkillSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let name: String
    let destination: DaemonAPI.SkillDestination
    let runtimes: [DaemonAPI.RuntimeName]
    var onUpdated: () -> Void = {}

    @State private var answer: DaemonAPI.SkillUpdatePreviewAnswer?
    @State private var error: DaemonAPI.CatalogError?
    @State private var addTo: DaemonAPI.SkillDestination = .personal

    var body: some View {
        Group {
            if let answer {
                SkillPreviewView(preview: answer.preview, addTo: $addTo, projectName: nil, runtimes: runtimes,
                                 back: { dismiss() },
                                 added: { _ in
                                     onUpdated()
                                     dismiss()
                                 },
                                 update: answer)
            } else if let error {
                VStack(spacing: 0) {
                    CatalogProblemView(error: error, retry: { Task { await load() } })
                    HStack { Spacer(); Button("Close") { dismiss() }.buttonStyle(.paper) }.padding(18)
                }
            } else {
                ProgressView("Fetching \(name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: AddSkillSheet.size.width, height: AddSkillSheet.size.height)
        .background(Paper.ground)
        .task {
            addTo = destination
            await load()
        }
    }

    private func load() async {
        error = nil
        switch await model.skillUpdatePreview(name, at: destination) {
        case .success(let fresh): answer = fresh
        case .failure(let failure): error = failure
        }
    }
}
