import Foundation
import os.log

/// Watches the ledge and, for any parked ask that named a resolver, keeps
/// asking that resolver whether the question has answered itself — then takes
/// the fin down when it has.
///
/// It follows the ledge rather than the pipeline on purpose: polling starts
/// when an ask *parks*, because that is the moment the question outlived the
/// person who could answer it. A banner still on screen has someone in front
/// of it, and a resolver racing a user's click would be a fin that vanishes
/// under the cursor.
///
/// Disarming is reconciliation, not bookkeeping: whatever removes a fin —
/// the ✕, a pill, an eviction, `trill resolve`, a relaunch — arrives here as
/// "that id isn't parked any more", and the poller for it stops. There is no
/// second path to keep in step.
@MainActor
final class ResolutionMonitor {
    private let rules: () -> RuleSet
    /// Takes down the fin. Returns whatever the queue cleared; the monitor
    /// doesn't care — resolving something a user already dismissed is a
    /// no-op, and that is the normal ending, not an error.
    private let resolve: (String) -> Void

    private var watches: [String: Task<Void, Never>] = [:]
    /// Asks whose resolver can't be armed at all — an unknown name, a
    /// malformed invocation, a deadline already past. Remembered so a ledge
    /// that re-renders forty times doesn't log the same complaint forty
    /// times, and so a broken resolver costs one message, not a loop.
    private var refused: Set<String> = []

    /// How many checks in a row may *fail* (not "say no" — fail: no such
    /// program, host unreachable) before the poller stops. A resolver that
    /// can't run won't start working on the fourteenth attempt, and a fin
    /// that quietly retries all day is worse than one that stops and stays
    /// on screen for a human.
    static let maxConsecutiveFailures = 5

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "resolver")

    init(rules: @escaping () -> RuleSet, resolve: @escaping (String) -> Void) {
        self.rules = rules
        self.resolve = resolve
    }

    /// The ledge changed. Arm what's new, drop what's gone.
    func reconcile(_ parked: [BannerQueue.Entry]) {
        let live = Set(parked.map(\.id))
        for (id, task) in watches where !live.contains(id) {
            task.cancel()
            watches.removeValue(forKey: id)
        }
        refused.formIntersection(live)

        for entry in parked where entry.event.until != nil {
            guard watches[entry.id] == nil, !refused.contains(entry.id) else { continue }
            arm(entry)
        }
    }

    func stop() {
        watches.values.forEach { $0.cancel() }
        watches.removeAll()
        refused.removeAll()
    }

    // MARK: - Internals

    private func arm(_ entry: BannerQueue.Entry) {
        guard let until = entry.event.until else { return }
        let id = entry.id

        let invocation: ResolverInvocation
        switch ResolverInvocation.parse(until) {
        case .success(let parsed): invocation = parsed
        case .failure(let problem): return refuse(id, problem.message)
        }
        guard let resolver = rules().resolver(named: invocation.name) else {
            // Names the file, because that is where the fix is. A resolver
            // the user hasn't written yet is the single likeliest reason a
            // `--until` does nothing, and it must not be silent.
            return refuse(id, "no resolver named '\(invocation.name)' in rules.json")
        }
        let plan: ResolverPlan
        switch resolver.plan(arguments: invocation.args) {
        case .success(let built): plan = built
        case .failure(let problem):
            return refuse(id, "resolver '\(invocation.name)': \(problem.message)")
        }

        // Measured from when the question was *asked*, not from when this
        // poller armed. Otherwise every relaunch would hand a stale ask
        // another full budget, and a fin parked over a long weekend would
        // still be running commands on Monday.
        let deadline = entry.event.timestamp.addingTimeInterval(resolver.giveUpAfter)
        guard deadline > .now else {
            return refuse(id, "resolver '\(invocation.name)' gave up before it started (past giveUpAfter)")
        }

        let name = invocation.name
        watches[id] = Task { [weak self] in
            await self?.watch(id: id, name: name, plan: plan, every: resolver.every, deadline: deadline)
        }
    }

    private func refuse(_ id: String, _ reason: String) {
        refused.insert(id)
        Self.log.error("resolver not armed for \(id, privacy: .public): \(reason, privacy: .public)")
    }

    private func watch(
        id: String, name: String, plan: ResolverPlan, every: TimeInterval, deadline: Date
    ) async {
        var failures = 0
        // Checked immediately, before the first sleep: an ask that parks
        // right as its PR merges — or one restored from disk hours later —
        // is already answered, and making the user look at it for another
        // two minutes would be the poller adding latency, not removing it.
        while !Task.isCancelled, Date.now < deadline {
            let outcome = await ResolverRunner.check(plan)
            guard !Task.isCancelled else { return }

            switch outcome {
            case .resolved:
                // Removed first: resolving re-enters `reconcile` through the
                // queue's ledge callback, and it should find this watch
                // already gone rather than cancel the task it's running in.
                watches.removeValue(forKey: id)
                Self.log.info("resolver \(name, privacy: .public) answered \(id, privacy: .public)")
                resolve(id)
                return
            case .notYet:
                failures = 0
            case .failed(let reason):
                failures += 1
                Self.log.error("resolver \(name, privacy: .public) failed: \(reason, privacy: .public)")
                if failures >= Self.maxConsecutiveFailures {
                    watches.removeValue(forKey: id)
                    refused.insert(id)
                    Self.log.error("resolver \(name, privacy: .public) stopped after \(failures) failures — the fin stays up")
                    return
                }
            }

            try? await Task.sleep(for: .seconds(every))
        }
        // Out of time. The fin stays: a question whose resolver never said
        // yes is still a question, and clearing it here would be trill
        // deciding an answer it never got.
        watches.removeValue(forKey: id)
        Self.log.info("resolver \(name, privacy: .public) gave up on \(id, privacy: .public) — the fin stays up")
    }
}
