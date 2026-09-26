import AgentsKitCore
import SwiftUI

/// What the agent has said and done, and the way the pane moves through it (033).
///
/// The Mac's transcript, made the phone's as well. The phone had its own: it moved only
/// when a whole new entry landed, with a fresh animation each time, so a streaming
/// reply ran on below the screen until somebody tapped the way back. This one follows
/// by the fragment, and it is the only one.
///
/// Everything it needs from the app it is told. It reads no model, so both apps can
/// hand it theirs.
struct ChatTranscript: View {
    let agent: Agent
    let items: [TranscriptItem]
    /// Whether there is more of the conversation before the first page in hand.
    let hasMore: Bool
    /// How many entries are in hand. Growth is what "something new" means.
    let entryCount: Int
    /// Whether the daemon is picking this conversation back up after a restart.
    let isComingBack: Bool
    /// Which conversation this is. A change settles the pane at the end again.
    let settleKey: UUID?
    let loadEarlier: () async -> Void
    /// How much of the foot of the pane the floating prompt covers.
    var bottomInset: CGFloat = 0
    /// Somebody asked for the end: the prompt was sent, or the menu command was used.
    /// A counter rather than a flag, so two asks in a row both land.
    var scrollToEndToken = 0
    /// A message to go to, asked for from elsewhere (the Mac's artifacts pane).
    var focusedEntry: UUID? = nil
    var clearFocus: () -> Void = {}
    /// How tall the visible part is. The phone sizes its first page to it.
    var onHeight: ((CGFloat) -> Void)? = nil

    @State private var expandedRuns: Set<UUID> = []
    /// Set once the pane is sitting at the foot of the conversation. Until then the
    /// top of the list is on screen only because nothing has moved yet, and taking
    /// that for "the reader scrolled up" would pull the whole transcript in at once.
    @State private var hasSettled = false
    @State private var isLoadingEarlier = false
    /// Whether the pane is following the end of the conversation.
    ///
    /// Not the same thing as being at the end. Being at the end is geometry, and
    /// geometry moves every time a line arrives; this is a mode, and only the reader
    /// changes it. Someone reading back through an hour of a conversation is left where
    /// they are until they ask to come back.
    @State private var isFollowing = true
    /// Whether the last thing to move the pane was a hand rather than the conversation.
    @State private var isUserScrolling = false
    /// Whether anything has arrived since they scrolled away from the end.
    ///
    /// The pane must not move while they are reading (FR-010), so the arrival is said
    /// rather than shown. Cleared the moment they are back at the end, by either route.
    @State private var hasNewBelow = false
    /// Whether there is more conversation than pane. No point offering a way to the
    /// end of something already wholly on screen.
    @State private var canScroll = false

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if hasMore {
                        // No button. Reaching the top is the ask.
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    // Folded once by the model as each entry lands, not here on every
                    // redraw: a reply arrives several chunks a second.
                    ForEach(items) { item in
                        TranscriptRow(item: item,
                                      isExpanded: expandedRuns.contains(item.id),
                                      toggle: { toggle(item.id) })
                            .id(item.id)
                    }
                    ForEach(agent.queuedPrompts) { queued in
                        QueuedPromptRow(prompt: queued, agentID: agent.id)
                    }
                    // Live, and so at the foot rather than in the record: the chat
                    // itself says what the row in the list says, and it stops saying
                    // it the moment the prompt lands.
                    if isComingBack {
                        ComingBackLine()
                    } else if agent.state == .running || agent.state == .starting {
                        WorkingLine()
                    }
                    Color.clear.frame(height: 1).id(bottom)
                }
                // The chat column, shared with the prompt bar below it and with the
                // cards that float above that: one pair of edges down the pane, set in
                // one place (FR-021).
                .chatColumn()
                .padding(.vertical, 20)
            }
            // Open at the foot. A lazy stack built from the top and then jumped to the
            // end placed the rows it made on the way (the accessibility tree had them,
            // on screen) but never drew them: a transcript taller than the pane opened
            // blank until something scrolled it. Starting at the end is what `settle`
            // was reaching for, and a plain VStack drew it — the laziness is the part
            // that did not survive the jump. Only where it opens: a transcript shorter
            // than the pane still sits at the top of it.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // The text stops above the floating prompt, and so does the scrollbar.
            // Insetting the content alone left the bar running the whole height of the
            // pane and disappearing under the glass, where it could be neither read nor
            // caught. Two lines rather than one bare `contentMargins`, because the bare
            // one moves the visible area up as well, and the transcript is meant to run
            // on under the glass rather than stop short of it.
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .onScrollGeometryChange(for: Edges.self) { geometry in
                Edges(fromTop: geometry.contentOffset.y,
                      fromBottom: geometry.contentSize.height
                          - geometry.contentOffset.y
                          - geometry.containerSize.height,
                      canScroll: geometry.contentSize.height > geometry.containerSize.height,
                      height: geometry.containerSize.height)
            } action: { _, edges in
                canScroll = edges.canScroll
                onHeight?(edges.height)
                // Geometry moves for two reasons: the reader scrolled, or the
                // conversation grew. Only the first may end follow mode. Reading the
                // distance on its own got this wrong — a new line puts the end below the
                // pane for a frame before the pane catches up, and that frame looks
                // exactly like somebody scrolling away — so the pane decided the reader
                // had left when they had not, stopped following, and put the way back up
                // unasked.
                if isUserScrolling, !isLoadingEarlier, edges.fromBottom > leftTheEnd {
                    isFollowing = false
                }
                // Back at the foot under their own steam. Generous on the way in and
                // strict on the way out: following again a moment early is a small
                // wrong, and being left behind a live conversation is the bug.
                if edges.fromBottom < atTheEnd {
                    isFollowing = true
                    hasNewBelow = false
                }
                // Following the end, taken from the geometry rather than from new
                // entries arriving. It used to be an animated scrollTo per entry, and
                // that is the chunkiness: a reply arrives in fragments, several a
                // second, and each one started a fresh 0.15s ease that restarted the one
                // still running, so the pane stuttered rather than moved. The geometry
                // sees every kind of growth — a new line, a line getting longer, a tool
                // run unfolding — and there is nothing to animate: at a fragment at a
                // time the pane moves by the word as the word arrives.
                //
                // Both declarative answers were tried here first, against a live agent,
                // and neither held the foot once the content grew past it:
                // `.defaultScrollAnchor(.bottom, for: .sizeChanges)`, and a
                // `ScrollPosition` left standing at its bottom edge. With either of them
                // the offset stayed where it was while the conversation ran on below the
                // pane.
                //
                // Not guarded on `isLoadingEarlier`: earlier pages land on top, and
                // whoever is following wants the foot whatever arrives above them.
                // Guarding it cost three seconds of falling behind at the start of a
                // turn, and then the catching-up jump this is all meant to stop.
                if isFollowing, !isUserScrolling, edges.fromBottom > 0.5 {
                    scroller.scrollTo(bottom, anchor: .bottom)
                }
                // A page is 200 entries, and a run of tool calls is one line however
                // many entries it took, so a page can come back shorter than the
                // pane. Nothing to scroll means nothing would ever ask for the rest,
                // so a page that does not fill the pane asks for another itself.
                if edges.fromTop < 400 || !edges.canScroll { loadEarlier(keeping: scroller) }
            }
            // What counts as the reader moving the pane. `.animating` is this view's own
            // scrollTo and `.idle` is the conversation growing under a still hand;
            // neither is a reason to stop following.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting, .decelerating: isUserScrolling = true
                default: isUserScrolling = false
                }
            }
            .onChange(of: entryCount) { before, after in
                // Nothing here moves the pane; the geometry does that. This is only the
                // word to the reader who is not watching. Loading earlier adds to the
                // top, and that must not read as something new having arrived.
                guard after > before, !isLoadingEarlier, !isFollowing else { return }
                hasNewBelow = true
            }
            .task(id: settleKey) { await settle(scroller) }
            // Asked for from elsewhere. A message entry is drawn with its own id, so
            // this lands on it.
            .onChange(of: focusedEntry) {
                guard let focusedEntry else { return }
                // Being sent to a line in the middle is being sent away from the end,
                // and it was asked for. Following on from here would take the reader
                // straight back off the line they were sent to.
                isFollowing = false
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(focusedEntry, anchor: .center) }
                clearFocus()
            }
            .onChange(of: scrollToEndToken) { goToEnd(scroller) }
            // The floor rose: a question or a permission card appeared above the
            // prompt bar, and the transcript's bottom margin grew with it. The
            // geometry does not count that as the end moving — content size and
            // offset are what they were — so whoever was following was left with the
            // last thing said, usually the question itself, under the glass. Only for
            // the follower: a reader elsewhere is not moved (FR-010), and the card
            // floats in view for them regardless. A turn of the run loop later, so
            // the new margin is in force before the pane is asked to reach the end.
            .onChange(of: bottomInset) { before, after in
                guard after > before, isFollowing else { return }
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
                }
            }
            .overlay(alignment: .bottom) {
                if canScroll, !isFollowing {
                    JumpToEnd(hasNewBelow: hasNewBelow) { goToEnd(scroller) }
                        // Clear of the floating prompt, whose height the chat has
                        // already measured for the transcript's own bottom inset.
                        .padding(.bottom, bottomInset + 12)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: canScroll && !isFollowing)
        }
    }

    private func toggle(_ id: UUID) {
        if expandedRuns.contains(id) { expandedRuns.remove(id) } else { expandedRuns.insert(id) }
    }

    private func goToEnd(_ scroller: ScrollViewProxy) {
        hasNewBelow = false
        isFollowing = true
        withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
    }

    /// How far from the foot counts as having left it, and how close counts as being
    /// back at it. Two numbers rather than one: with a single line between the two
    /// states, a conversation arriving a line at a time could flip the mode back and
    /// forth under the reader.
    private var leftTheEnd: CGFloat { 160 }
    private var atTheEnd: CGFloat { 40 }

    /// How far the pane is from either end of the conversation, and how tall it is.
    private struct Edges: Equatable {
        var fromTop: CGFloat
        var fromBottom: CGFloat
        var canScroll: Bool
        var height: CGFloat
    }

    /// Open at the end, the way every chat does, and only then let reaching the top
    /// mean something.
    private func settle(_ scroller: ScrollViewProxy) async {
        expandedRuns = []
        hasSettled = false
        isFollowing = true
        isUserScrolling = false
        hasNewBelow = false
        // The first page arrives a moment after the selection does. Waiting for it
        // rather than guessing at a delay is what keeps a big transcript from
        // opening halfway up itself.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while entryCount == 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled else { return }
        scroller.scrollTo(bottom, anchor: .bottom)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        hasSettled = true
    }

    /// Another page, and the reader left looking at the same line they were.
    ///
    /// The anchor is the line that was at the top before the page went in. Scrolling
    /// back to it afterwards is the difference between reading backwards through a
    /// conversation and being thrown about by it.
    private func loadEarlier(keeping scroller: ScrollViewProxy) {
        guard hasSettled, !isLoadingEarlier, hasMore else { return }
        isLoadingEarlier = true
        let anchor = items.first?.id
        Task {
            await loadEarlier()
            if let anchor { scroller.scrollTo(anchor, anchor: .top) }
            // A beat before the next one can start, so one flick does not swallow
            // the whole file.
            try? await Task.sleep(for: .milliseconds(250))
            isLoadingEarlier = false
        }
    }

    private var bottom: String { "bottom" }
}
