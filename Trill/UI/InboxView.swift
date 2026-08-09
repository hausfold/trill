import SwiftUI

/// The history window: everything the policy engine let through, banner or
/// not. v0 is a plain reverse-chronological list; search, threads, and the
/// keyboard-first pounce hand-off are milestone 2.
struct InboxView: View {
    let database: AppDatabase?
    @State private var items: [AppDatabase.StoredEvent] = []

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "tray",
                    description: Text("Events arrive here as sources send them — try `trill send --title hello`.")
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
        .navigationTitle("Trill")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
        }
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    private func reload() {
        items = database?.recent(limit: 200) ?? []
    }
}
