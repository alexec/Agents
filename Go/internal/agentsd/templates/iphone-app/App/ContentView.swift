import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("__APP_NAME__")
                .font(.title)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
