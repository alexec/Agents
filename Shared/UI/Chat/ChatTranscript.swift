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
    /// What waits on the person (questions, forms, guarded changes) and the agent's wait on
    /// events, drawn in the conversation rather than over it (#723), after all of it
    /// (#1995). Each card keeps the chat column itself.
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

    /// Whether the agent's thoughts are drawn (#1725), from Settings ▸ Appearance.
    @AppStorage(ChatThoughts.showsKey, store: WindowDefaults.store) private var showsThoughts = ChatThoughts.showsAtFirst
    /// The stored turns whose entries were let go, by id (#285). Kept until the chat is left.
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
        /// The in-hand items without their thoughts, made again only when they change (#1849).
        let shown = ShownItems()
        /// Each turn's rows, by its id, cut again only when what it draws changes: a reply
        /// arrives several chunks a second (P20261022-18).
        var cuts: [UUID: Cut] = [:]

        struct Cut {
            let turn: ChatTurn
            let detail: TurnDetail
            let fetched: [TranscriptItem]?
            let isLive: Bool
            let rows: [TurnRows.Row]
        }
    }

    /// A row of the transcript that is a turn, or part of a turn whose reply is long
    /// (`TurnRows`, P20261022-18). The turn's first row has its id.
    private struct TurnRow: Identifiable {
        let turn: ChatTurn
        let row: TurnRows.Row
        let isLast: Bool
        var id: UUID { row.id }
    }

    /// A stored turn's entries as far back as they have been fetched, folded once.
    private struct FetchedTurn {
        let entries: [TranscriptEntry]
        /// Where `entries` starts in the transcript: past the turn's start when it has
        /// earlier steps not yet asked for (#519).
        let firstIndex: Int
        /// The ask is the turn's own and is drawn already.
        let items: [TranscriptItem]
        /// `items` with the thoughts left off, made once, so a turn drawn again compares the
        /// same array (#1849).
        let itemsWithoutThoughts: [TranscriptItem]

        init(entries: [TranscriptEntry], firstIndex: Int) {
            self.entries = entries
            self.firstIndex = firstIndex
            let items = TranscriptEntry.display(entries)
            self.items = items.first?.isPersonsAsk == true ? Array(items.dropFirst()) : items
            itemsWithoutThoughts = self.items.omittingThoughts()
        }

        func items(showsThoughts: Bool) -> [TranscriptItem] {
            showsThoughts ? items : itemsWithoutThoughts
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
    /// How tall and how wide the pane is: the foot's margin is held to its height (#371),
    /// and the chat column is worked out from its width once, not by each row.
    @State private var paneHeight: CGFloat?
    @State private var paneWidth: CGFloat = 0
    /// Every row's height and place, and the row a reader's place is held by (#2310).
    @State private var geometry = TranscriptGeometry()
    /// The span of the content whose rows are drawn: the screen and a pane either side.
    /// Moved only when the screen nears its edge. Following, the end is drawn instead.
    @State private var drawnSpan: ClosedRange<Double> = 0...0
    /// Asks the rows to be laid out again after what holds them was changed outside a
    /// layout pass (opening a conversation).
    @State private var layoutPass = 0
    /// The slack, as the margin that keeps the pane out of it: the pane goes no higher
    /// than the first row, however much empty space is kept above it for a page (#2310).
    /// Taken off the top of the rows, so the content starts at the first row and counts
    /// from there; `Edges` puts it back, so the rest counts in the rows' own places.
    @State private var slackMargin: CGFloat = 0
    /// How the pane last moved, kept where writing it does not draw the pane again.
    @State private var motion = Motion()
    /// Moves the pane: the one way this view moves it (#2310).
    @State private var position = ScrollPosition(idType: UUID.self)
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
        /// Which conversation the pane holds.
        var key: UUID?
        /// The part of the content on screen.
        var visibleTop: Double = 0
        var visibleBottom: Double = 0
        /// The rows drawn, by id: only these can let their steps go unseen.
        var drawn: Set<UUID> = []
        /// What sits over the top of the pane, a title or navigation bar.
        var barInset: CGFloat = 0

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
        let items = folded.shown.of(self.items, showsThoughts: showsThoughts)
        if folded.items != items {
            folded.itemTurns = items.turns(reusing: folded.itemTurns)
            folded.items = items
        }
        return (folded.storedTurns + folded.itemTurns).keepingLastTurnWithEachID()
    }

    /// The turns as rows: a long reply is several, so a turn drawn lays out a few screens of
    /// its reply, not all of it (P20261022-18).
    private func cut(_ turns: [ChatTurn], liveID: UUID?) -> [TurnRow] {
        if folded.cuts.count > turns.count * 2 {
            let now = Set(turns.map(\.id))
            folded.cuts = folded.cuts.filter { now.contains($0.key) }
        }
        return turns.flatMap { turn -> [TurnRow] in
            let detail = turnViews[turn.id] ?? .initial
            let fetched = fetchedTurns[turn.id]?.items(showsThoughts: showsThoughts)
            let isLive = turn.id == liveID
            let rows: [TurnRows.Row]
            if let was = folded.cuts[turn.id], was.turn == turn, was.detail == detail, was.fetched == fetched,
               was.isLive == isLive {
                rows = was.rows
            } else {
                let outcome = TurnView.outcome(of: turn, detail: detail, fetched: fetched, isLive: isLive)
                rows = TurnRows.rows(of: turn.id, outcome: outcome)
                folded.cuts[turn.id] = FoldedTurns.Cut(turn: turn, detail: detail, fetched: fetched,
                                                       isLive: isLive, rows: rows)
            }
            return rows.enumerated().map { TurnRow(turn: turn, row: $1, isLast: $0 == rows.count - 1) }
        }
    }

    var body: some View {
        // Once per pass. Read inside the row closure, `rows` was the whole conversation
        // mapped again for every row it drew (#90).
        let rows = self.rows
        let liveID = isWorking ? rows.last?.id : nil
        // The head (the load failure, the spinner for the page above), every turn, and the
        // foot (what waits to be sent, the working line, the cards), as the stack lays them out.
        let turnRows = cut(rows, liveID: liveID)
        let ids = [Self.head] + turnRows.map(\.id) + [Self.foot]
        let drawn = drawnRows(ids, turns: [Self.head] + turnRows.map(\.turn.id) + [Self.foot])
        let column = paneWidth > 0 ? ChatMetrics.forPane(width: paneWidth) : nil
        ScrollViewReader { scroller in
            ScrollView {
                TranscriptStack(ids: ids, geometry: geometry, pass: layoutPass) {
                    if drawn.contains(0) || ids.count < 3 {
                        head.inColumn(column)
                            .layoutValue(key: TranscriptRowID.self, value: Self.head)
                    }
                    // Folded once by the model as each entry lands, not here on every
                    // redraw: a reply arrives several chunks a second. Only the turns drawn.
                    ForEach(turnRows[Self.turns(drawn, of: turnRows.count)]) { part in
                        let turn = part.turn
                        TurnView(turn: turn,
                                 detail: turnViews[turn.id] ?? .initial,
                                 focusedRun: focusedRun,
                                 fetched: fetchedTurns[turn.id]?.items(showsThoughts: showsThoughts),
                                 hasEarlier: fetchedTurns[turn.id]?.hasEarlier(than: turn) ?? false,
                                 fetchFailed: failedTurns.contains(turn.id),
                                 isLive: turn.id == liveID,
                                 loadSteps: { loadSteps(turn) },
                                 fetch: { await fetch(turn) },
                                 fetchEarlier: { await fetchEarlier(turn) },
                                 row: part.row,
                                 isLastRow: part.isLast)
                            .equatable()
                            .inColumn(column)
                            .layoutValue(key: TranscriptRowID.self, value: part.id)
                            .id(part.id)
                    }
                    .environment(\.backgroundWork, agent.background)
                    foot(column)
                        .layoutValue(key: TranscriptRowID.self, value: Self.foot)
                }
                // Out of the slack: the rows less the empty space above them. Not a negative
                // top margin on the scroll view, which hid every row from the pointer: no
                // click reached a question card's choices or any other row (#2374).
                .padding(.top, -slackMargin)
            }
            .scrollPosition($position)
            // Hidden from choosing a conversation until it is placed at its end: its first
            // frame is the end, never a jump to it (#1287, #1349).
            .opacity(isPlacing ? 0 : 1)
            // Open at the foot, and held there as it grows while following. The content's
            // height is the sum of the rows' own, so the foot is where it says (#2310).
            .defaultScrollAnchor(.bottom, for: .initialOffset)
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: {
                paneHeight = $0.height
                if abs($0.width - paneWidth) > 0.5 { paneWidth = $0.width }
            }
            .onScrollGeometryChange(for: Edges.self) { geometry in
                // The screen in the rows' own places, the slack above them put back: the
                // content starts at the first row, the slack taken off its top (#2374).
                // Read with the margin the content was laid out by, so `was` and `edges`
                // each count by their own.
                Edges(contentHeight: geometry.contentSize.height + slackMargin,
                      offset: geometry.contentOffset.y + slackMargin,
                      footInset: geometry.contentInsets.bottom, height: geometry.containerSize.height,
                      topInset: geometry.contentInsets.top)
            } action: { was, edges in
                #if os(macOS)
                // The pane is its own frame and the title bar it runs under. On iOS the
                // container is the pane, safe area and all.
                var edges = edges, was = was
                if let paneHeight {
                    edges.height = paneHeight + edges.topInset
                    was.height = paneHeight + was.topInset
                }
                #endif
                moved(was, edges)
            }
            // What counts as the reader moving the pane. `.animating` is this view's own
            // move and `.idle` is the conversation growing under a still hand; neither is a
            // reason to stop following.
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .tracking, .interacting:
                    if !isUserScrolling { motion.handStart = motion.offset }
                    isUserScrolling = true
                case .decelerating: isUserScrolling = true
                default: isUserScrolling = false
                }
            }
            .onChange(of: entryCount) { before, after in
                if after > 0 { hasFirstPage = true }
                // The first page, drawn hidden until the pane is placed (`settle`, #1287).
                if before == 0, after > 0, isAwaitingFirstPage { isPlacing = true }
            }
            // Opened when it comes on screen and when another conversation is chosen, in a
            // task of its own: a phone pushing the chat again tells it it has gone 8 ms after
            // it came, though it stays, and a `.task` ended there was never started again,
            // so the conversation opened wherever it had been (#1287).
            .onAppear { startSettling() }
            .onChange(of: settleKey) { startSettling() }
            // Asked for from elsewhere. A message entry is drawn with its own id, so
            // this lands on it once its turn is drawn.
            .onChange(of: focusedEntry) {
                guard let focusedEntry else { return }
                // In a stored turn's steps, not yet drawn: the turn is drawn, its steps
                // fetched, and then gone to (#1532).
                if let focusedIndex, !rows.contains(where: { $0.draws(focusedEntry) }),
                   let turn = rows.first(where: { $0.range?.contains(focusedIndex) == true }) {
                    turnViews[turn.id] = .open
                    goTo(turn.id)
                    clearFocus()
                    Task {
                        await fetch(turn)
                        try? await Task.sleep(for: .milliseconds(50))
                        scroller.scrollTo(focusedEntry, anchor: .center)
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
                    goTo(turn.id)
                }
                // Being sent to a line in the middle is being sent away from the end,
                // and it was asked for. Following on from here would take the reader
                // straight back off the line they were sent to.
                stopFollowing()
                Task { @MainActor in scroller.scrollTo(focusedEntry, anchor: .center) }
                clearFocus()
            }
            .onChange(of: scrollToEndToken) { goToEnd() }
            .onChange(of: isFollowing) { _, now in onFollowing(now) }
            // Nobody is reading a chat that is not on screen, so it may be trimmed again.
            .onDisappear { onFollowing(true) }
            // The floor rose: the prompt bar grew, and the transcript's bottom margin with
            // it. The content is what it was, so whoever was following was left with the
            // last thing said under the glass. Only for the follower: a reader elsewhere is
            // not moved (FR-010). A turn of the run loop later, so the new margin is in
            // force first; not eased, as nothing that moves the pane is (#2310).
            .onChange(of: bottomInset) { before, after in
                guard after > before, isFollowing else { return }
                Task { @MainActor in position.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottom) {
                // The fade belongs to the button alone. The same animation on the
                // scroll view eased every correction, so a reader and the pane pulled
                // against each other for the length of the ease.
                ZStack(alignment: .bottom) {
                    if canScroll, !isFollowing {
                        JumpToEnd { goToEnd() }
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

    /// Above the first turn: the history that did not load, and the page above coming.
    private var head: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        .padding(.top, 20)
        .padding(.bottom, loadFailure == nil && !hasMore ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// After the last turn, always drawn: what waits to be sent, the working line, and what
    /// waits on the person, whose half-filled answers and ⌘1…9 stay with it however far
    /// away the reader is (#723).
    private func foot(_ column: ChatMetrics?) -> some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(agent.queuedPrompts) { queued in
                    QueuedPromptRow(prompt: queued, agentID: agent.id, canSendNow: canSendNow)
                }
                // Kept by the control plane for a stopped workspace (#691 US3).
                ForEach(actions.kept(agent.id)) { kept in
                    KeptPromptRow(kept: kept)
                }
                // Live, and so at the foot rather than in the record: the chat itself says
                // what the row in the list says, and it stops saying it the moment the
                // prompt lands.
                if isComingBack {
                    ComingBackLine()
                } else if agent.state == .running || agent.state == .starting {
                    // The one working mark on the page, always here: never in a tool's or a
                    // thought's line, where it moved the words and jumped about (#2831).
                    WorkingLine(tool: RunningToolWords.tool(agent))
                }
                // What it holds and waits for in line: what the agent is doing now, as the
                // working line says, so here and not over the prompt (#2344). A place in line
                // that its wait card says is left to the card (#2361).
                if let leases = actions.leaseStatus(agent.id)?.without(agent.eventWait) {
                    LeaseLine(status: leases, open: actions.openLease)
                }
            }
            .inColumn(column)
            // Last, after everything the agent said and everything waiting to be sent
            // (#1995): what waits on the person is where the reader is. Each card keeps the
            // chat column itself.
            if !cards.isEmpty {
                VStack(spacing: 12) {
                    ForEach(cards) { $0.view }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let quietSince {
                    QuietLine(since: quietSince)
                        .inColumn(column)
                }
                Color.clear.frame(height: 1).id(bottom)
            }
        }
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }

    /// The turns among the rows drawn, as indices into the turns: the rows less the head
    /// before them and the foot after.
    private static func turns(_ drawn: Range<Int>, of count: Int) -> Range<Int> {
        let lower = min(max(drawn.lowerBound, 1) - 1, count)
        return lower..<max(lower, min(drawn.upperBound - 1, count))
    }

    /// The rows to draw, as indices into `ids`: those in `drawnSpan`, or following, the end
    /// and half a pane above the screen. The foot is drawn whatever this says. `turns` is
    /// the turn each row is of: a turn with any row drawn keeps its steps.
    private func drawnRows(_ ids: [UUID], turns: [UUID]) -> Range<Int> {
        let placed = geometry.place(ids)
        let pane = Double(paneHeight ?? 800)
        let span = isFollowing ? (placed.height - pane * 1.5)...(placed.height) : drawnSpan
        let range = TranscriptPlacement.window(tops: placed.tops, heights: geometry.heights,
                                               from: span.lowerBound, to: span.upperBound)
        motion.drawn = Set(turns[range])
        return range
    }

    /// The pane moved, or what is in it changed size.
    private func moved(_ was: Edges, _ edges: Edges) {
        // Another conversation chosen, and not yet settled into: what the pane measures is
        // the old one emptied or the new one arriving, and says nothing about the reader.
        guard settleKey == motion.key else { return }
        onHeight?(edges.height)
        motion.offset = edges.offset
        motion.barInset = edges.topInset
        motion.visibleTop = edges.top
        motion.visibleBottom = edges.bottom
        // The slack ran out under a reader: everything went down by as much, and so does
        // the pane (`TranscriptGeometry.shift`).
        if geometry.shift > 0 {
            let by = geometry.shift
            geometry.shift = 0
            drawnSpan = (drawnSpan.lowerBound + by)...(drawnSpan.upperBound + by)
            slackMargin = geometry.slack
            scroll(to: edges.offset + by)
            return
        }
        // The margin follows the slack. A scroll view keeps its offset from the margin, not
        // from the content, so the screen is put back where it was in the same update.
        if abs(geometry.slack - slackMargin) > 0.5 {
            slackMargin = geometry.slack
            if !isFollowing { scroll(to: edges.top) }
        }
        let pane = edges.height
        // The rows drawn follow the screen, a pane either side, moved only near the edge.
        if !isFollowing, edges.top - pane / 2 < drawnSpan.lowerBound || edges.bottom + pane / 2 > drawnSpan.upperBound {
            drawnSpan = (edges.top - pane)...(edges.bottom + pane)
        }
        let rowsHeight = edges.contentHeight - geometry.slack
        canScroll = rowsHeight > edges.height + 1
        // A finger on the pane that has moved it up, by any amount, ends following at once
        // (#378); one that has moved it down is on its way back. A wheel says so itself
        // (`hand`), and so do the keys.
        if isUserScrolling, hasSettled {
            if edges.offset < motion.handStart - 4 { hand(.up) }
            else if edges.offset > motion.handStart + 4 { motion.wentDown = true }
        }
        // Reading: the row at the top of the screen holds the place. Choosing it again
        // moves nothing: it is where it was laid out.
        if !isFollowing {
            geometry.hold(from: edges.top, to: edges.bottom)
        } else if hasSettled, edges.offset < was.offset - 0.5, edges.contentHeight == was.contentHeight,
                  edges.height == was.height, edges.pastTheEnd < -1 {
            // Up the pane with nothing changing size, and not held at the end by a margin
            // that shrank: the content's height is a sum the transcript made, so only a
            // reader does that (#2310).
            hand(.up)
        }
        // Back at the foot under their own steam. Generous on the way in and strict on the
        // way out. Not while their hand is still on it: one frame of a flick reads as the
        // end, and following then pulls them there as they let go. On the way down, or
        // right at it: a reader a few points up from the end stays there (#378).
        if !isFollowing, !isUserScrolling, edges.fromBottom < atTheEnd, motion.wentDown || edges.pastTheEnd > -1 {
            follow()
        }
        // Following and short of the end: once, with nothing to chase, as the content's
        // height is its own (#2310).
        if isFollowing, !isUserScrolling, !isPlacing, edges.pastTheEnd < -1 {
            position.scrollTo(edge: .bottom)
        }
        // Near the first turn, the page above. A page that does not fill the pane asks for
        // the next itself: nothing to scroll would never ask.
        if let first = geometry.ids.dropFirst().first, let top = geometry.top(of: first),
           edges.top - top < 400 || !canScroll {
            askForEarlier()
        }
    }

    /// When the chat last did anything, for the line at its foot once it is quiet: none
    /// while the agent is at work or coming back, where the foot says so already (#1564).
    private var quietSince: Date? {
        guard !isComingBack, agent.state != .running, agent.state != .starting else { return nil }
        return lastEntryAt ?? agent.lastActivityAt
    }

    /// Draw a let-go turn with its steps again: it fetches them as it is drawn.
    private func loadSteps(_ turn: ChatTurn) {
        turnViews[turn.id] = .open
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
        // Eight kept, the oldest not drawn let go first: it goes back to its summary and
        // fetches its steps again when it is drawn. Only turns drawn fetch, so this cannot
        // go round in a loop, and a turn that shrinks off screen above the reader moves
        // nothing on it: the slack takes it (#2310).
        while fetchedOrder.count > Self.fetchedKept,
              let at = fetchedOrder.firstIndex(where: { !motion.drawn.contains($0) }) {
            fetchedTurns[fetchedOrder.remove(at: at)] = nil
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

    /// A key that moves the pane: a pane at a time, less a few lines so the reader keeps
    /// their place, or to either end. Going up is reading back, and ends following as a
    /// hand would.
    private func read(_ key: TranscriptKey, _ scroller: ScrollViewProxy) {
        let page = max(40, Double(paneHeight ?? 400) - 60)
        switch key {
        case .end:
            goToEnd()
        case .top:
            guard let first = geometry.ids.dropFirst().first else { return }
            goTo(first)
        case .pageUp:
            stopFollowing()
            let to = max(geometry.slack, motion.visibleTop - page)
            drawnSpan = (to - page)...(motion.visibleBottom + page)
            scroll(to: to)
        case .pageDown:
            guard !isFollowing else { return }
            let to = motion.visibleTop + page
            if to + (motion.visibleBottom - motion.visibleTop) >= geometry.height - 1 { goToEnd(); return }
            drawnSpan = (motion.visibleTop - page)...(motion.visibleBottom + page * 2)
            scroll(to: to)
        }
    }

    /// To a turn: drawn first, held where it is laid out, and the pane put at its top.
    private func goTo(_ id: UUID) {
        guard let top = geometry.top(of: id) else { return }
        stopFollowing()
        let pane = Double(paneHeight ?? 800)
        drawnSpan = (top - pane)...(top + pane * 2)
        geometry.anchor = (id, top)
        scroll(to: max(geometry.slack, top - 20))
    }

    /// A hand moved the pane. Up it, by any amount, is reading back: following ends at
    /// once, and nothing that arrives moves the pane after that (#378).
    private func hand(_ way: TranscriptHand) {
        switch way {
        case .up:
            guard hasSettled, canScroll else { return }
            stopFollowing()
            motion.wentDown = false
        case .down:
            motion.wentDown = true
        }
    }

    /// Reading back: held by the row at the top of the screen, before anything moves.
    private func stopFollowing() {
        guard isFollowing else { return }
        geometry.hold(from: motion.visibleTop, to: motion.visibleBottom)
        drawnSpan = (motion.visibleTop - Double(paneHeight ?? 800))...(motion.visibleBottom + Double(paneHeight ?? 800))
        isFollowing = false
    }

    /// Following the end again: nothing holds a row, and the slack is what it should be.
    private func follow() {
        motion.wentDown = false
        geometry.follow()
        isFollowing = true
    }

    private func goToEnd() {
        // Still being placed at the end, out of sight.
        guard !isPlacing else { return }
        follow()
        // Where the last finger went down says nothing about this move: only a new one may
        // end following again.
        motion.handStart = -.infinity
        position.scrollTo(edge: .bottom)
    }

    /// Moves the pane so the screen starts at `y` in the rows' own places. A scroll position
    /// counts from the top margin, the bar over the pane, in the content, which starts
    /// below the slack (#2310, #2374). Never eased: an
    /// eased move started as following ends was dropped, and nothing that moves this pane
    /// is eased.
    private func scroll(to y: Double) {
        position.scrollTo(y: y + motion.barInset - slackMargin)
    }

    /// How far from the foot counts as being back at it.
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

    /// Where the pane is, and what is in it.
    private struct Edges: Equatable {
        var contentHeight: CGFloat
        /// Where the pane is scrolled to: where the screen starts in the content.
        var offset: CGFloat
        /// The margin under the floating prompt.
        var footInset: CGFloat
        /// How tall the pane is.
        var height: CGFloat
        /// The margin over the content: a bar over the pane.
        var topInset: CGFloat

        /// The part of the content on screen.
        var top: Double { offset }
        var bottom: Double { offset + height }
        /// How far past the furthest the pane can rest it is: negative short of it, positive
        /// in a bounce.
        var pastTheEnd: CGFloat { offset - (contentHeight + footInset - height) }
        var fromBottom: CGFloat { max(0, -pastTheEnd) }
    }

    private func startSettling() {
        settling?.cancel()
        settling = Task { await settle() }
    }

    /// Open at the end, following, every time (#1349), and only then let reaching the top
    /// mean something. A card asked before the end is one tap away, on the "Question
    /// waiting" pill (#723).
    private func settle() async {
        // Hidden until placed, from the first page on (#1287). A chat with nothing yet
        // stays shown while it waits.
        isPlacing = entryCount > 0
        defer { isPlacing = false }
        motion.key = settleKey
        motion.wentDown = false
        turnViews = [:]
        focusedRun = nil
        fetchedTurns = [:]
        fetchedOrder = []
        hasSettled = false
        isFollowing = true
        isUserScrolling = false
        // Room above the first turn for every page there may be. Set once: only a page that
        // lands, or a turn above the reader that grows, takes from it, and the margin keeps
        // the pane out of what is left (#2310).
        geometry.reset(slack: TranscriptGeometry.reserve)
        slackMargin = TranscriptGeometry.reserve
        layoutPass += 1
        // The first page arrives a moment after the selection does. Waiting for it rather
        // than guessing at a delay is what keeps a big transcript from opening halfway up.
        // Told by `entryCount` changing, and read from state: this task holds the view as
        // it was when the conversation was chosen (#378).
        hasFirstPage = entryCount > 0
        isAwaitingFirstPage = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !hasFirstPage, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
        }
        isAwaitingFirstPage = false
        guard !Task.isCancelled else { return }
        // Two frames: one to draw the end's rows and measure them, one to stand at the end
        // of what they measured. Nothing is estimated in what is on screen (#2310).
        position.scrollTo(edge: .bottom)
        try? await Task.sleep(for: .milliseconds(32))
        position.scrollTo(edge: .bottom)
        try? await Task.sleep(for: .milliseconds(16))
        isPlacing = false
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        hasSettled = true
    }

    /// Another page above. Following, the foot holds itself; reading, the row held does
    /// (#2310). A beat after it lands before the next one, so one flick does not swallow
    /// the whole file.
    private func askForEarlier() {
        guard hasSettled, !isLoadingEarlier, hasMore else { return }
        isLoadingEarlier = true
        Task {
            await loadEarlier()
            try? await Task.sleep(for: .milliseconds(250))
            isLoadingEarlier = false
        }
    }

    /// The rows of the transcript that are not turns.
    private static let head = UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!
    private static let foot = UUID(uuidString: "00000000-0000-0000-0000-00000000F007")!

    private var bottom: String { "bottom" }
}

private extension View {
    /// In the chat column worked out once for the pane (`ChatMetrics`): the same edges as
    /// `chatColumn()`, which measures the pane itself a pass late, so a row it held was
    /// measured twice (#2310).
    func inColumn(_ metrics: ChatMetrics?) -> some View {
        padding(.horizontal, metrics?.padding ?? ChatMetrics.widePadding)
            .frame(maxWidth: metrics.map { $0.measure + $0.padding * 2 } ?? .infinity)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A card that waits on the person, or the agent's wait on events (#1995), drawn at the
/// end of the conversation.
struct WaitingCard: Identifiable {
    let id: String
    let view: AnyView

    init(id: String, @ViewBuilder _ view: () -> some View) {
        self.id = id
        self.view = AnyView(view())
    }
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
