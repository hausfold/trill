import Combine
import Foundation

/// What an open inbox window watches: which database to read, what changed,
/// and which asks are still hanging on the ledge right now.
///
/// It carries no events. The database is the history and `BannerQueue` is the
/// live truth — this only says *when to look again*, so the window stays a
/// view onto the store rather than a second copy of it (the same reason
/// panels never park event state). One instance, owned by `AppRuntime`, shared
/// by every window it opens.
@MainActor
final class InboxFeed: ObservableObject {
    /// Bumped once per delivered event. The bump happens *after*
    /// `EventRepository.ingest` has enqueued the insert, and reads go through
    /// the same serial queue that write does — so a window reloading on this
    /// signal is guaranteed to see the row, without the feed having to carry
    /// the event itself.
    @Published private(set) var revision: UInt64 = 0

    /// Ids of the asks currently parked on the ledge. This is what lets the
    /// inbox be the ledge's overflow honestly: the sixth ask that evicted the
    /// first is here with a fin beside it, and the first is here *without*
    /// one — the difference between "still waiting on the edge of your
    /// screen" and "gone from it, kept here".
    @Published private(set) var parkedIDs: Set<String> = []

    /// Nil when history is off. Published rather than handed to the window at
    /// open time, because that switch is live: turning history off with the
    /// inbox up has to empty it, not leave it reading a handle nothing writes
    /// to any more.
    @Published var database: AppDatabase?

    init(database: AppDatabase?) {
        self.database = database
    }

    func noteDelivery() {
        revision &+= 1
    }

    func noteParked(_ ids: Set<String>) {
        guard ids != parkedIDs else { return }
        parkedIDs = ids
    }
}
