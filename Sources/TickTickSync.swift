import Foundation
import Combine

// MARK: - Read outcome (proposal §5)

/// One bound list's read as pure data. A read that came back with
/// saturation-many rows cannot be proven complete — the endpoint has no
/// truncation marker — so the merge treats it like a partially known list
/// instead of trusting the row set (proposal §5.1).
struct TickTickListRead: Equatable {
    /// The id the read was addressed by: "inbox" for the inbox alias, a real
    /// project id otherwise.
    let projectId: String
    let tasks: [TickTickTask]
    /// True when the row count reached the endpoint's saturation ceiling.
    let possiblyTruncated: Bool
}

/// One round's raw reads, filled in by the engine and consumed by the pure
/// merge. Lists that failed to read are named, not emptied: a missing read is
/// never an empty list (proposal §5.1).
struct TickTickReadOutcome: Equatable {
    var lists: [TickTickListRead]
    var failedProjectIds: Set<String>
    /// nil when the completed query did not run or failed this round — never
    /// a stand-in for "no completions".
    var completedTasks: [TickTickTask]?
    /// True only when the completed window query ran and every window it
    /// produced was proven complete (below the saturation cap).
    var completedWindowComplete: Bool
}

// MARK: - Merge (proposal §5)

/// Combines one round's reads with the previous population. Pure — no IO, no
/// clock beyond the injected `now` — so the integrity rules are testable
/// without a transport: unread lists keep their tasks, saturation blocks
/// absence evidence, missing tasks are queued for confirmation rather than
/// deleted, and pending writes are never flipped by stale data.
enum TickTickMerge {

    /// A known task this round cannot account for: keep the row, confirm it
    /// with a single-task read-back (proposal §5.3).
    struct Missing: Equatable {
        let taskId: String
        let projectId: String
    }

    struct Outcome: Equatable {
        var tasks: [TickTickTask]
        var listsIncomplete: Bool
        var completedIncomplete: Bool
        var confirmedPending: [TickTickTaskCache.PendingOperation]
        var missing: [Missing]
        var seenTaskIDs: Set<String>
    }

    static func merge(previousTasks: [TickTickTask],
                      pending: [TickTickTaskCache.PendingOperation],
                      outcome: TickTickReadOutcome,
                      now: Date = Date(),
                      recentWindow: TimeInterval = 24 * 3600) -> Outcome {
        var tasks = previousTasks
        let pendingByTask = Dictionary(pending.map { ($0.taskId, $0) },
                                       uniquingKeysWith: { first, _ in first })
        var confirmed: [TickTickTaskCache.PendingOperation] = []
        var seen = Set<String>()

        // 1. The completed window (proposal §5.2) is authoritative for
        //    completions. A window hit confirms a pending completion; for a
        //    pending restore it proves nothing — completedTime survives an
        //    un-complete with its stale value (contract report §四.1), so only
        //    status counts.
        if let completed = outcome.completedTasks {
            for task in completed {
                seen.insert(task.id)
                if let operation = pendingByTask[task.id] {
                    if operation.targetStatus == 2 && task.status == 2 {
                        confirmed.append(operation)
                        upsert(&tasks, task)
                    }
                } else {
                    upsert(&tasks, task)
                }
            }
        }

        // 2. Undone list reads (proposal §5.1): each list read completely
        //    replaces the tasks it contains. A task absent from its list's
        //    read is NOT dropped here — absence only queues it for
        //    confirmation, never deletion (proposal §5.3).
        for read in outcome.lists {
            for task in read.tasks {
                seen.insert(task.id)
                if let operation = pendingByTask[task.id] {
                    // The undone list confirms a restore (the task reappears
                    // undone); a pending completion ignores the list — a row
                    // there is a stale read, not evidence (proposal §6.2).
                    if operation.targetStatus == 0 && task.status == 0 {
                        confirmed.append(operation)
                        upsert(&tasks, task)
                    }
                } else {
                    upsert(&tasks, task)
                }
            }
        }

        // 3. Missing candidates (proposal §5.3): undone tasks absent from
        //    their list's complete read, and recent completions absent from
        //    a complete completed window. Pending writes are confirmed by
        //    their own channel and never enter the queue.
        let windowRanAndComplete = outcome.completedTasks != nil && outcome.completedWindowComplete
        var missing: [Missing] = []
        for task in tasks where pendingByTask[task.id] == nil && !seen.contains(task.id) {
            guard let owner = outcome.lists.first(where: {
                TickTickTaskListLayout.bindingKey(forTaskProjectId: task.projectId,
                                                  boundProjectIds: [$0.projectId]) != nil
            }), !owner.possiblyTruncated else { continue }
            if task.status == 2 {
                // A completion outside the window is absent by design, not
                // missing; only a complete window that omits a recent
                // completion needs explaining.
                guard windowRanAndComplete, let completedAt = task.completedTime,
                      now.timeIntervalSince(completedAt) <= recentWindow else { continue }
            }
            missing.append(Missing(taskId: task.id, projectId: task.projectId))
        }

        // 4. Window expiry (proposal §5.2): completions older than the window
        //    leave the display cache — only that. A trusted completedTime, a
        //    complete window this round, and no pending write are all
        //    required; expiry never touches the server.
        if windowRanAndComplete {
            tasks.removeAll { task in
                guard task.status == 2, pendingByTask[task.id] == nil,
                      let completedAt = task.completedTime else { return false }
                return now.timeIntervalSince(completedAt) > recentWindow
            }
        }

        // Deterministic order keeps the encrypted snapshot byte-stable.
        tasks.sort { $0.id < $1.id }

        return Outcome(tasks: tasks,
                       listsIncomplete: !outcome.failedProjectIds.isEmpty
                           || outcome.lists.contains { $0.possiblyTruncated },
                       completedIncomplete: outcome.completedTasks != nil
                           && !outcome.completedWindowComplete,
                       confirmedPending: confirmed,
                       missing: missing,
                       seenTaskIDs: seen)
    }

    private static func upsert(_ tasks: inout [TickTickTask], _ task: TickTickTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        else { tasks.append(task) }
    }
}

// MARK: - Completed-window splitting (proposal §5.2)

/// What to do with a completed-window query that came back saturated. The
/// endpoints cap at 200 rows; a saturated window is split at its time
/// midpoint until the budget or the one-second floor stops the descent.
enum TickTickCompletedSplitter {
    static let saturationCount = 200
    /// History completion requests one round may spend (proposal §5.2).
    static let maxRequestsPerRound = 8
    /// The smallest window worth querying; below this a saturated window
    /// keeps its incomplete mark instead of splitting forever.
    static let minimumWindow: TimeInterval = 1

    struct Window: Equatable {
        let start: Date
        let end: Date
    }

    enum Verdict: Equatable {
        /// Below the cap — the window is proven complete.
        case accepted
        /// Saturated and wide enough — query both halves.
        case split(Window, Window)
        /// Saturated at or below the floor — keep the incomplete mark.
        case saturatedAtMinimum
    }

    static func verdict(count: Int, for window: Window) -> Verdict {
        guard count >= saturationCount else { return .accepted }
        guard window.end.timeIntervalSince(window.start) > minimumWindow else {
            return .saturatedAtMinimum
        }
        let (first, second) = halves(of: window)
        return .split(first, second)
    }

    /// The midpoint split. Both halves keep the boundary inclusive, which is
    /// exactly why callers dedupe by taskId.
    static func halves(of window: Window) -> (Window, Window) {
        let midpoint = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
        return (Window(start: window.start, end: midpoint),
                Window(start: midpoint, end: window.end))
    }

    /// Collapses overlapping windows' boundary duplicates by taskId, keeping
    /// the freshest observation (modifiedTime, then first seen).
    static func dedupe(_ tasks: [TickTickTask]) -> [TickTickTask] {
        var byID: [String: TickTickTask] = [:]
        var order: [String] = []
        for task in tasks {
            if byID[task.id] == nil { order.append(task.id) }
            if let existing = byID[task.id], existing.modifiedTime > task.modifiedTime { continue }
            byID[task.id] = task
        }
        return order.compactMap { byID[$0] }
    }
}

// MARK: - Backoff (proposal §7.1)

/// Retry pacing for retryable failures: 15→30→60→120→300 s with a little
/// jitter, a server-provided Retry-After ahead of everything (even beyond
/// 300 s — the server's word outranks the ladder).
enum TickTickBackoff {
    static let ladder: [TimeInterval] = [15, 30, 60, 120, 300]

    /// `failures` counts consecutive retryable rounds, starting at 1.
    static func delay(failures: Int,
                      retryAfter: TimeInterval? = nil,
                      jitter: () -> Double = { Double.random(in: 0...0.1) }) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return max(retryAfter, 0) }
        let index = min(max(failures, 1), ladder.count) - 1
        return ladder[index] * (1 + max(0, jitter()))
    }
}

// MARK: - Write policy (proposal §6)

/// The write path's decision rules, pure so every failure mode is
/// regression-tested without a transport.
enum TickTickWritePolicy {
    /// What a failed send means (proposal §6.2).
    enum SendFailure: Equatable {
        /// Timeout, connection loss, 5xx, throttling — the outcome is
        /// unknowable: keep the pending, keep reading back, never re-send.
        case uncertain
        /// A definitive refusal: clear the pending, keep the last trusted
        /// state, let later reads correct the display.
        case rejected
        /// 401 — pause the engine until credentials change.
        case unauthorized
    }

    static func classifySendFailure(_ error: TickTickError) -> SendFailure {
        switch error {
        case .timedOut, .network, .server, .rateLimited: return .uncertain
        case .unauthorized: return .unauthorized
        case .forbidden, .notFound, .invalidResponse, .httpStatus: return .rejected
        }
    }

    /// Only an authoritative read-back showing the target status confirms a
    /// write — HTTP success is not confirmation (proposal §6.2).
    static func confirms(pending: TickTickTaskCache.PendingOperation, readBackStatus: Int) -> Bool {
        readBackStatus == pending.targetStatus
    }

    /// The active confirmation window (proposal §6.2): 30 seconds of retries,
    /// then "结果待确认" and passive confirmation by later rounds.
    static let activeConfirmationWindow: TimeInterval = 30

    /// Read-back retry pacing inside the active window, in seconds.
    static let confirmRetryDelays: [TimeInterval] = [2, 5, 10, 15]

    /// Whether a new write may start (proposal §6.1/§6.2): writes disabled by
    /// the connection, one pending per task, NOTE-kind tasks carry no
    /// completion semantics and repeated tasks stay read-only until the
    /// next-instance behaviour is verified (proposal §5.4), and a task
    /// already in the target state needs no request.
    static func mayStartWrite(taskId: String,
                              targetStatus: Int,
                              existingTask: TickTickTask?,
                              hasPending: Bool,
                              writesForbidden: Bool) -> Bool {
        guard !writesForbidden, !hasPending, let task = existingTask else { return false }
        guard task.kind != "NOTE" else { return false }
        guard task.repeatFlag != true else { return false }
        return task.status != targetStatus
    }
}

// MARK: - Missing-task evidence (proposal §5.3)

/// Absence evidence per task. Removal from display needs two *independent*
/// confirmations — two 404 read-backs, or two read-backs of an unchanged,
/// still-undone task (a soft-deleted task's read-back keeps answering 200
/// with a modifiedTime frozen at the deletion stamp, contract report §四.2).
/// 403, 401, timeouts and 5xx never count: they are not evidence.
struct TickTickMissingTracker: Equatable {
    static let removalThreshold = 2

    private(set) var notFoundCounts: [String: Int] = [:]
    private(set) var absenceCounts: [String: Int] = [:]
    private(set) var lastReadBackModified: [String: Date] = [:]

    /// The task was observed in some read this round: absence evidence resets.
    mutating func seen(_ taskId: String) {
        notFoundCounts[taskId] = nil
        absenceCounts[taskId] = nil
    }

    /// A read-back of a missing task answered 200. Absence counts only when
    /// the task shows no fresh modification since it was last observed.
    mutating func readBack(taskId: String, observed: TickTickTask,
                           lastObservedModified: Date?) {
        notFoundCounts[taskId] = nil
        if let last = lastObservedModified, observed.modifiedTime > last {
            absenceCounts[taskId] = nil       // something is still editing it
        } else {
            absenceCounts[taskId, default: 0] += 1
        }
        lastReadBackModified[taskId] = observed.modifiedTime
    }

    /// A read-back answered 404. Never evidence of deletion by itself
    /// (proposal §5.3.5) — two independent 404s remove the task from display
    /// as inaccessible.
    mutating func notFound(_ taskId: String) {
        notFoundCounts[taskId, default: 0] += 1
    }

    /// Task ids whose absence has been confirmed often enough to leave the
    /// display — described as inaccessible, never as deleted.
    func removalTaskIDs() -> Set<String> {
        let byNotFound = notFoundCounts.filter { $0.value >= Self.removalThreshold }.keys
        let byAbsence = absenceCounts.filter { $0.value >= Self.removalThreshold }.keys
        return Set(byNotFound).union(byAbsence)
    }

    mutating func forget(_ taskIds: Set<String>) {
        for id in taskIds {
            notFoundCounts[id] = nil
            absenceCounts[id] = nil
            lastReadBackModified[id] = nil
        }
    }
}

// MARK: - Identity hashing

/// A stable 32-bit FNV-1a hash. The account epoch must survive restarts —
/// a random per-process hash would invalidate every restarted pending — and
/// must derive from non-secret account data (the project id inventory), so
/// no token material ever reaches the cache (proposal §7.2).
enum TickTickIdentityHash {
    static func fnv1a32(_ string: String) -> Int {
        var hash: UInt32 = 0x811c9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return Int(hash)
    }
}

// MARK: - Scheduling seam (proposal §7.1)

/// One-shot timers the engine reschedules every round. Behind a protocol so
/// tests drive time by hand; firings must land on the main thread so the
/// engine can capture the note snapshot where it lives.
protocol TickTickScheduling: AnyObject {
    /// Schedules a future firing under `id`; a later schedule with the same
    /// id replaces the earlier one.
    func schedule(id: String, interval: TimeInterval, _ fire: @escaping () -> Void)
    func cancel(id: String)
    /// Drops every scheduled firing — sleep, disconnect, auth pause.
    func cancelAll()
}

/// The production scheduler: main-queue timers, one per id.
final class TickTickMainScheduler: TickTickScheduling {
    private let main: (@escaping () -> Void) -> Void
    private var timers: [String: Timer] = [:]

    init(main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.main = main
    }

    func schedule(id: String, interval: TimeInterval, _ fire: @escaping () -> Void) {
        main { [weak self] in
            guard let self else { return }
            self.timers[id]?.invalidate()
            self.timers[id] = Timer.scheduledTimer(withTimeInterval: max(interval, 0.05),
                                                   repeats: false) { _ in fire() }
        }
    }

    func cancel(id: String) {
        main { [weak self] in
            self?.timers[id]?.invalidate()
            self?.timers[id] = nil
        }
    }

    func cancelAll() {
        main { [weak self] in
            self?.timers.values.forEach { $0.invalidate() }
            self?.timers.removeAll()
        }
    }
}

// MARK: - Engine (proposal §3, §5–§7)

/// The sync engine: one serial execution domain (this actor), a generation
/// that invalidates every in-flight response the moment account, bindings or
/// credentials change (proposal §6.3), reads that refuse to read failure as
/// emptiness (§5), a write state machine that persists before sending and
/// confirms before trusting (§6), and the §7.1 schedule. UI and NoteStore
/// mutations leave the actor through `main`; the note snapshot enters it only
/// from the main thread.
actor TickTickSyncEngine: TickTickEngine {

    // MARK: Cadence (proposal §7.1)

    static let undoneIntervalVisible: TimeInterval = 15
    static let undoneIntervalHidden: TimeInterval = 60
    static let completedQueryInterval: TimeInterval = 60
    static let recentWindow: TimeInterval = 24 * 3600
    static let roundTimerID = "ticktick.round"
    static let confirmTimerPrefix = "ticktick.confirm."

    // MARK: Dependencies

    private let keychain: TickTickKeychain
    private let bindingsStore: TickTickBindingsStore
    private let cache: TickTickTaskCache
    private let portal: TickTickPortal
    private let noteStore: NoteStore
    /// Read on the main thread only — the engine never observes NoteStore
    /// from its own domain.
    private let noteReader: @Sendable () -> [Note]
    private let makeClient: (String) -> TickTickClient
    private let scheduler: TickTickScheduling
    private let main: (@escaping () -> Void) -> Void
    private let now: () -> Date

    // MARK: Live state

    /// The task population — the source of every note's derived snapshot.
    private var tasks: [TickTickTask] = []
    private var inaccessible: [TickTickTaskCache.InaccessibleTask] = []
    /// Pending writes by taskId: one per task, shared by every note that
    /// shows the task (proposal §4.2).
    private var pendingWrites: [String: PendingWrite] = [:]
    private var loadedCache = false
    private var currentBindings: [TickTickBinding] = []

    // MARK: Connection identity

    /// The account's project-id inventory — non-secret, stable, and the
    /// restart-stable basis of the epoch.
    private var accountKey: String?
    /// Set when credentials change: the next round re-reads the account
    /// inventory so a token for a *different* account is detected and the
    /// old cache quarantined, while the same account keeps its pendings
    /// valid (proposal §4.2, §7.2).
    private var needsAccountRefresh = true
    private var projectNames: [String: String] = [:]
    /// The epoch pendings are stamped with: deterministic from the account,
    /// so a restart with the same account still confirms them, and a
    /// different account never does (proposal §4.2).
    private var epoch = 0
    /// Bumped by any account/binding/credential change; in-flight rounds
    /// capture it and are dropped if it moved (proposal §6.3).
    private var generation = 1
    private var lastToken: String?
    private var lastBindingsSignature: String?
    /// Binding note ids a previous round resolved — the difference between a
    /// lifecycle event (the note was deleted after its undo window, §8.4:
    /// prune the binding) and corruption (the binding never pointed anywhere,
    /// §4.2: configuration error).
    private var knownBindingNoteIDs: Set<String> = []
    private var cachedClient: (token: String, client: TickTickClient)?

    // MARK: Round bookkeeping

    private struct RoundDiagnostics: Equatable {
        var retryableFailure = false
        var authFailed = false
        var permissionFailed = false
        var retryAfter: TimeInterval?
        var anyListRead = false
    }
    private var diagnostics = RoundDiagnostics()
    private var roundInFlight = false
    private var followUpRoundNeeded = false
    private var carryWindows: [TickTickCompletedSplitter.Window] = []
    private var lastCompletedQuery: Date?
    private var consecutiveFailures = 0
    private var tracker = TickTickMissingTracker()

    // MARK: Connection gates

    private var visibleTaskViews = 0
    private var pausedForAuth = false
    private var writesForbidden = false

    /// One pending write's live state (proposal §6.2). The observable state
    /// machine runs: `idle` (no entry — the row shows the confirmed state and
    /// is operable), `sending` (persisted, request in flight — 正在确认, the
    /// row disabled), `awaitingConfirmation` (HTTP answered, the authoritative
    /// read still pending), `uncertain` (结果待确认 — timeout, transport loss
    /// or the 30 s window closing; the pending stays and rounds keep reading
    /// back, never re-sending), and the terminal `confirmed`/`rejected` (the
    /// entry leaves — `confirmed` converges the snapshot, `rejected` keeps
    /// the last trusted state and reports through the connection phase).
    private struct PendingWrite {
        let operation: TickTickTaskCache.PendingOperation
        enum Phase: Equatable {
            case sending
            case awaitingConfirmation
            case uncertain
        }
        var phase: Phase
        var attempts: Int
        var nextConfirmAt: Date
    }

    // MARK: Init

    init(keychain: TickTickKeychain = .standard,
         bindingsStore: TickTickBindingsStore = TickTickBindingsStore(),
         cache: TickTickTaskCache = TickTickTaskCache(),
         portal: TickTickPortal = .shared,
         noteStore: NoteStore = .shared,
         noteReader: (@Sendable () -> [Note])? = nil,
         makeClient: ((String) -> TickTickClient)? = nil,
         scheduler: TickTickScheduling = TickTickMainScheduler(),
         main: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         now: (() -> Date)? = nil) {
        self.keychain = keychain
        self.bindingsStore = bindingsStore
        self.cache = cache
        self.portal = portal
        self.noteStore = noteStore
        // The snapshot always includes a note sitting in its ten-second undo
        // window (proposal §8.4): during the window the binding stays valid,
        // the engine keeps confirming that note's pendings, and no body
        // update can resurrect the deleted row — NoteStore refuses writes to
        // missing notes.
        self.noteReader = noteReader ?? { [noteStore] in
            noteStore.notes + (noteStore.pendingUndo.map { [$0.note] } ?? [])
        }
        self.makeClient = makeClient ?? { token in TickTickClient(token: token) }
        self.scheduler = scheduler
        self.main = main
        self.now = now ?? { Date() }
    }

    // MARK: Engine entry points (main thread)

    /// 启动 (proposal §7.1): one merged immediate read. No token means no
    /// requests at all — the round itself decides and stops.
    nonisolated func start() { requestRound() }

    nonisolated func applicationDidActivate() { requestRound() }

    nonisolated func applicationDidWake() {
        Task { await self.handleWake() }
    }

    nonisolated func systemWillSleep() {
        Task { await self.handleSleep() }
    }

    nonisolated func refreshRequested() { requestRound() }

    nonisolated func completeTask(taskId: String, noteID: String) {
        Task { await self.requestWrite(taskId: taskId, noteID: noteID, targetStatus: 2) }
    }

    /// The verified restore path (contract report §2.2): the same full state
    /// machine as completion — pending persisted first, POST /task/{taskId}
    /// with {id, projectId, status: 0}, then read-back confirmation.
    nonisolated func uncompleteTask(taskId: String, noteID: String) {
        Task { await self.requestWrite(taskId: taskId, noteID: noteID, targetStatus: 0) }
    }

    /// 展开便签 (proposal §7.1): the visible cadence applies, and one merged
    /// read fires because the person is looking right now.
    nonisolated func noteTaskViewDidAppear() {
        Task { await self.taskViewAppeared() }
    }

    nonisolated func noteTaskViewDidDisappear() {
        Task { await self.taskViewDisappeared() }
    }

    /// Credentials or the connection changed (settings connect/disconnect).
    /// Bumps the generation and re-evaluates everything (proposal §7.2).
    nonisolated func credentialsDidChange() {
        Task { await self.credentialsChanged() }
    }

    /// Every round starts here, on the caller's (main) thread, so the note
    /// snapshot is captured where NoteStore lives — never read from the actor.
    private nonisolated func requestRound() {
        let notes = noteReader()
        Task { await self.beginRound(notes: notes) }
    }

    // MARK: Lifecycle

    private func handleWake() {
        requestRound()   // merged with anything still in flight
    }

    private func handleSleep() {
        // Cancelling a request does not cancel a server write: in-flight
        // rounds keep their unknown-result handling, scheduling stops.
        scheduler.cancelAll()
    }

    private func taskViewAppeared() {
        visibleTaskViews += 1
        if visibleTaskViews == 1 {
            // Merged immediate read through the scheduler so the note
            // snapshot is still captured on the main thread.
            scheduleRound(after: 0.05)
        }
    }

    private func taskViewDisappeared() {
        visibleTaskViews = max(0, visibleTaskViews - 1)
    }

    private func credentialsChanged() {
        let token = (try? keychain.load()) ?? nil
        if token != lastToken { generation += 1 }
        pausedForAuth = false       // the 401 pause ends with fresh credentials
        // Re-verify which account the new credentials belong to before any
        // pending is trusted again (proposal §7.2).
        needsAccountRefresh = true
        if let token, !token.isEmpty {
            writesForbidden = false
            scheduleRound(after: 0.05)
        } else {
            // Disconnected: stop scheduled reads entirely (proposal §7.1).
            writesForbidden = false
            scheduler.cancelAll()
            publishPhase(.idle)
        }
    }

    private func scheduleRound(after interval: TimeInterval) {
        guard !pausedForAuth else { return }
        scheduler.schedule(id: Self.roundTimerID, interval: interval) { [weak self] in
            self?.requestRound()    // nonisolated: fires on the main thread
        }
    }

    private func stopScheduling() {
        scheduler.cancelAll()
    }

    // MARK: The round (proposal §5, §7.1)

    private func beginRound(notes: [Note]) async {
        guard !roundInFlight else {
            // Manual refresh, timers and activation events merge: one round
            // in flight, one follow-up remembered (proposal §6.3).
            followUpRoundNeeded = true
            return
        }
        roundInFlight = true
        defer { roundInFlight = false }

        // Connection re-evaluation first — the generation the round captures
        // must already include any change detected here.
        let token = (try? keychain.load()) ?? nil
        if token != lastToken {
            if lastToken != nil { generation += 1 }
            // A different token may belong to a different account: the
            // inventory re-read decides (proposal §7.2).
            needsAccountRefresh = true
            lastToken = token
        }
        guard !pausedForAuth else { return }

        guard let token, !token.isEmpty else {
            // Not connected: no request leaves the app (proposal §7.2), and
            // nothing is scheduled.
            publishPhase(.idle)
            stopScheduling()
            return
        }

        var bindingsState = bindingsStore.load(notes: notes)
        // A binding whose note was deleted after its undo window is a
        // lifecycle event, not corruption (proposal §8.4): deleting a task
        // note only removes the local display, so the binding leaves with
        // it. Bindings that never resolved stay a configuration error (§4.2).
        while case .invalid(.noteNotFound(let danglingID)) = bindingsState,
              knownBindingNoteIDs.contains(danglingID),
              bindingsStore.pruneBinding(noteID: danglingID) {
            bindingsState = bindingsStore.load(notes: notes)
        }
        let bindings: [TickTickBinding]
        switch bindingsState {
        case .absent:
            // No task notes exist: stop scheduled reads (proposal §7.1).
            publishPhase(.idle)
            stopScheduling()
            return
        case .invalid:
            // A broken configuration is a state to show, never "no
            // bindings" (proposal §4.2).
            publishPhase(.misconfigured)
            stopScheduling()
            return
        case .loaded(let loaded) where loaded.isEmpty:
            // Every task note was deleted: nothing left to read (§7.1).
            knownBindingNoteIDs = []
            publishPhase(.idle)
            stopScheduling()
            return
        case .loaded(let loaded):
            bindings = loaded
        }
        knownBindingNoteIDs = Set(bindings.map(\.noteId))
        let signature = Self.bindingsSignature(bindings)
        if signature != lastBindingsSignature {
            if lastBindingsSignature != nil { generation += 1 }
            lastBindingsSignature = signature
        }
        currentBindings = bindings

        let roundGeneration = generation
        let roundNow = now()
        diagnostics = RoundDiagnostics()
        publishPhase(.refreshing)

        // The cache loads once per engine; a cache that exists but cannot be
        // decrypted or parsed is a configuration error, never empty (§4.2).
        if !loadedCache {
            do {
                if let snapshot = try cache.load() {
                    tasks = snapshot.tasks
                    inaccessible = snapshot.inaccessible ?? []
                    // Restarted pendings are read back, never re-sent
                    // (proposal §4.2): they start uncertain, due now.
                    pendingWrites = Dictionary(
                        snapshot.pending.sorted { $0.sentAt > $1.sentAt }
                            .map { ($0.taskId, PendingWrite(operation: $0, phase: .uncertain,
                                                            attempts: 0, nextConfirmAt: roundNow)) },
                        uniquingKeysWith: { first, _ in first })
                }
            } catch {
                publishPhase(.misconfigured)
                stopScheduling()
                return
            }
            loadedCache = true
        }

        // Requests go out per deduped list, not per note (proposal §5.1).
        var orderedProjects: [String] = []
        var seenProjects = Set<String>()
        for binding in bindings {
            for projectId in binding.projectIds where seenProjects.insert(projectId).inserted {
                orderedProjects.append(projectId)
            }
        }

        // The account inventory (names + epoch) is fetched once per
        // connection — and again after a credential change, so an account
        // switch is detected: it identifies the account and names the groups.
        if needsAccountRefresh {
            do {
                let projects = try await client(token).listProjects()
                let key = projects.map(\.id).sorted().joined(separator: ",")
                if key != accountKey {
                    if accountKey != nil {
                        // Account switch: the old account's tasks, pendings
                        // and history are quarantined (proposal §4.2).
                        tasks = []
                        pendingWrites = [:]
                        inaccessible = []
                        tracker = TickTickMissingTracker()
                        carryWindows = []
                    }
                    accountKey = key
                    epoch = TickTickIdentityHash.fnv1a32(key)
                    projectNames = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
                    let names = projectNames
                    let portal = self.portal
                    main { portal.setProjectNames(names) }
                }
                needsAccountRefresh = false
            } catch let error as TickTickError {
                absorb(error)
                // Names are optional: the round continues without them.
            } catch {}
        }

        // Undone reads, one list at a time, in order (proposal §6.3).
        var lists: [TickTickListRead] = []
        var failedProjectIds = Set<String>()
        for projectId in orderedProjects {
            do {
                let data = try await client(token).projectData(projectId: projectId)
                lists.append(TickTickListRead(
                    projectId: projectId,
                    tasks: data.tasks,
                    possiblyTruncated: data.tasks.count >= TickTickCompletedSplitter.saturationCount))
                diagnostics.anyListRead = true
            } catch let error as TickTickError {
                absorb(error)
                // A failed read is not an empty list (proposal §5.1): the
                // list is named as failed and its tasks keep their state.
                failedProjectIds.insert(projectId)
            } catch {
                failedProjectIds.insert(projectId)
                diagnostics.retryableFailure = true
            }
        }

        // Recent completions, on their own cadence (proposal §5.2/§7.1).
        var completedTasks: [TickTickTask]?
        var completedWindowComplete = false
        if let last = lastCompletedQuery,
           roundNow.timeIntervalSince(last) < Self.completedQueryInterval {
            // Not due yet this round.
        } else {
            lastCompletedQuery = roundNow
            let queryResult = await queryCompletedWindows(projectIds: orderedProjects, now: roundNow)
            completedTasks = queryResult.tasks
            completedWindowComplete = queryResult.complete
            if !queryResult.complete { diagnostics.retryableFailure = true }
        }

        // Merge the round (pure) and apply it — unless the world moved on.
        let outcome = TickTickReadOutcome(lists: lists,
                                          failedProjectIds: failedProjectIds,
                                          completedTasks: completedTasks,
                                          completedWindowComplete: completedWindowComplete)
        let merged = TickTickMerge.merge(previousTasks: tasks,
                                         pending: pendingWrites.values.map(\.operation),
                                         outcome: outcome,
                                         now: roundNow,
                                         recentWindow: Self.recentWindow)
        guard generation == roundGeneration else {
            // An account, binding or credential changed while this round was
            // in flight: every response in it is void (proposal §6.3) — the
            // merge is discarded and nothing below runs. A trigger that
            // arrived mid-round still gets its merged follow-up round.
            if followUpRoundNeeded {
                followUpRoundNeeded = false
                scheduleRound(after: 0.05)
            }
            return
        }

        tasks = merged.tasks
        currentBindings = bindings
        for taskId in merged.seenTaskIDs { tracker.seen(taskId) }
        for operation in merged.confirmedPending {
            pendingWrites[operation.taskId] = nil
            tracker.forget([operation.taskId])
        }
        // A task that came back is no longer described as inaccessible.
        inaccessible.removeAll { merged.seenTaskIDs.contains($0.taskId) }

        // Pending-write confirmations first, then up to four missing-task
        // read-backs (proposal §5.3: 未确认写操作优先). Read-backs carry the
        // round's generation: a response that lands after another change is
        // void too (proposal §6.3).
        for taskId in pendingWrites.keys.sorted() {
            let due = pendingWrites[taskId]?.nextConfirmAt ?? roundNow
            if due <= roundNow { await confirmWrite(taskId: taskId, roundGeneration: roundGeneration) }
        }
        for missing in merged.missing.prefix(Self.missingReadBackBudget) {
            await resolveMissing(missing, roundGeneration: roundGeneration)
        }

        // Absence confirmed twice: leave the display as inaccessible — never
        // claimed deleted, never removed on the server (proposal §5.3.5).
        let removals = tracker.removalTaskIDs()
        for taskId in removals.sorted() {
            guard let task = tasks.first(where: { $0.id == taskId }) else { continue }
            tasks.removeAll { $0.id == taskId }
            if !inaccessible.contains(where: { $0.taskId == taskId }) {
                inaccessible.append(TickTickTaskCache.InaccessibleTask(taskId: taskId,
                                                                       projectId: task.projectId,
                                                                       title: task.title))
            }
        }
        tracker.forget(removals)

        persistAndPublish(now: roundNow)

        // Phase (proposal §7.3) — the honest summary of what just happened.
        if diagnostics.authFailed {
            // 401 pauses everything until credentials change (proposal §7.1).
            pausedForAuth = true
            publishPhase(.unauthorized)
            scheduler.cancelAll()
            return
        }
        if diagnostics.permissionFailed {
            writesForbidden = true          // 403 stops the related writes
            publishPhase(.forbidden)
        } else if diagnostics.retryableFailure {
            consecutiveFailures += 1
            publishPhase(diagnostics.anyListRead || completedTasks != nil ? .incomplete : .offline)
        } else {
            consecutiveFailures = 0
            publishPhase(merged.listsIncomplete || merged.completedIncomplete
                         ? .incomplete : .updated(roundNow))
        }

        if followUpRoundNeeded {
            // Events that arrived mid-round get one merged follow-up.
            followUpRoundNeeded = false
            scheduleRound(after: 0.05)
            return
        }
        let interval: TimeInterval
        if diagnostics.retryableFailure {
            interval = TickTickBackoff.delay(failures: consecutiveFailures,
                                             retryAfter: diagnostics.retryAfter)
        } else {
            interval = visibleTaskViews > 0 ? Self.undoneIntervalVisible : Self.undoneIntervalHidden
        }
        scheduleRound(after: interval)
    }

    /// How many missing-task read-backs one round may spend (proposal §5.3).
    static let missingReadBackBudget = 4

    /// Queries the recent-completion windows, splitting saturated ones within
    /// the round's request budget (proposal §5.2). Returns the deduped task
    /// set and whether every window was proven complete.
    private func queryCompletedWindows(projectIds: [String], now roundNow: Date) async
        -> (tasks: [TickTickTask], complete: Bool) {
        let splitter = TickTickCompletedSplitter.self
        let base = TickTickCompletedSplitter.Window(start: roundNow.addingTimeInterval(-Self.recentWindow),
                                                    end: roundNow)
        var queue: [TickTickCompletedSplitter.Window] = carryWindows
        var results: [TickTickTask] = []
        var complete = true
        var nextCarry: [TickTickCompletedSplitter.Window] = []
        var budget = splitter.maxRequestsPerRound

        func query(_ window: TickTickCompletedSplitter.Window) async -> Int? {
            let token = lastToken ?? ""
            do {
                let page = try await client(token).completedTasks(projectIds: projectIds,
                                                                  from: window.start, to: window.end)
                results += page
                return page.count
            } catch let error as TickTickError {
                absorb(error)
                return nil            // the window is simply unknown now
            } catch { return nil }
        }

        // The fresh window always runs first; carried windows follow.
        if let count = await query(base) {
            switch splitter.verdict(count: count, for: base) {
            case .accepted: break
            case .split(let first, let second): queue += [first, second]
            case .saturatedAtMinimum: complete = false
            }
        } else {
            complete = false
        }
        while budget > 1, let window = queue.first {
            queue.removeFirst()
            budget -= 1
            if let count = await query(window) {
                switch splitter.verdict(count: count, for: window) {
                case .accepted: break
                case .split(let first, let second): queue += [first, second]
                case .saturatedAtMinimum: complete = false
                }
            } else {
                complete = false
                nextCarry.append(window)   // retried on a later round
            }
        }
        // Budget exhausted or windows left unproven: keep the incomplete
        // mark and carry the remainder — never split forever (§5.2).
        if !queue.isEmpty {
            complete = false
            nextCarry += queue
        }
        carryWindows = nextCarry.filter { carry in
            // The fresh base window is re-queried whole next round; only
            // split sub-windows are worth carrying.
            carry.start != base.start || carry.end != base.end
        }
        return (splitter.dedupe(results), complete)
    }

    /// Feeds a request failure into the round's diagnostics.
    private func absorb(_ error: TickTickError) {
        switch error {
        case .unauthorized: diagnostics.authFailed = true
        case .forbidden: diagnostics.permissionFailed = true
        case .rateLimited(let retryAfter):
            diagnostics.retryableFailure = true
            if let retryAfter, retryAfter > (diagnostics.retryAfter ?? 0) {
                diagnostics.retryAfter = retryAfter
            }
        case .network, .timedOut, .server, .invalidResponse:
            diagnostics.retryableFailure = true
        case .notFound, .httpStatus:
            break    // a definitive answer, not a transport problem
        }
    }

    // MARK: Missing-task confirmation (proposal §5.3)

    private func resolveMissing(_ missing: TickTickMerge.Missing, roundGeneration: Int) async {
        guard let token = lastToken else { return }
        do {
            let task = try await client(token).task(projectId: missing.projectId,
                                                    taskId: missing.taskId)
            // A response that outlived its round is void (proposal §6.3).
            guard generation == roundGeneration,
                  pendingWrites[missing.taskId] == nil else { return }
            let previouslyObserved = tasks.first { $0.id == missing.taskId }?.modifiedTime
            tracker.readBack(taskId: missing.taskId, observed: task,
                             lastObservedModified: previouslyObserved)
            switch task.status {
            case -1:
                // status=-1: out of the action list (proposal §5.3.3).
                tasks.removeAll { $0.id == missing.taskId }
            default:
                // A read-back that names an unbound project means the task
                // left every bound list: out of the display (proposal §5.3.4).
                let bound = currentBindings.flatMap(\.projectIds)
                if TickTickTaskListLayout.bindingKey(forTaskProjectId: task.projectId,
                                                     boundProjectIds: bound) == nil {
                    tasks.removeAll { $0.id == missing.taskId }
                } else {
                    upsert(task)
                }
            }
        } catch TickTickError.notFound {
            // One 404 is待核实; two independent ones remove the task from
            // display (proposal §5.3.5). Never evidence of deletion alone.
            tracker.notFound(missing.taskId)
        } catch let error as TickTickError {
            // 403/401/timeout/5xx are never deletion evidence (proposal §5.3.5).
            absorb(error)
        } catch {}
    }

    // MARK: The write state machine (proposal §6)

    private func requestWrite(taskId: String, noteID: String, targetStatus: Int) async {
        // 校验连接、任务身份与写入能力 (proposal §6.1): the task is located by
        // taskId alone — title and line numbers never participate.
        guard !pausedForAuth, !writesForbidden else { return }
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }
        guard TickTickWritePolicy.mayStartWrite(taskId: taskId,
                                                targetStatus: targetStatus,
                                                existingTask: task,
                                                hasPending: pendingWrites[taskId] != nil,
                                                writesForbidden: writesForbidden) else { return }
        guard let token = lastToken, !token.isEmpty else { return }

        let sentAt = now()
        let operation = TickTickTaskCache.PendingOperation(noteId: noteIdSanitized(noteID),
                                                           taskId: taskId,
                                                           projectId: task.projectId,
                                                           targetStatus: targetStatus,
                                                           generation: epoch,
                                                           sentAt: sentAt)
        pendingWrites[taskId] = PendingWrite(operation: operation, phase: .sending,
                                             attempts: 0, nextConfirmAt: sentAt)

        // 持久化未确认操作,成功后才发请求 (proposal §6.1): a pending that is
        // not durable never leaves the app.
        do { try cache.save(currentSnapshot(now: sentAt)) }
        catch {
            pendingWrites[taskId] = nil
            return
        }
        publishCacheVersion()

        do {
            if targetStatus == 2 {
                try await client(token).completeTask(projectId: task.projectId, taskId: taskId)
            } else {
                try await client(token).updateTaskStatus(taskId: taskId,
                                                          projectId: task.projectId, status: 0)
            }
            // HTTP success is not confirmation (proposal §6.2).
            if pendingWrites[taskId]?.operation.sentAt == sentAt {
                pendingWrites[taskId]?.phase = .awaitingConfirmation
            }
            await confirmWrite(taskId: taskId)
        } catch let error as TickTickError {
            if case .rateLimited(let retryAfter) = error, let retryAfter,
               retryAfter > (diagnostics.retryAfter ?? 0) {
                diagnostics.retryAfter = retryAfter
            }
            applySendFailure(taskId: taskId, error: error)
        } catch {
            applySendFailure(taskId: taskId, error: .network(error.localizedDescription))
        }
    }

    private func applySendFailure(taskId: String, error: TickTickError) {
        switch TickTickWritePolicy.classifySendFailure(error) {
        case .uncertain:
            // Timeout, offline, 5xx, throttling: the result is unknown. Keep
            // the pending, keep reading back, never re-send (proposal §6.2).
            if pendingWrites[taskId] != nil { pendingWrites[taskId]?.phase = .uncertain }
            scheduleConfirmation(taskId: taskId)
        case .rejected:
            // A definitive refusal: the last trusted state stands (§6.2).
            pendingWrites[taskId] = nil
            persistAndPublish(now: now())
        case .unauthorized:
            pausedForAuth = true
            scheduler.cancelAll()
            if pendingWrites[taskId] != nil { pendingWrites[taskId]?.phase = .uncertain }
            publishPhase(.unauthorized)
        }
    }

    /// One authoritative read-back of a pending write: the only thing that
    /// can confirm it (proposal §6.2). `roundGeneration` guards read-backs a
    /// round issued — a self-scheduled confirmation passes nil and relies on
    /// the pending's own epoch.
    private func confirmWrite(taskId: String, roundGeneration: Int? = nil) async {
        guard let write = pendingWrites[taskId] else { return }
        guard write.operation.generation == epoch else {
            // A pending from another account can never be confirmed here.
            pendingWrites[taskId] = nil
            persistAndPublish(now: now())
            return
        }
        let token = lastToken ?? ""
        do {
            let task = try await client(token).task(projectId: write.operation.projectId,
                                                    taskId: taskId)
            if let roundGeneration, generation != roundGeneration { return }
            // The pending may have been confirmed or replaced meanwhile.
            guard pendingWrites[taskId]?.operation.sentAt == write.operation.sentAt else { return }
            if TickTickWritePolicy.confirms(pending: write.operation, readBackStatus: task.status) {
                upsert(task)
                pendingWrites[taskId] = nil
                tracker.seen(taskId)
                tracker.forget([taskId])
                persistAndPublish(now: now())
            } else {
                // Fresh evidence disagrees: keep waiting — the write may not
                // have landed, or the remote may have been reversed; only a
                // confirming read converges (proposal §6.2).
                scheduleConfirmation(taskId: taskId)
            }
        } catch {
            // 404, transport, permission: all unknown — keep the pending.
            scheduleConfirmation(taskId: taskId)
        }
    }

    /// Active waiting inside the 30 s window, then passive confirmation by
    /// later rounds (proposal §6.2). Never a re-send.
    private func scheduleConfirmation(taskId: String) {
        guard var write = pendingWrites[taskId] else { return }
        let roundNow = now()
        let deadline = write.operation.sentAt
            .addingTimeInterval(TickTickWritePolicy.activeConfirmationWindow)
        if roundNow >= deadline {
            // 结果待确认 — the row keeps its feedback, rounds keep reading.
            write.phase = .uncertain
            write.nextConfirmAt = roundNow.addingTimeInterval(Self.undoneIntervalHidden)
            pendingWrites[taskId] = write
            return
        }
        write.attempts += 1
        let cadence = TickTickWritePolicy.confirmRetryDelays[
            min(write.attempts, TickTickWritePolicy.confirmRetryDelays.count) - 1]
        let delay = min(cadence, deadline.timeIntervalSince(roundNow))
        write.nextConfirmAt = roundNow.addingTimeInterval(delay)
        pendingWrites[taskId] = write
        scheduler.schedule(id: Self.confirmTimerPrefix + taskId, interval: delay) { [weak self] in
            Task { await self?.confirmWrite(taskId: taskId) }
        }
    }

    // MARK: Persistence and publishing

    private func currentSnapshot(now savedAt: Date) -> TickTickTaskCache.Snapshot {
        TickTickTaskCache.Snapshot(
            tasks: tasks.sorted { $0.id < $1.id },
            pending: pendingWrites.values.map(\.operation).sorted { $0.taskId < $1.taskId },
            savedAt: savedAt,
            inaccessible: inaccessible)
    }

    /// Saves the merged state and publishes it: bump the cache version (rows
    /// reload), and rewrite every bound note's derived body through the
    /// controlled snapshot writer — title, colour, order and pin untouched
    /// (proposal §4.3). A failed save publishes nothing: "not saved" must
    /// never read as saved (proposal §4.2).
    private func persistAndPublish(now roundNow: Date) {
        do {
            try cache.save(currentSnapshot(now: roundNow))
        } catch {
            return
        }
        publishDerivedBodies(now: roundNow)
    }

    private func publishDerivedBodies(now roundNow: Date) {
        let tasks = self.tasks
        let bindings = currentBindings
        let names = projectNames
        let portal = self.portal
        let noteStore = self.noteStore
        main {
            portal.bumpCacheVersion()
            for binding in bindings {
                let body = TickTickTaskListLayout.noteBody(tasks: tasks,
                                                           boundProjectIds: binding.projectIds,
                                                           projectNames: names,
                                                           now: roundNow)
                noteStore.updateSnapshotBody(id: binding.noteId, body: body)
            }
        }
    }

    private func publishCacheVersion() {
        let portal = self.portal
        main { portal.bumpCacheVersion() }
    }

    private func publishPhase(_ phase: TickTickSyncPhase) {
        let portal = self.portal
        main { portal.setPhase(phase) }
    }

    // MARK: Helpers

    private func upsert(_ task: TickTickTask) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        else { tasks.append(task) }
    }

    private func client(_ token: String) -> TickTickClient {
        if let cached = cachedClient, cached.token == token { return cached.client }
        let client = makeClient(token)
        cachedClient = (token, client)
        return client
    }

    /// The note id recorded on pendings — recorded for attribution and
    /// diagnostics only; identity is always the taskId.
    private func noteIdSanitized(_ noteID: String) -> String {
        noteID.isEmpty ? "-" : noteID
    }

    private static func bindingsSignature(_ bindings: [TickTickBinding]) -> String {
        bindings
            .map { "\($0.noteId):\($0.projectIds.joined(separator: ","))" }
            .sorted()
            .joined(separator: ";")
    }
}
