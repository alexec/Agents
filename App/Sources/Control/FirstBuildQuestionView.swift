import AgentsKitCore
import SwiftUI

/// The question page (#5050, `specs/5048-first-build/spec.md`, sections 1, 2 and 8): a
/// newcomer's first open, the whole window. The Huddle, **Let's build your idea.** and one
/// prompt box whose placeholder goes round the ideas. Nothing else, and no way past it.
///
/// The first open's set-up (#4226) runs behind it, so the person can type at once. Its line
/// shows under the box only when it is slow (5 s) or fails, and at once after a Submit that
/// waits for it. Submit goes on when the window is paired.
struct FirstBuildQuestionView: View {
    let firstOpen: FirstOpen

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var text = ""
    @State private var tick = 0
    @State private var pointer: CGPoint?
    @State private var slow = false
    @State private var submitted: String?
    @State private var showingDetails = false
    @FocusState private var focused: Bool

    private var idea: FirstBuild.Idea { FirstBuild.idea(at: tick) }
    private var canSubmit: Bool { FirstBuild.submission(text) != nil && submitted == nil }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            Huddle(promptFocused: focused, pointer: pointer, typed: text.count)
                .padding(.bottom, 20)
            Text(FirstBuild.hero)
                .appText(.title).fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 24)
            box
            setUpLine
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .padding(.top, 12)
            Spacer(minLength: 40)
        }
        // A floor on the width, as on the first open: narrower, the words fixed to their
        // height push the window thousands of points tall.
        .frame(minWidth: 520, maxWidth: 640)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperGround()
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case let .active(location) = phase { pointer = location } else { pointer = nil }
        }
        .onAppear { focused = true }
        // The set-up, behind the page, only while the window has no control plane: a
        // newcomer who quit before Submit is paired already.
        .task {
            guard model.needsFirstRun else { return }
            // A walk's window pairs itself from AGENTS_CONTROL; nothing else sets it.
            await model.pairForWalk()
            guard model.needsFirstRun else { return }
            await firstOpen.run(pair: pair)
        }
        .task(id: firstOpen.needsApproval) {
            if model.needsFirstRun, firstOpen.needsApproval { await firstOpen.waitForApproval(pair: pair) }
        }
        // Its line only after 5 s of work.
        .task {
            try? await Task.sleep(for: .seconds(5))
            slow = true
        }
        // The placeholder goes round the ideas while the box is empty, and stops on the one
        // it shows when the person types.
        .task(id: text.isEmpty) {
            guard text.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(FirstBuild.ideaSeconds))
                guard !Task.isCancelled else { return }
                if reduceMotion { tick += 1 } else { withAnimation(.easeInOut(duration: 0.6)) { tick += 1 } }
            }
        }
        // A Submit that waited goes on once the window is paired.
        .onChange(of: model.needsFirstRun) { _, needs in
            if !needs, let submitted { model.submitFirstBuild(submitted) }
        }
    }

    private var box: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .appText(.reading)
                .lineLimit(4...10)
                .focused($focused)
                .accessibilityLabel("Your idea")
                .accessibilityHint("For example: \(idea.words)")
                .overlay(alignment: .topLeading) { placeholder }
                // Return submits. Shift-Return and Option-Return break the line, as in the
                // prompt bar (#377, #1514).
                .onKeyPress(.return, phases: .down) { press in
                    guard PromptReturn(option: press.modifiers.contains(.option),
                                       shift: press.modifiers.contains(.shift)) == .send else {
                        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                        editor.insertNewlineIgnoringFieldEditor(nil)
                        return .handled
                    }
                    submit()
                    return .handled
                }
                // Tab puts the idea that shows into the box, to change it.
                .onKeyPress(.tab) {
                    guard text.isEmpty else { return .ignored }
                    text = idea.words
                    return .handled
                }
                .disabled(submitted != nil)
            Button("Submit", action: submit)
                .buttonStyle(.paperProminent)
                .disabled(!canSubmit)
        }
        .padding(14)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
    }

    /// The idea that shows, faded into the next one; with Reduce Motion it just changes.
    @ViewBuilder
    private var placeholder: some View {
        if text.isEmpty {
            Text(idea.words)
                .appText(.reading)
                .foregroundStyle(.tertiary)
                .id(tick)
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The set-up's line: after a Submit that waits, after 5 s of work, or a failure. Nothing
    /// once the window is paired.
    @ViewBuilder
    private var setUpLine: some View {
        if model.needsFirstRun {
            switch firstOpen.step {
            case .working(let words):
                if submitted != nil || slow {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(submitted != nil ? "Setting up Agents on this Mac…" : words)
                            .appText(.supporting).foregroundStyle(.secondary)
                    }
                }
            case .failed(let line, let details):
                failed(line: line, details: details)
            case .elsewhere:
                // ContentView shows the first open's Connect page in this page's place.
                EmptyView()
            }
        }
    }

    private func failed(line: String, details: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(line, icon: "exclamationmark.triangle")
                    .appText(.supporting)
                    .tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if firstOpen.needsApproval {
                    Button("Open Login Items") { firstOpen.openLoginItems() }
                }
                Button(showingDetails ? "Hide Details" : "Show Details") { showingDetails.toggle() }
                Button("Try Again") { Task { await firstOpen.run(pair: pair) } }
            }
            if showingDetails {
                Text(details)
                    .appText(.supporting).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Logs") { firstOpen.showLogs() }.buttonStyle(.link)
            }
        }
    }

    private func submit() {
        guard canSubmit, let words = FirstBuild.submission(text) else { return }
        if model.needsFirstRun {
            // Submit waits for the set-up, with the words kept.
            submitted = words
        } else {
            model.submitFirstBuild(words)
        }
    }

    /// The window's pairing with this Mac's own control plane, as on the first open; then
    /// the page stays until Submit.
    private func pair(_ code: ControlCode) async throws {
        let membership = try await ControlConfig.pair(with: code)
        model.keepAskingFirstBuild()
        await model.adopt(.remote(membership))
    }
}
