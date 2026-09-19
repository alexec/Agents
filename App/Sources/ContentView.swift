import AgentsKit
import SwiftUI

/// The skeleton's only screen. The first feature replaces it.
struct ContentView: View {
    var body: some View {
        Text(Agents.greeting)
            .font(.title2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
}
