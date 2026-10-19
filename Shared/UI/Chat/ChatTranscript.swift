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
    /// Whether there is more of the conversation before the first page in hand.
    let hasMore: Bool
    /// How many entries are in hand. Growth is what "something new" means.
    let entryCount: Int
    /// Whether the daemon is picking this conversation back up after a restart.
    let isComingBack: Bool
    /// When the conversation last did anything (`AgentsModel.lastEntryAt`). Nil with no
    /// page in hand: the agent's own last activity is said instead (#1564).
    var lastEntryAt: Date? = nil
    /// Why the history did not load, or only partly, said at its top with Try Again (#400).
    var loadFailure: TranscriptLoadFailure? = nil
    /// Which conversation this is. A change settles the pane at the end again.
    let settleKey: UUID?
    let loadEarlier: () async -> Void
    /// How much of the foot of the pane the floating prompt covers.
    var bottomInset: CGFloat = 0
    /// What waits on the person (questions, forms, guarded changes), drawn in the
    /// conversation rather than over it (#723), where each was asked: what came after it
    /// is below it (#973). Each card keeps the chat column itself.
    var cards: [WaitingCard] = []
    /// Somebody asked for the end: the prompt was sent, or the menu command was used.
    /// A counter rather than a flag, so two asks in a row both land.
    var scrollToEndToken = 0
    /// A message to go to, asked for from elsewhere (the Mac's artifacts pane).
    var focusedEntry: UUID? = nil
    /// Where that message is in the transcript, when known (Find, #1532): a message in a
    /// stored turn's steps is drawn only once the turn is opened and its entries fetched.
    var focusedIndex: Int? = nil
    var clearFocus: () -> Void = {}
    /// How tall the visible part is. The phone sizes its first page to it.
    var onHeight: ((CGFloat) -> Void)? = nil
    /// Told whether the pane is following the end. The model lets the oldest entries
    /// go only while it is, so nothing leaves from above somebody reading back.
    var onFollowing: (Bool) -> Void = { _ in }

    /// The turns opened or closed by hand, by id. Kept until the chat is left (069).
    @State private var turnViews: [UUID: TurnDetail] = [:]
    /// The run of calls gone to from elsewhere: opened, with its first call (#1315).
    @State private var focusedRun: UUID?
    /// Every entry of a stored turn once it has been opened, folded. Eight at a time:
    /// opening one lets the oldest opened one go (#285).
    @State private var fetchedTurns: [UUID: FetchedTurn] = [:]
    @State private var fetchedOrder: [UUID] = []
    /// Stored turns whose entries did not come when opened: said, and asked for again
    /// on Try Again, never kept as a turn with no steps (#400).
    @State private var failedTurns: Set<UUID> = []
    private static let fetchedKept = 8
    /// Turns already folded. A chunk changes the tail; the turns before it stay the
    /// same values, so those rows are not drawn again (#285). A class, so folding
    /// during the pass does not write the view's state.
    @State private var folded = FoldedTurns()

    private final class FoldedTurns {
        var stored: [TurnSummary] = []
        var storedTurns: [ChatTurn] = []
        var items: [TranscriptItem] = []
        var itemTurns: [ChatTurn] = []
    }

    /// A stored turn's entries as far back as they have been fetched, folded once.
    private struct FetchedTurn {
        let entries: [TranscriptEntry]
        /// Where `entries` starts in the transcript: past the turn's start when it has
        /// earlier steps not yet asked for (#519).
        let firstIndex: Int
        /// The ask is the turn's own and is drawn already.
        let items: [TranscriptItem]

        init(entries: [TranscriptEntry], firstIndex: Int) {
            self.entries = entries
            self.firstIndex = firstIndex
            let items = TranscriptEntry.display(entries)
            self.items = items.first?.isPersonsAsk == true ? Array(items.dropFirst()) : items
        }

        func hasEarlier(than turn: ChatTurn) -> Bool {
            guard let range = turn.range else { return false }
            return firstIndex > range.lowerBound
        }
    }
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
    /// Whether there is more conversation than pane. No point offering a way to the
    /// end of something already wholly on screen.
    @State private var canScroll = false
    /// How tall the pane is, which the foot's margin is held to (#371).
    @State private var paneHeight: CGFloat?
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
    /// How the pane last moved, and the turn at its top: read on every scroll, so kept
    /// where writing them does not draw the pane again.
    @State private var motion = Motion()
    /// From choosing a conversation until it is placed: hidden, so it never shows anywhere
    /// but where it opens (#1287).
    @State private var isPlacing = false
    @State private var isAwaitingFirstPage = false
    /// Opening the conversation in hand (`settle`), until it is placed.
    @State private var settling: Task<Void, Never>?
    /// Whether the conversation's first page is in hand since it was chosen.
    @State private var hasFirstPage = false

    private final class Motion {
        /// Whether the hand last moved the pane down it, rather than up.
        var wentDown = false
        /// Where the pane was when a finger went down on it, and where it is.
        var handStart: CGFloat = 0
        var offset: CGFloat = 0
        /// The first turn on screen: the line an earlier page keeps in place.
        var topTurn: UUID?
        /// Which conversation the pane holds.
        var key: UUID?
        /// How far down the conversation the pane last was.
        var fromTop: CGFloat = .infinity
        /// The turns on screen, top first: what a key pages from.
        var shown: [UUID] = []
        /// How far past the furthest the pane can rest it is (`Edges.pastTheEnd`).
        var pastTheEnd: CGFloat = -.infinity
    }

    /// Send now is for a turn that is running, on a runtime that said it takes words
    /// mid-turn. Starting is not running: there is no turn yet to send them into.
    private var canSendNow: Bool {
        (agent.state == .running || agent.state == .waitingOnUser) && actions.canSendNow(agent.runtimeID)
    }

    /// The conversation as turns: stored and in-hand turns, folded once per change.
    private var rows: [ChatTurn] {
        if folded.stored != stored {
            folded.storedTurns = stored.map(ChatTurn.init)
            folded.stored = stored
        }
        if folded.items != items {
            folded.itemTurns = items.turns(reusing: folded.itemTurns)
            folded.items = items
        }
        return (folded.storedTurns + folded.itemTurns).keepingLastTurnWithEachID()
    }

    var body: some View {
        // Once per pass. Read inside the row closure, `rows` was the whole conversation
        // mapped again for every row it drew (#90).
        let rows = self.rows
        // The conversation cut at each card's place (#973). With none waiting, one stretch.
        let stretches = rows.placing(cards, at: \.at)
        // The live turn is the last row, and when a card cut it, its part after the card.
        let liveID = isWorking ? stretches.last(where: { !$0.turns.isEmpty })?.turns.last?.id : nil
        ScrollViewReader { scroller in
            ScrollView {
                VStack(spacing: 14) {
                    // Named by the first card after them, so a card answered above leaves
                    // the cards below it built as they were.
                    ForEach(Array(stretches.enumerated()), id: \.element.id) { offset, stretch in
                        if !stretch.turns.isEmpty || (offset == 0 && (loadFailure != nil || hasMore)) {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                if offset == 0 {
                                    if let loadFailure {
                                        LoadFailureLine(sentence: loadFailure.sentence, retry: actions.reloadTranscript)
                                    }
                                    if hasMore {
                                        // No button. Reaching the top is the ask.
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                }
                                // Folded once by the model as each entry lands, not here on every
                                // redraw: a reply arrives several chunks a second.
                                // Each turn at the app's level, or the one chosen for it. A new turn
                                // leaves the ones before it as they were: one being read stays open.
                                ForEach(stretch.turns) { turn in
                                    TurnView(turn: turn,
                                             detail: turnViews[turn.id] ?? .initial,
                                             focusedRun: focusedRun,
                                             fetched: fetchedTurns[turn.id]?.items,
                                             hasEarlier: fetchedTurns[turn.id]?.hasEarlier(than: turn) ?? false,
                                             fetchFailed: failedTurns.contains(turn.id),
                                             isLive: turn.id == liveID,
                                             toggle: { toggle(turn) },
                                             fetch: { await fetch(turn) },
                                             fetchEarlier: { await fetchEarlier(turn) })
                                        .equatable()
                                        .id(turn.id)
                                }
                                .environment(\.backgroundWork, agent.background)
                                .environment(\.textIsLazy, true)
                            }
                            // The chat column, shared with the prompt bar below it and with
                            // the cards: one pair of edges down the pane, set in one place
                            // (FR-021).
                            .chatColumn()
                            .scrollTargetLayout()
                        }
                        // Between two lazy stacks rather than in one, so a card scrolled far
                        // away is still built: its half-filled answers and its ⌘1…9 stay
                        // with it (#723).
                        if !stretch.cards.isEmpty {
                            VStack(spacing: 12) {
                                ForEach(stretch.cards) { $0.view }
                            }
                            .id(stretch.cards[0].id)
                        }
                    }
                    if hasFoot {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(agent.queuedPrompts) { queued in
                                QueuedPromptRow(prompt: queued, agentID: agent.id,
                                                canSendNow: canSendNow)
                            }
                            // Kept by the control plane for a stopped workspace (#691 US3).
                            ForEach(actions.kept(agent.id)) { kept in
                                KeptPromptRow(kept: kept)
                            }
                            // Live, and so at the foot rather than in the record: the chat
                            // itself says what the row in the list says, and it stops saying
                            // it the moment the prompt lands.
                            if isComingBack {
                                ComingBackLine()
                            } else if agent.state == .running || agent.state == .starting {
                                WorkingLine()
                            }
                        }
                        .chatColumn()
                    }
                    // In a stack of its own with the end marker, so a chat not yet quiet
                    // has no gap where the line would be.
                    VStack(alignment: .leading, spacing: 0) {
                        if let quietSince {
                            QuietLine(since: quietSince)
                                .chatColumn()
                        }
                        Color.clear.frame(height: 1).id(bottom)
                    }
                }
                .padding(.vertical, 20)
            }
            // Hidden from choosing a conversation until it is placed at its end: its first
            // frame is the end, never a jump to it (#1287, #1349).
            .opacity(isPlacing ? 0 : 1)
            .onScrollTargetVisibilityChange(idType: UUID.self, threshold: 0.01) { visible in
                guard settleKey == motion.key else { return }
                let visible = Set(visible)
                motion.shown = rows.lazy.map(\.id).filter(visible.contains)
                motion.topTurn = motion.shown.first
            }
            // Open at the foot. A lazy stack built from the top and then jumped to the
            // end placed the rows it made on the way (the accessibility tree had them,
            // on screen) but never drew them: a transcript taller than the pane opened
            // blank until something scrolled it. Starting at the end is what `settle`
            // was reaching for, and a plain VStack drew it — the laziness is the part
            // that did not survive the jump. Only where it opens: a transcript shorter
            // than the pane still sits at the top of it.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // And held there as it grows, while following: the scroll view keeps the foot
            // where it is as rows are measured, rather than a move asked for from an estimate
            // of where the foot will be (#378). Reading back, nothing holds the foot.
            .defaultScrollAnchor(isFollowing ? .bottom : nil, for: .sizeChanges)
            .transcriptInput(key: { read($0, scroller) }, hand: hand)
            // The text stops above the floating prompt, and so does the scrollbar.
            // Insetting the content alone left the bar running the whole height of the
            // pane and disappearing under the glass, where it could be neither read nor
            // caught. Two lines rather than one bare `contentMargins`, because the bare
            // one moves the visible area up as well, and the transcript is meant to run
            // on under the glass rather than stop short of it.
            //
            // Held within the pane, which only a card that fills the pane asks for.
            .contentMargins(.bottom, footMargin, for: .scrollContent)
            .contentMargins(.bottom, footMargin, for: .scrollIndicators)
            // A scroll view will not be shorter than its margins, so the margin above
            // made the pane at least as tall as the cards and prompt bar it measured,
            // and they, being given that much, never shrank: a tall question card ran
            // the prompt bar off the bottom of a short window (#371). The pane takes
            // the height it is given whatever the margin, and is measured there.
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
            .onScrollGeometryChange(for: Edges.self) { geometry in
                // `visibleRect` is the content actually on screen, insets included.
                // Measuring from `contentOffset` alone counts the top bar as distance
                // still below the fold, and the pane then chases that distance: a few
                // points down, a few points up, for as long as the chat is open.
                Edges(fromTop: max(0, geometry.visibleRect.minY),
                      fromBottom: max(0, geometry.contentSize.height - geometry.visibleRect.maxY),
                      canScroll: geometry.contentSize.height > geometry.containerSize.height + 1,
                      height: geometry.containerSize.height,
                      contentHeight: geometry.contentSize.height,
                      offset: geometry.contentOffset.y,
                      pastTheEnd: geometry.contentOffset.y - (geometry.contentSize.height
                          + geometry.contentInsets.bottom - geometry.containerSize.height))
            } action: { was, edges in
                // Another conversation chosen, and not yet settled into: what the pane
                // measures is the old one emptied or the new one arriving, and says nothing
                // about where the reader is. Taken for the end, it once resumed following and
                // lost the place they were leaving (#378).
                guard settleKey == motion.key else { return }
                onHeight?(edges.height)
                motion.fromTop = edges.fromTop
                motion.offset = edges.offset
                motion.pastTheEnd = edges.pastTheEnd
                // Near the top, the page above. How far down the pane is does not depend
                // on the content's height, so it is asked for whatever that reads.
                if edges.contentHeight > 1, edges.fromTop < 400 { askForEarlier() }
                // A lazy stack's content size can collapse to the rows it has made
                // for the length of a flick. Even when that sample still exceeds the
                // viewport, treating it as a real shorter page can resume following.
                // Keep the tallest measurement while their hand is on it, and ignore a
                // sample that falls materially below it.
                //
                // Only then. Outside a flick a shorter page is a real one — the front let
                // go while following, an estimate settled — and holding the tallest ever
                // seen took every later sample for a collapse: the pane stopped following
                // short of the end and never asked for the page above (#378).
                let collapsed = isUserScrolling && trustedContentHeight > edges.height + 80
                    && edges.contentHeight < trustedContentHeight - 80
                if collapsed {
                    // The measurement cannot be believed. Stop following now; the honest
                    // sample arrives as they let go, and waiting for it is how a flick
                    // ends at the foot.
                    isFollowing = false
                    return
                }
                trustedContentHeight = isUserScrolling
                    ? max(trustedContentHeight, edges.contentHeight) : edges.contentHeight
                canScroll = edges.canScroll
                guard !isLoadingEarlier else { return }
                // A finger on the pane that has moved it up, by any amount, ends following at
                // once (#378); one that has moved it down is on its way back. A wheel says so
                // itself (`hand`), and so do the keys.
                if isUserScrolling, hasSettled {
                    if edges.offset < motion.handStart - 4 { hand(.up) }
                    else if edges.offset > motion.handStart + 4 { motion.wentDown = true }
                }
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
                // Back at the foot under their own steam. Generous on the way in and
                // strict on the way out: following again a moment early is a small
                // wrong, and being left behind a live conversation is the bug.
                // Not while their hand is still on it: one frame of a flick reads as
                // the end, and resuming follow then pulls them there as they let go.
                // On the way down, or right at it: a reader a few points up from the end
                // stays where they put themselves (#378).
                if !isUserScrolling, edges.fromBottom < atTheEnd, motion.wentDown || edges.pastTheEnd > -1 {
                    motion.wentDown = false
                    isFollowing = true
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
                //
                // Short of the furthest the pane can rest, not merely with the end somewhere in
                // the pane: the foot of the pane is under the prompt, and an end that had only
                // reached the glass was left there, the last lines unread (#378).
                if isFollowing, !isUserScrolling, edges.pastTheEnd < -1 {
                    let grown = edges.contentHeight != lastPinnedHeight
                    // Again whenever the distance changes, not only when it shrinks: the
                    // stack can throw the pane back up as it measures, and no hand did that.
                    // A distance that stays put is not chased, or the pane bounces.
                    let moved = lastPinnedDistance.map { abs(-edges.pastTheEnd - $0) > 0.5 } ?? true
                    if grown || moved {
                        lastPinnedHeight = edges.contentHeight
                        lastPinnedDistance = -edges.pastTheEnd
                        place(scroller, on: bottom, anchor: .bottom)
                    }
                }
                // A page is 200 entries, and a run of tool calls is one line however
                // many entries it took, so a page can come back shorter than the
                // pane. Nothing to scroll means nothing would ever ask for the rest,
                // so a page that does not fill the pane asks for another itself.
                if edges.contentHeight > 1, !edges.canScroll {
                    askForEarlier()
                }
            }
            // What counts as the reader moving the pane. `.animating` is this view's own
            // scrollTo and `.idle` is the conversation growing under a still hand;
            // neither is a reason to stop following.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting:
                    if !isUserScrolling { motion.handStart = motion.offset }
                    isUserScrolling = true
                case .decelerating: isUserScrolling = true
                default:
                    isUserScrolling = false
                    // A flick that ended at the top may leave nothing more to measure.
                    if motion.fromTop < 400 { askForEarlier() }
                }
            }
            .onChange(of: entryCount) { before, after in
                // An earlier page has landed. Hold the line they were on — or the
                // foot, if they were following it. Doing it here rather than in the
                // load is what makes the rows exist to hold: the load's own view
                // value still has the page from before.
                if after > 0 { hasFirstPage = true }
                // The first page, drawn hidden until the pane is placed (`settle`, #1287).
                if before == 0, after > 0, isAwaitingFirstPage { isPlacing = true }
                if isLoadingEarlier, after != before { holdPlace(scroller) }
            }
            // Opened when it comes on screen and when another conversation is chosen, in a
            // task of its own: a phone pushing the chat again tells it it has gone 8 ms after
            // it came, though it stays, and a `.task` ended there was never started again,
            // so the conversation opened wherever it had been (#1287).
            .onAppear { startSettling(scroller) }
            .onChange(of: settleKey) { startSettling(scroller) }
            // Asked for from elsewhere. A message entry is drawn with its own id, so
            // this lands on it.
            .onChange(of: focusedEntry) {
                guard let focusedEntry else { return }
                // In a stored turn's steps, not yet drawn: the turn is opened and its steps
                // fetched, and then gone to (#1532).
                if let focusedIndex, !rows.contains(where: { $0.draws(focusedEntry) }),
                   let turn = rows.first(where: { $0.range?.contains(focusedIndex) == true }) {
                    turnViews[turn.id] = .open
                    isFollowing = false
                    clearFocus()
                    Task {
                        await fetch(turn)
                        try? await Task.sleep(for: .milliseconds(50))
                        withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(focusedEntry, anchor: .center) }
                    }
                    return
                }
                if let turn = rows.first(where: { $0.items.contains { $0.id == focusedEntry } }) {
                    if !(turnViews[turn.id] ?? .initial).showsSteps { turnViews[turn.id] = .open }
                    // A run of calls is drawn as its last: open that run and its call, and
                    // nothing else in the turn (#1315).
                    if turn.items.contains(where: { if case .toolRun = $0 { $0.id == focusedEntry } else { false } }) {
                        focusedRun = focusedEntry
                    }
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
            // The floor rose: the prompt bar grew, and the transcript's bottom margin
            // grew with it. The geometry does not count that as the end moving —
            // content size and offset are what they were — so whoever was following
            // was left with the last thing said under the glass. Only for the
            // follower: a reader elsewhere is not moved (FR-010). A turn of the run
            // loop later, so the new margin is in force before the pane is asked to
            // reach the end.
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
                        JumpToEnd { goToEnd(scroller) }
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

    /// Something to draw after the last turn and the cards: what waits to be sent, and
    /// the line that says the agent is at work.
    private var hasFoot: Bool {
        !agent.queuedPrompts.isEmpty || !actions.kept(agent.id).isEmpty || isComingBack
            || agent.state == .running || agent.state == .starting
    }

    /// When the chat last did anything, for the line at its foot once it is quiet: none
    /// while the agent is at work or coming back, where the foot says so already (#1564).
    private var quietSince: Date? {
        guard !isComingBack, agent.state != .running, agent.state != .starting else { return nil }
        return lastEntryAt ?? agent.lastActivityAt
    }

    /// Open a turn's steps, or close them (`TurnDetail.toggled`).
    private func toggle(_ turn: ChatTurn) {
        turnViews[turn.id] = (turnViews[turn.id] ?? .initial).toggled
    }

    /// A stored turn's entries, the first time it is drawn with its steps. The ask is
    /// the turn's own and is drawn already.
    private func fetch(_ turn: ChatTurn) async {
        guard turn.isSummaryOnly, let range = turn.range, fetchedTurns[turn.id] == nil else { return }
        failedTurns.remove(turn.id)
        let answer = await actions.turnEntries(agent.id, range)
        guard !Task.isCancelled else { return }
        guard let page = answer else {
            failedTurns.insert(turn.id)
            return
        }
        fetchedTurns[turn.id] = FetchedTurn(entries: page.entries,
                                            firstIndex: max(range.lowerBound, page.firstIndex))
        fetchedOrder.removeAll { $0 == turn.id }
        fetchedOrder.append(turn.id)
        while fetchedOrder.count > Self.fetchedKept {
            let dropped = fetchedOrder.removeFirst()
            fetchedTurns[dropped] = nil
            // Still open, it would ask again and push another one out. Closed, it
            // shows the summary it already had (#285).
            if turnViews[dropped]?.showsSteps == true { turnViews[dropped] = .collapsed }
        }
    }

    /// The page of a stored turn before the one held, put in front of it (#519). A turn
    /// longer than a host gives in one answer used to open at its last page with
    /// nothing to say the start of it was missing.
    private func fetchEarlier(_ turn: ChatTurn) async {
        guard let range = turn.range, let held = fetchedTurns[turn.id], held.hasEarlier(than: turn) else { return }
        let answer = await actions.turnEntries(agent.id, range.lowerBound..<held.firstIndex)
        guard !Task.isCancelled, let page = answer, let still = fetchedTurns[turn.id],
              still.firstIndex == held.firstIndex else { return }
        let seen = Set(still.entries.map(\.id))
        fetchedTurns[turn.id] = FetchedTurn(entries: page.entries.filter { !seen.contains($0.id) } + still.entries,
                                            firstIndex: page.entries.isEmpty
                                                ? range.lowerBound
                                                : max(range.lowerBound, page.firstIndex))
    }

    /// Whether the conversation's last turn is still going.
    private var isWorking: Bool {
        switch agent.state {
        case .running, .starting, .waitingOnUser: return true
        default: return false
        }
    }

    /// A key that moves the pane, a turn at a time being what the pane can be sent to: a
    /// pane down puts the last turn on screen at the top, a pane up puts the first at the
    /// foot. Going up is reading back, and ends following as a hand would.
    private func read(_ key: TranscriptKey, _ scroller: ScrollViewProxy) {
        let ids = rows.map(\.id)
        let shown = motion.shown
        func go(_ id: UUID, _ anchor: UnitPoint) {
            withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(id, anchor: anchor) }
        }
        switch key {
        case .end:
            goToEnd(scroller)
        case .top:
            isFollowing = false
            if let first = ids.first { go(first, .top) }
        case .pageUp:
            guard let first = shown.first, let at = ids.firstIndex(of: first) else { return }
            isFollowing = false
            // One turn taller than the pane: the one above it, so the key still moves.
            if shown.count > 1 { go(first, .bottom) } else if at > 0 { go(ids[at - 1], .bottom) } else { go(first, .top) }
        case .pageDown:
            guard let last = shown.last, let at = ids.firstIndex(of: last) else { return }
            if shown.count > 1 { go(last, .top) } else if at + 1 < ids.count { go(ids[at + 1], .top) } else { goToEnd(scroller) }
        }
    }

    /// A hand moved the pane. Up it, by any amount, is reading back: following ends at
    /// once, and nothing that arrives moves the pane after that (#378).
    private func hand(_ way: TranscriptHand) {
        switch way {
        case .up:
            guard hasSettled, canScroll else { return }
            isFollowing = false
            motion.wentDown = false
        case .down:
            motion.wentDown = true
        }
    }

    private func goToEnd(_ scroller: ScrollViewProxy) {
        // Still being placed at the end, out of sight: no animated move on open (#1349).
        guard !isPlacing else { return }
        isFollowing = true
        withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(bottom, anchor: .bottom) }
    }

    /// How far from the foot counts as having left it, and how close counts as being
    /// back at it. Two numbers rather than one: with a single line between the two
    /// states, a conversation arriving a line at a time could flip the mode back and
    /// forth under the reader.
    private var leftTheEnd: CGFloat { 160 }
    private var atTheEnd: CGFloat { 40 }

    /// The room kept at the foot for what floats over it, within the pane (#371).
    ///
    /// A point short of the whole pane at most. With no room at all to scroll in, the
    /// rows sat from the top down instead of at the end, and showed through the gap
    /// between the card and the prompt bar; with a point, the end is held at the top
    /// of the pane, under the card.
    private var footMargin: CGFloat {
        paneHeight.map { min(bottomInset, max(0, $0 - 1)) } ?? bottomInset
    }

    /// How far the pane is from either end of the conversation, and how tall it is.
    private struct Edges: Equatable {
        var fromTop: CGFloat
        var fromBottom: CGFloat
        var canScroll: Bool
        var height: CGFloat
        var contentHeight: CGFloat
        /// Where the pane is scrolled to, and how far past the furthest it can rest at
        /// (negative short of it, positive in a bounce).
        var offset: CGFloat
        var pastTheEnd: CGFloat
    }

    /// Move without animating. An animated move restarts on the next fragment, which
    /// is the stutter this pane used to have, and it is also how a correction and a
    /// hand on the pane end up pulling the page in opposite directions.
    private func place(_ scroller: ScrollViewProxy, on id: some Hashable, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scroller.scrollTo(id, anchor: anchor) }
    }

    private func startSettling(_ scroller: ScrollViewProxy) {
        settling?.cancel()
        settling = Task { await settle(scroller) }
    }

    /// Open at the end, following, every time (#1349), and only then let reaching the top
    /// mean something. A card asked before the end is one tap away, on the "Question
    /// waiting" pill (#723).
    private func settle(_ scroller: ScrollViewProxy) async {
        // Hidden until placed, from the first page on: a lazy stack sent
        // to its end draws its last rows a screen below the fold, then moves them up as it
        // measures (#1287). A chat with nothing yet stays shown while it waits.
        isPlacing = entryCount > 0
        defer { isPlacing = false }
        motion.key = settleKey
        motion.pastTheEnd = -.infinity
        motion.topTurn = nil
        motion.wentDown = false
        turnViews = [:]
        focusedRun = nil
        fetchedTurns = [:]
        fetchedOrder = []
        hasSettled = false
        isFollowing = true
        isUserScrolling = false
        trustedContentHeight = 0
        lastPinnedHeight = nil
        lastPinnedDistance = nil
        restoreIDs = []
        restoreFollowing = false
        // The first page arrives a moment after the selection does. Waiting for it
        // rather than guessing at a delay is what keeps a big transcript from
        // opening halfway up itself.
        //
        // Told by `entryCount` changing, and read from state: this task holds the view as
        // it was when the conversation was chosen, so its own `entryCount` never moved,
        // and every open waited out the whole deadline at the top of the page (#378).
        hasFirstPage = entryCount > 0
        isAwaitingFirstPage = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !hasFirstPage, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        isAwaitingFirstPage = false
        guard !Task.isCancelled else { return }
        place(scroller, on: bottom, anchor: .bottom)
        // Placed again, out of sight, until it stops moving: the rows above the end are
        // measured after the move, and a long chat's grew enough to leave it a screen short
        // of the end (#1287, #1349). Shown three samples running at rest, or after 400 ms.
        let shownBy = ContinuousClock.now.advanced(by: .milliseconds(400))
        var resting = 0
        var last = motion.pastTheEnd
        while resting < 3, ContinuousClock.now < shownBy, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            place(scroller, on: bottom, anchor: .bottom)
            let now = motion.pastTheEnd
            resting = now.isFinite && abs(now - last) < 0.5 ? resting + 1 : 0
            last = now
        }
        isPlacing = false
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
        // The turn at the top of the pane first: the first row in hand can sit a screen
        // above what they are reading, and putting it at the top moved them by that much.
        restoreIDs = (motion.topTurn.map { [$0] } ?? []) + rows.prefix(8).map(\.id)
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

/// A card that waits on the person, and when it was asked: where it is drawn (#973).
struct WaitingCard: Identifiable {
    let id: String
    let at: Date
    let view: AnyView

    init(id: String, at: Date, @ViewBuilder _ view: () -> some View) {
        self.id = id
        self.at = at
        self.view = AnyView(view())
    }
}

extension ChatStretch where Card == WaitingCard {
    /// Named by its first card, the one after its turns; the stretch with none is the end.
    var id: String { cards.first?.id ?? "end" }
}

/// The history, or part of it, that did not load, and the way to ask again (#400).
private struct LoadFailureLine: View {
    let sentence: String
    let retry: @MainActor () async -> Void
    @State private var retrying = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(sentence, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Try Again") {
                retrying = true
                Task {
                    await retry()
                    retrying = false
                }
            }
            .disabled(retrying)
        }
        .appText(.fine)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension ChatTurn {
    /// Whether the chat draws a row with this id for the turn as it stands: its ask, its
    /// items, or a stored turn's outcome.
    func draws(_ id: UUID) -> Bool {
        ask?.id == id || items.contains { $0.id == id } || (storedOutcome ?? []).contains { $0.id == id }
    }
}
