import SwiftUI

/// The history window: everything the policy engine let through, banner or
/// not. v0 is a plain reverse-chronological list; search, threads, and the
/// keyboard-first pounce hand-off are milestone 2.
struct InboxView: View {
    let database: AppDatabase?
    /// Which slice of history this window is for — the plain list, the asks
    /// the ledge parks (`trill inbox --asks`), or the events behind one
    /// digest card. The scope arrives from the click; the query is below.
    var scope: InboxScope = .all
    @State private var items: [AppDatabase.StoredEvent] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: scope == .all ? "tray" : "tray.full",
                    description: Text(emptyMessage)
                )
            } else {
                List(items) { stored in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(stored.event.source)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(stored.event.timestamp, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(stored.event.title)
                            .font(.title3.weight(.medium))
                        if let body = stored.event.body {
                            Text(body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear(perform: reload)
        .navigationTitle(windowTitle)
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
        }
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private var windowTitle: String {
        switch scope {
        case .all: "Trill"
        case .asks: "Trill — Asks"
        case .digest(let name, _):
            name == DigestCard.defaultName ? "Trill — Digest" : "Trill — \(name)"
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .all: "Nothing yet"
        case .asks: "No asks"
        case .digest: "Nothing in this digest"
        }
    }

    private var emptyMessage: String {
        switch scope {
        case .all:
            "Events arrive here as sources send them — try `trill send --title hello`."
        case .asks:
            "Nothing has asked for you — events sent with `--kind ask` land here."
        case .digest:
            // The one honest reason a *counted* digest reads empty: the count
            // is kept in memory, the list is kept on disk, and history is off.
            "The events behind that card weren't kept — history is off in Settings."
        }
    }

    private func reload() {
        switch scope {
        case .all:
            items = database?.recent(limit: 200) ?? []
        case .asks:
            // The database has no answered/unanswered state (answering a
            // banner is not a write), so this is a kind filter, honestly named.
            items = (database?.recent(limit: 200) ?? []).filter { $0.event.kind == .ask }
        case .digest(let name, let since):
            items = database?.digest(named: name, since: since) ?? []
        }
    }
}
