import SwiftUI

/// The history window: everything the policy engine let through, banner or
/// not — and the one surface where nothing is a glance.
///
/// It is three things at once, which is why it earns a window: the plain
/// history, **the ledge's overflow** (`trill inbox --asks`, where an ask that
/// yielded its fin to a newer one is still findable), and **the digest's
/// landing** (a card's click is a query against this list, not a second
/// store). The scope arrives from the click; everything below is a view onto
/// `AppDatabase` through `InboxList`, which does the scoping, searching and
/// thread-folding as pure functions.
///
/// **It never redacts.** Shyness is a rendering rule for cards drawn *at*
/// someone — the banner stack, the ledge — and `--redact` is documented as
/// keeping a body off the banner, not out of the inbox. This window only
/// exists because the user summoned it; hiding what they came to read would
/// make it useless in exactly the moment they opened it on purpose.
struct InboxView: View {
    /// Which database to read, when to re-read it, and what is still parked.
    /// Observed rather than handed a database once: history can be switched
    /// off while this window is up, and the window has to follow.
    @ObservedObject var feed: InboxFeed
    /// Which slice of history this window is for — the plain list, the asks
    /// the ledge parks (`trill inbox --asks`), or the events behind one
    /// digest card.
    var scope: InboxScope = .all
    /// Where a pill goes. The same router the banners use, so a click here
    /// and a click there do exactly the same thing. Nil in surfaces with no
    /// daemon behind them, which draws the pills inert — so they aren't drawn.
    var router: ActionRouter?

    @State private var entries: [InboxEntry] = []
    @State private var query = ""
    @State private var unreadOnly: Bool
    /// Thread ids whose mates are showing. Threads open closed: the fold is
    /// the whole reason a fifteen-message thread is one row.
    @State private var openThreads: Set<String> = []
    /// Ages are computed against this rather than each row keeping its own
    /// `TimelineView` — one state bump re-renders the handful of rows the
    /// List actually has on screen, where a thousand timelines would not be
    /// so kind.
    @State private var now = Date()
    @FocusState private var searchFocused: Bool

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Written out rather than left to the memberwise one for a single line:
    /// the unread filter starts where the *scope* says it should, so a
    /// catch-up card's click lands on exactly the events it counted. Doing it
    /// in `onAppear` instead would show the wider list for a frame and then
    /// visibly narrow it.
    init(feed: InboxFeed, scope: InboxScope = .all, router: ActionRouter? = nil) {
        self.feed = feed
        self.scope = scope
        self.router = router
        _unreadOnly = State(initialValue: scope.opensUnreadOnly)
    }

    private var rows: [InboxRow] {
        InboxList.rows(from: entries, scope: scope, query: query, unreadOnly: unreadOnly)
    }

    /// Everything unread in this scope — the number that answers "how much
    /// went past me", which is why it stays whole while a search narrows.
    private var unreadCount: Int {
        InboxList.inScope(entries, scope: scope).filter(\.isUnread).count
    }

    /// Unread among the rows actually on screen — what Mark All Read would
    /// touch, and therefore what it is enabled by.
    private var visibleUnreadCount: Int {
        rows.reduce(0) { $0 + $1.unreadCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySymbol,
                    description: Text(emptyMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(minWidth: 460, minHeight: 360)
        // Live. A delivered event bumps the revision *after* the repository
        // enqueued its insert, and reads share that write's serial queue —
        // so by the time this fires the row is really there. No polling, and
        // no Refresh button: a history window you have to ask for the news is
        // a history window you stop opening.
        .onChange(of: feed.revision) { entries = fetch(from: feed.database) }
        // Also the first load: a `@Published` publisher replays its current
        // value on subscribe, so this fires once as the window comes up and
        // again if history is switched off underneath it.
        .onReceive(feed.$database) { entries = fetch(from: $0) }
        .onReceive(clock) { now = $0 }
        .trillType()
    }

    /// The window's own chrome rather than an `NSToolbar`: this window is a
    /// bare `NSHostingView` (no navigation container), which is where
    /// `.searchable` and `.toolbar` have nothing to attach to. Settings draws
    /// its own for the same reason.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .frame(maxWidth: 260)

            Spacer(minLength: 0)

            Toggle(isOn: $unreadOnly) {
                Label(
                    unreadCount > 0 ? "Unread (\(unreadCount))" : "Unread",
                    systemImage: unreadOnly ? "largecircle.fill.circle" : "circle"
                )
                .font(AppFont.caption)
            }
            .toggleStyle(.button)
            .help("Show only what trill never put in front of you")

            Button("Mark All Read", systemImage: "checkmark.circle") {
                markAllRead()
            }
            .font(AppFont.caption)
            .labelStyle(.titleOnly)
            .disabled(visibleUnreadCount == 0)
            .help("Marks what this window is showing — not what a search is hiding")

            // ⌘F, without a search field that owns the window's toolbar.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        List {
            ForEach(rows) { row in
                InboxRowView(
                    row: row,
                    now: now,
                    expanded: row.thread.map(openThreads.contains) ?? false,
                    onLedge: feed.parkedIDs,
                    canAct: router != nil,
                    onOpen: { open(row) },
                    onAction: { action, event in router?.perform(action, for: event) },
                    onToggleRead: { setRead(!row.isUnread, in: row) }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
            }
            if entries.count >= InboxList.fetchLimit {
                // Said out loud rather than left to look like the whole of
                // history: the window reads a bounded slice, and a search
                // that finds nothing past it should say why.
                Text("Showing the most recent \(InboxList.fetchLimit) events.")
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    // MARK: - Reading

    private func fetch(from database: AppDatabase?) -> [InboxEntry] {
        guard let database else { return [] }
        switch scope {
        case .all, .asks:
            // `.asks` is the same query narrowed by kind in `InboxList` —
            // the database has no answered/unanswered state (answering a
            // banner is not a write), so the honest filter is the kind, and
            // the ledge tells us which of those are still hanging.
            return database.recent(limit: InboxList.fetchLimit)
        case .digest(let name, let since):
            return database.digest(named: name, since: since, limit: InboxList.fetchLimit)
        case .since(let instant):
            return database.events(since: instant, limit: InboxList.fetchLimit)
        }
    }

    // MARK: - Read state

    /// Opening a row is reading it. A thread opens as a whole — you clicked
    /// the thing that said "9 more", so all nine have now been offered to
    /// you — and closing it again doesn't put the dot back.
    private func open(_ row: InboxRow) {
        if let thread = row.thread, row.isThread {
            if openThreads.contains(thread) {
                openThreads.remove(thread)
            } else {
                openThreads.insert(thread)
            }
        }
        setRead(true, in: row)
    }

    private func setRead(_ read: Bool, in row: InboxRow) {
        apply(read: read, to: read ? row.entries.filter(\.isUnread).map(\.id) : row.ids)
    }

    /// Everything the window is *currently showing* — not everything stored.
    /// A filtered list's "mark all read" that quietly cleared the rows a
    /// search had hidden would be the one destructive thing in this window.
    private func markAllRead() {
        apply(read: true, to: rows.flatMap(\.entries).filter(\.isUnread).map(\.id))
    }

    private func apply(read: Bool, to ids: [String]) {
        guard !ids.isEmpty else { return }
        feed.database?.setRead(read, ids: ids)
        // Moved here too, not re-read: the write is async and the dot has to
        // go the moment you click. The database is still the truth — this is
        // the same row, ahead of its own round trip.
        let touched = Set(ids)
        let stamp: Date? = read ? .now : nil
        for index in entries.indices where touched.contains(entries[index].id) {
            entries[index].readAt = stamp
        }
    }

    // MARK: - Chrome

    /// Set on the `NSWindow` by the delegate — the same reason the chrome is
    /// hand-drawn: `.navigationTitle` needs a navigation container to land in.
    static func windowTitle(for scope: InboxScope) -> String {
        switch scope {
        case .all: "Trill"
        case .asks: "Trill — Asks"
        case .digest(let name, _):
            name == DigestCard.defaultName ? "Trill — Digest" : "Trill — \(name)"
        case .since: "Trill — While You Were Away"
        }
    }

    private var searching: Bool { !query.isEmpty || unreadOnly }

    private var emptySymbol: String {
        if feed.database == nil { return "externaldrive.badge.xmark" }
        if searching { return "magnifyingglass" }
        return scope == .all ? "tray" : "tray.full"
    }

    private var emptyTitle: String {
        if feed.database == nil { return "History is off" }
        if searching { return "No matches" }
        switch scope {
        case .all: return "Nothing yet"
        case .asks: return "No asks"
        case .digest: return "Nothing in this digest"
        case .since: return "Nothing came in"
        }
    }

    private var emptyMessage: String {
        // The one emptiness that isn't about this scope at all: nothing is
        // being kept, so nothing can be shown. Saying "try trill send" here
        // would send someone off to prove the window is broken.
        if feed.database == nil {
            return "History is off in Settings, so nothing is being kept to show."
        }
        if searching {
            return unreadOnly && query.isEmpty
                ? "Everything here has been in front of you already."
                : "Nothing in this window matches that."
        }
        switch scope {
        case .all:
            return "Events arrive here as sources send them — try `trill send --title hello`."
        case .asks:
            return "Nothing has asked for you — events sent with `--kind ask` land here, "
                + "including the ones the ledge had to let go of."
        case .digest:
            // History being off is handled above; what's left is a card whose
            // rows were never written (history was off when they arrived) or
            // have since aged out. The count is kept in memory, the list on
            // disk — this is the seam where the two can disagree.
            return "The events behind that card aren't in history — "
                + "either it was off when they arrived, or they've been pruned since."
        case .since:
            return "Nothing has landed since you left — which is what the card would "
                + "have said, if there had been one."
        }
    }
}
