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
    @Environment(\.chatActions) private var actions
    let agent: Agent
    /// The turn in progress and any since, folded.
    let items: [TranscriptItem]
    /// The finished turns before `items`, as stored: drawn from their outcome until opened.
    var stored: [TurnSummary] = []
    /// The level a turn starts at, the app's one setting (069).
    var defaultDetail: TurnDetail = .outcome
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
    /// Told whether the pane is following the end. The model lets the oldest entries
    /// go only while it is, so nothing leaves from above somebody reading back.
    var onFollowing: (Bool) -> Void = { _ in }

    /// The turns opened or closed by hand, by id. Kept until the chat is left (069).
    @State private var turnViews: [UUID: TurnDetail] = [:]
    /// Every entry of a stored turn once it has been opened, folded.
    @State private var fetchedTurns: [UUID: [TranscriptItem]] = [:]
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
    /// The tallest honest content height seen for this conversation.
    ///
    /// A lazy stack reports about one screen of height while it is throwing rows
    /// away. That sample looks like a short page whose end is on screen, and
    /// acting on it — resume following, go to the foot, ask for the page above
    /// and go to its top — is the pane jumping up and down under a reader.
    @State private var trustedContentHeight: CGFloat = 0
    /// Where an automatic move to the foot last aimed, so a distance that does
    /// not shrink can be chased once rather than on every geometry tick.
    @State private var lastPinnedHeight: CGFloat?
    @State private var lastPinnedDistance: CGFloat?
    /// The rows at the top when an earlier page was asked for, and whether the
    /// reader was following the end. The first row's id often does not survive
    /// the page: what arrives joins onto it, and the row takes the earlier
    /// entry's id. The next id that is still there is the line they were reading.
    @State private var restoreIDs: [UUID] = []
    @State private var restoreFollowing = false

    /// Send now is for a turn that is running, on a runtime that said it takes words
    /// mid-turn. Starting is not running: there is no turn yet to send them into.
    private var canSendNow: Bool {
        (agent.state == .running || agent.state == .waitingOnUser) && actions.canSendNow(agent.runtimeID)
    }

    /// The conversation as turns: the stored ones, then those in hand.
    private var rows: [ChatTurn] { stored.map(ChatTurn.init) + items.turns() }

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
                    // Each turn at the app's level, or the one chosen for it. A new turn
                    // leaves the ones before it as they were: one being read stays open.
                    ForEach(rows) { turn in
                        TurnView(turn: turn,
                                 detail: turnViews[turn.id] ?? defaultDetail,
                                 fetched: fetchedTurns[turn.id],
                                 isLive: turn.id == rows.last?.id && isWorking,
                                 toggle: { toggle(turn) },
                                 fetch: { await fetch(turn) })
                            .id(turn.id)
                    }
                    .environment(\.backgroundWork, agent.background)
                    ForEach(agent.queuedPrompts) { queued in
                        QueuedPromptRow(prompt: queued, agentID: agent.id,
                                        canSendNow: canSendNow)
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
                // `visibleRect` is the content actually on screen, insets included.
                // Measuring from `contentOffset` alone counts the top bar as distance
                // still below the fold, and the pane then chases that distance: a few
                // points down, a few points up, for as long as the chat is open.
                Edges(fromTop: max(0, geometry.visibleRect.minY),
                      fromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                      canScroll: geometry.contentSize.height > geometry.containerSize.height + 1,
                      height: geometry.containerSize.height,
                      contentHeight: geometry.contentSize.height)
            } action: { _, edges in
                onHeight?(edges.height)
                // A lazy stack's content size can collapse to the rows it has made
                // for the length of a flick. Even when that sample still exceeds the
                // viewport, treating it as a real shorter page can resume following
                // or ask for an earlier page. Keep the tallest reliable measurement
                // and ignore a sample that falls materially below it.
                let collapsed = trustedContentHeight > edges.height + 80
                    && edges.contentHeight < trustedContentHeight - 80
                if collapsed {
                    // Their hand is on it and the measurement cannot be believed.
                    // Stop following now; the honest sample arrives as they let go,
                    // and waiting for it is how a flick ends at the foot.
                    if isUserScrolling { isFollowing = false }
                    return
                }
                trustedContentHeight = max(trustedContentHeight, edges.contentHeight)
                canScroll = edges.canScroll
                guard !isLoadingEarlier else { return }
                // Geometry moves for two reasons: the reader scrolled, or the
                // conversation grew. Only the first may end follow mode. Reading the
                // distance on its own got this wrong — a new line puts the end below the
                // pane for a frame before the pane catches up, and that frame looks
                // exactly like somebody scrolling away — so the pane decided the reader
                // had left when they had not, stopped following, and put the way back up
                // unasked.
                if isUserScrolling, edges.fromBottom > leftTheEnd {
                    isFollowing = false
                }
                // A move up the page that is not the page growing. The scroll
                // phase is not always delivered for it — a wheel tick can land
                // while the phase is idle — and without this the foot is pinned
                // again the moment the hand lets go, which is the jump.
                if let pinned = lastPinnedHeight, let was = lastPinnedDistance,
                   abs(edges.contentHeight - pinned) < 0.5,
                   edges.fromBottom > was + leftTheEnd {
                    isFollowing = false
                }
                // Back at the foot under their own steam. Generous on the way in and
                // strict on the way out: following again a moment early is a small
                // wrong, and being left behind a live conversation is the bug.
                // Not while their hand is still on it: one frame of a flick reads as
                // the end, and resuming follow then pulls them there as they let go.
                if !isUserScrolling, edges.fromBottom < atTheEnd {
                    isFollowing = true
                    hasNewBelow = false
                    lastPinnedDistance = 0
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
                // Once per content height, and again only when the distance actually
                // shrinks. A distance that stays put — the top bar, counted as though
                // it were content below the fold — used to be chased on every tick,
                // and the pane bounced.
                if isFollowing, !isUserScrolling, edges.fromBottom > 1 {
                    let grown = edges.contentHeight != lastPinnedHeight
                    let closer = lastPinnedDistance.map { edges.fromBottom < $0 - 0.5 } ?? true
                    if grown || closer {
                        lastPinnedHeight = edges.contentHeight
                        lastPinnedDistance = edges.fromBottom
                        place(scroller, on: bottom, anchor: .bottom)
                    }
                }
                // A page is 200 entries, and a run of tool calls is one line however
                // many entries it took, so a page can come back shorter than the
                // pane. Nothing to scroll means nothing would ever ask for the rest,
                // so a page that does not fill the pane asks for another itself.
                if edges.contentHeight > 1, edges.fromTop < 400 || !edges.canScroll {
                    askForEarlier()
                }
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
                // An earlier page has landed. Hold the line they were on — or the
                // foot, if they were following it. Doing it here rather than in the
                // load is what makes the rows exist to hold: the load's own view
                // value still has the page from before.
                if isLoadingEarlier, after != before { holdPlace(scroller) }
                // Nothing here moves the pane otherwise; the geometry does that. This
                // is only the word to the reader who is not watching. Loading earlier
                // adds to the top, and that must not read as something new having arrived.
                guard after > before, !isLoadingEarlier, !isFollowing else { return }
                hasNewBelow = true
            }
            .task(id: settleKey) { await settle(scroller) }
            // Asked for from elsewhere. A message entry is drawn with its own id, so
            // this lands on it.
            .onChange(of: focusedEntry) {
                guard let focusedEntry else { return }
                if let turn = rows.first(where: { $0.items.contains { $0.id == focusedEntry } }),
                   !(turnViews[turn.id] ?? defaultDetail).showsSteps {
                    turnViews[turn.id] = .steps
                }
                // Being sent to a line in the middle is being sent away from the end,
                // and it was asked for. Following on from here would take the reader
                // straight back off the line they were sent to.
                isFollowing = false
                withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(focusedEntry, anchor: .center) }
                clearFocus()
            }
            .onChange(of: scrollToEndToken) { goToEnd(scroller) }
            .onChange(of: isFollowing) { _, now in onFollowing(now) }
            // Nobody is reading a chat that is not on screen, so it may be trimmed again.
            .onDisappear { onFollowing(true) }
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
                // The fade belongs to the button alone. The same animation on the
                // scroll view eased every correction, so a reader and the pane pulled
                // against each other for the length of the ease.
                ZStack(alignment: .bottom) {
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
    }

    /// Open a turn's steps, or close them. Open is the app's level when that shows
    /// steps, and Steps when it does not; closed is always the outcome, never a trip
    /// through Details.
    private func toggle(_ turn: ChatTurn) {
        let now = turnViews[turn.id] ?? defaultDetail
        turnViews[turn.id] = now.showsSteps ? .outcome : (defaultDetail.showsSteps ? defaultDetail : .steps)
    }

    /// A stored turn's entries, the first time it is drawn with its steps. The ask is
    /// the turn's own and is drawn already.
    private func fetch(_ turn: ChatTurn) async {
        guard turn.isSummaryOnly, let range = turn.range, fetchedTurns[turn.id] == nil else { return }
        let items = TranscriptEntry.display(await actions.turnEntries(agent.id, range))
        fetchedTurns[turn.id] = items.first?.isPersonsAsk == true ? Array(items.dropFirst()) : items
    }

    /// Whether the conversation's last turn is still going.
    private var isWorking: Bool {
        switch agent.state {
        case .running, .starting, .waitingOnUser: return true
        default: return false
        }
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
        var contentHeight: CGFloat
    }

    /// Move without animating. An animated move restarts on the next fragment, which
    /// is the stutter this pane used to have, and it is also how a correction and a
    /// hand on the pane end up pulling the page in opposite directions.
    private func place(_ scroller: ScrollViewProxy, on id: some Hashable, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scroller.scrollTo(id, anchor: anchor) }
    }

    /// Open at the end, the way every chat does, and only then let reaching the top
    /// mean something.
    private func settle(_ scroller: ScrollViewProxy) async {
        turnViews = [:]
        fetchedTurns = [:]
        hasSettled = false
        isFollowing = true
        isUserScrolling = false
        hasNewBelow = false
        trustedContentHeight = 0
        lastPinnedHeight = nil
        lastPinnedDistance = nil
        restoreIDs = []
        restoreFollowing = false
        // The first page arrives a moment after the selection does. Waiting for it
        // rather than guessing at a delay is what keeps a big transcript from
        // opening halfway up itself.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while entryCount == 0, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled else { return }
        place(scroller, on: bottom, anchor: .bottom)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        hasSettled = true
    }

    /// Another page, and the reader left looking at the same line they were.
    ///
    /// Someone following the end stays at the foot: the page arrives above them,
    /// and scrolling the old first line to the top is what used to throw them up
    /// there and then back down. Someone reading stays on the row they had. The
    /// move itself happens when the rows land (`entryCount`), because a scroll
    /// asked for before they exist does not land on them.
    private func askForEarlier() {
        guard hasSettled, !isLoadingEarlier, hasMore else { return }
        isLoadingEarlier = true
        restoreFollowing = isFollowing
        restoreIDs = rows.prefix(8).map(\.id)
        Task {
            await loadEarlier()
            // A beat before the next one can start, so one flick does not swallow
            // the whole file.
            try? await Task.sleep(for: .milliseconds(250))
            isLoadingEarlier = false
        }
    }

    /// Keep the reader where they were once an earlier page has been drawn.
    private func holdPlace(_ scroller: ScrollViewProxy) {
        if restoreFollowing {
            place(scroller, on: bottom, anchor: .bottom)
            return
        }
        // The first row may have been joined into the page that just arrived, so
        // its id is gone. The next row that is still there is the same line.
        if let id = restoreIDs.first(where: { id in rows.contains { $0.id == id } }) {
            place(scroller, on: id, anchor: .top)
        }
    }

    private var bottom: String { "bottom" }
}
