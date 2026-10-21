import SwiftUI

/// A row that opens one page of Settings, as a pane of the window's rail.
struct SettingsPageLink<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        NavigationLink {
            Form { content() }
                .scrollContentBackground(.hidden)
                .background(Paper.ground)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            Label(title, systemImage: systemImage)
        }
    }
}
