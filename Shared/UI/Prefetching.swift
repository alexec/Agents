import AgentsKitCore
import SwiftUI

/// A wait on the network, said only once it is long enough to notice (#4795; spec
/// 4777-fast, "a spinner only after 300 ms"): nothing for `after`, then the spinner. A
/// wait shorter than that, as most are, shows no flash of one.
struct DelayedProgress: View {
    /// How long nothing is shown.
    static let after: Duration = .milliseconds(300)

    var controlSize: ControlSize = .regular
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                ProgressView().controlSize(controlSize)
            }
        }
        .task {
            try? await Task.sleep(for: Self.after)
            shown = true
        }
    }
}

extension View {
    /// Runs `prefetch` once the pointer has stayed on this view for
    /// `OpeningPrefetch.hoverDelay` (#4795): a pointer that only crosses it fetches nothing.
    func prefetchesOnHover(_ prefetch: @escaping @MainActor () -> Void) -> some View {
        modifier(PrefetchOnHover(prefetch: prefetch))
    }
}

private struct PrefetchOnHover: ViewModifier {
    let prefetch: @MainActor () -> Void
    @State private var waiting: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                waiting = nil
                guard inside else { return }
                waiting = Task { @MainActor in
                    try? await Task.sleep(for: OpeningPrefetch.hoverDelay)
                    guard !Task.isCancelled else { return }
                    prefetch()
                }
            }
            .onDisappear {
                waiting?.cancel()
                waiting = nil
            }
    }
}
