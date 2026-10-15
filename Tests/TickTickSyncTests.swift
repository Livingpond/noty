import Foundation
import SQLite3

/// Layer-3 TickTick sync (proposal §9.3): the pure merge, window-splitting,
/// backoff and write-policy rules; the engine's read and write timing
/// against a stubbed transport (no network, no account); and the iCloud
/// isolation of task notes across every plan and execution path (proposal
/// §8). The engine's UI and NoteStore mutations land on an injectable
/// dispatch queue, so tests drain them deterministically instead of parking
/// the main run loop.
enum TickTickSyncTests {
    typealias Check = (Bool, String) -> Void

    // MARK: - Entry point

    static func run(check: Check) {
        TickTickTests.StubURLProtocol.reset()
        do {
            try testMergeIntegrityRules(check: check)
            try testMergeSortingAndGrouping(check: check)
            testCompletedWindowSplitter(check: check)
            testBackoffLadder(check: check)
            try testWritePolicyRules(check: check)
            try testMissingTrackerEvidence(check: check)
            try testWriteTimingCacheSaveFailureSendsNothing(check: check)
            try testWriteTimingRepeatedClicksSendOnce(check: check)
            try testWriteTimingSuccessReadBackConverges(check: check)
            try testWriteTimingTimeoutThenServerActuallyCompleted(check: check)
            try testWriteTimingStaleResponseArrivesLate(check: check)
            try testWriteTimingRemoteReverseEdit(check: check)
            try testWriteTimingRestartedPendingOnlyReadsBack(check: check)
            try testUncompleteRunsTheSameStateMachine(check: check)
            try testRepeatedTaskStaysReadOnly(check: check)
            try testMultipleNotesShareTaskState(check: check)
            try testUndoDeleteRestoresBindingAndRereads(check: check)
            try testAccountSwitchQuarantinesOldState(check: check)
            try testCompletedSaturationMarksIncomplete(check: check)
            try testLargeListSaturationMarksIncomplete(check: check)
            try testSameTitleTasksResolveByIdentity(check: check)
            try testPartialListFailureKeepsTasks(check: check)
            try testMissingTaskSurvivesUntilConfirmedTwice(check: check)
            try testMissingReadBackBudget(check: check)
            try testDeletedTaskNoteLifecycle(check: check)
        } catch {
            check(false, "TickTick sync regression failed: \(error)")
        }
        testICloudPlanExcludesTaskNotes(check: check)
        testICloudRunnerExcludesTaskNotes(check: check)
        testICloudExecutionRechecksProtectedIdentity(check: check)
        do {
            try testICloudProtectsTaskNotesWithBrokenBindings(check: check)
        } catch {
            check(false, "TickTick iCloud regression failed: \(error)")
        }
        testICloudQuarantineSurvivesRestart(check: check)
        TickTickTests.StubURLProtocol.reset()
    }

    // MARK: - Shared fixtures

    /// The account's real inbox id, as task payloads carry it; the binding
    /// addresses it through the "inbox" alias.
    private static let inboxProjectID = "inbox62240517"
    private static let workProjectID = "dd304bc59cb99e8098dc0a73"
    private static let projectsJSON = """
    [{"id":"\(workProjectID)","name":"工作","kind":"TASK","sortOrder":12}]
    """

    /// A fixed clock base so snapshots are byte-stable across a scenario.
    private static let baseTime = Date(timeIntervalSince1970: 1_792_000_000)

    /// A task in the wire shape contract verification captured, with the
    /// fields the sync rules read.
    private static func taskJSON(id: String, projectId: String = inboxProjectID,
                                 title: String = "task", status: Int = 0,
                                 kind: String = "TEXT", sortOrder: Int = 0,
                                 completedTime: Date? = nil,
                                 modifiedTime: Date = baseTime,
                                 repeatFlag: Bool? = nil) -> String {
        var fields = "\"id\":\"\(id)\",\"projectId\":\"\(projectId)\",\"title\":\"\(title)\","
            + "\"status\":\(status),\"kind\":\"\(kind)\",\"sortOrder\":\(sortOrder),"
            + "\"priority\":3,\"timeZone\":\"Asia/Shanghai\",\"isAllDay\":false,\"isFloating\":false,"
            + "\"etag\":\"e\",\"etimestamp\":1,"
            + "\"modifiedTime\":\"\(TickTickDate.format(modifiedTime))\","
            + "\"createdTime\":\"\(TickTickDate.format(baseTime))\""
        if let completedTime {
            fields += ",\"completedTime\":\"\(TickTickDate.format(completedTime))\""
        }
        if let repeatFlag {
            fields += ",\"repeatFlag\":\(repeatFlag)"
        }
        return "{\(fields)}"
    }

    private static func task(id: String, projectId: String = inboxProjectID,
                             title: String = "task", status: Int = 0, kind: String = "TEXT",
                             sortOrder: Int = 0, completedTime: Date? = nil,
                             modifiedTime: Date = baseTime,
                             repeatFlag: Bool? = nil) throws -> TickTickTask {
        try TickTickJSON.makeDecoder().decode(
            TickTickTask.self, from: Data(taskJSON(id: id, projectId: projectId, title: title,
                                                   status: status, kind: kind, sortOrder: sortOrder,
                                                   completedTime: completedTime,
                                                   modifiedTime: modifiedTime,
                                                   repeatFlag: repeatFlag).utf8))
    }

    private static func pending(taskId: String, projectId: String = inboxProjectID,
                                targetStatus: Int = 2, generation: Int = 7,
                                sentAt: Date = baseTime) -> TickTickTaskCache.PendingOperation {
        TickTickTaskCache.PendingOperation(noteId: "note-1", taskId: taskId, projectId: projectId,
                                           targetStatus: targetStatus, generation: generation,
                                           sentAt: sentAt)
    }

    private static func outcome(lists: [TickTickListRead] = [],
                                failed: Set<String> = [],
                                completed: [TickTickTask]? = nil,
                                completedComplete: Bool = true) -> TickTickReadOutcome {
        TickTickReadOutcome(lists: lists, failedProjectIds: failed,
                            completedTasks: completed, completedWindowComplete: completedComplete)
    }

    private static func listRead(_ projectId: String, _ tasks: [String]) throws -> TickTickListRead {
        TickTickListRead(projectId: projectId,
                         tasks: try tasks.map { try task(id: $0) },
                         possiblyTruncated: false)
    }

    // MARK: - Pure rules: merge (proposal §5.1/§5.3)

    private static func testMergeIntegrityRules(check: Check) throws {
        // A failed list read is not an empty list: its tasks keep their last
        // known state and the round is flagged incomplete (proposal §5.1).
        let previous = [try task(id: "t-1"), try task(id: "t-2", projectId: workProjectID)]
        let merged = TickTickMerge.merge(previousTasks: previous, pending: [],
                                         outcome: outcome(lists: [try listRead("inbox", ["t-1"])],
                                                          failed: [workProjectID]),
                                         now: baseTime)
        check(merged.tasks.contains { $0.id == "t-1" } && merged.tasks.contains { $0.id == "t-2" },
              "a task from a list that failed to read keeps its last known state")
        check(merged.listsIncomplete, "a failed list read marks the round incomplete")
        check(merged.missing.contains { $0.taskId == "t-1" } == false,
              "a task present in its list's read is not missing")

        // A truncated read proves nothing about absence either (proposal §5.1).
        let truncated = TickTickListRead(projectId: "inbox",
                                         tasks: try [task(id: "t-1")],
                                         possiblyTruncated: true)
        let mergedTruncated = TickTickMerge.merge(previousTasks: previous, pending: [],
                                                  outcome: outcome(lists: [truncated]),
                                                  now: baseTime)
        check(mergedTruncated.missing.isEmpty,
              "a saturation-truncated list read provides no absence evidence")

        // A missing undone task stays in the population and is queued for
        // read-back confirmation — never deleted (proposal §5.3).
        let mergedMissing = TickTickMerge.merge(previousTasks: [try task(id: "t-gone")],
                                                pending: [],
                                                outcome: outcome(lists: [try listRead("inbox", ["t-other"])]),
                                                now: baseTime)
        check(mergedMissing.tasks.contains { $0.id == "t-gone" },
              "a task absent from this round's reads is kept, not deleted")
        check(mergedMissing.missing == [TickTickMerge.Missing(taskId: "t-gone",
                                                              projectId: inboxProjectID)],
              "the missing task is queued for single-task confirmation with its own project")

        // A task that moved to another bound list follows the new read: the
        // upsert rewrites its project, the old membership is gone.
        let moved = TickTickMerge.merge(
            previousTasks: [try task(id: "t-move")],
            pending: [],
            outcome: outcome(lists: [
                try listRead("inbox", []),
                TickTickListRead(projectId: workProjectID,
                                 tasks: [try task(id: "t-move", projectId: workProjectID)],
                                 possiblyTruncated: false)]),
            now: baseTime)
        check(moved.tasks == [try task(id: "t-move", projectId: workProjectID)],
              "a task read in its new list is upserted with the new project")
        check(moved.missing.isEmpty, "a moved task is not missing")

        // A pending completion is not flipped back by list data (§6.2)…
        let staleList = TickTickMerge.merge(
            previousTasks: [try task(id: "t-p")],
            pending: [pending(taskId: "t-p", targetStatus: 2)],
            outcome: outcome(lists: [try listRead("inbox", ["t-p"])]),
            now: baseTime)
        check(staleList.tasks == [try task(id: "t-p")],
              "while a completion is pending, a list read showing it undone changes nothing")
        check(staleList.confirmedPending.isEmpty, "an undone list read does not confirm a completion")
        // …and a completed-window hit with status 2 does confirm it.
        let windowConfirmed = TickTickMerge.merge(
            previousTasks: [try task(id: "t-p")],
            pending: [pending(taskId: "t-p", targetStatus: 2)],
            outcome: outcome(completed: [try task(id: "t-p", status: 2,
                                                  completedTime: baseTime)]),
            now: baseTime)
        check(windowConfirmed.confirmedPending == [pending(taskId: "t-p", targetStatus: 2)],
              "a completed-window hit with status 2 confirms the pending completion")
        check(windowConfirmed.tasks.first?.status == 2, "the confirmed task is merged as completed")
        // …but a window hit does not confirm a pending restore (completedTime
        // survives an un-complete, contract report §四.1).
        let windowNotRestore = TickTickMerge.merge(
            previousTasks: [try task(id: "t-p", status: 2, completedTime: baseTime)],
            pending: [pending(taskId: "t-p", targetStatus: 0)],
            outcome: outcome(completed: [try task(id: "t-p", status: 2,
                                                  completedTime: baseTime)]),
            now: baseTime)
        check(windowNotRestore.confirmedPending.isEmpty,
              "a completed-window hit is not evidence for a pending restore")
        // The undone list read is what confirms a restore.
        let restored = TickTickMerge.merge(
            previousTasks: [try task(id: "t-p", status: 2, completedTime: baseTime)],
            pending: [pending(taskId: "t-p", targetStatus: 0)],
            outcome: outcome(lists: [try listRead("inbox", ["t-p"])]),
            now: baseTime)
        check(restored.confirmedPending == [pending(taskId: "t-p", targetStatus: 0)],
              "an undone list read confirms a pending restore")
        check(restored.tasks.first?.status == 0, "the restored task is merged back as undone")

        // Window expiry removes only completed tasks with a trusted time, and
        // only when the window was complete (proposal §5.2).
        let expired = TickTickMerge.merge(
            previousTasks: [
                try task(id: "t-old", status: 2, completedTime: baseTime.addingTimeInterval(-25 * 3600)),
                try task(id: "t-keep", status: 2, completedTime: baseTime.addingTimeInterval(-3600)),
                try task(id: "t-unknown-time", status: 2),
                try task(id: "t-pending", status: 2,
                         completedTime: baseTime.addingTimeInterval(-25 * 3600)),
            ],
            pending: [pending(taskId: "t-pending", targetStatus: 2)],
            outcome: outcome(completed: [], completedComplete: true),
            now: baseTime)
        let expiredIDs = Set(expired.tasks.map(\.id))
        check(expiredIDs == ["t-keep", "t-unknown-time", "t-pending"],
              "expiry removes only old completions with a trusted time — never unknown times, "
                  + "never pending writes")
        let incompleteWindowKeeps = TickTickMerge.merge(
            previousTasks: [try task(id: "t-old", status: 2,
                                     completedTime: baseTime.addingTimeInterval(-25 * 3600))],
            pending: [],
            outcome: outcome(completed: [], completedComplete: false),
            now: baseTime)
        check(incompleteWindowKeeps.tasks.count == 1,
              "an incomplete window never applies the expiry rule")

        // A recent completion absent from an incomplete window cannot be
        // classified as missing (proposal §5.3): absence proves nothing.
        let unclassified = TickTickMerge.merge(
            previousTasks: [try task(id: "t-recent", status: 2, completedTime: baseTime)],
            pending: [],
            outcome: outcome(lists: [try listRead("inbox", [])], completed: [],
                             completedComplete: false),
            now: baseTime)
        check(unclassified.missing.isEmpty,
              "an incomplete completed window provides no absence evidence for completions")
        // With a complete window omitting it, the recent completion is queued.
        let classified = TickTickMerge.merge(
            previousTasks: [try task(id: "t-recent", status: 2, completedTime: baseTime)],
            pending: [],
            outcome: outcome(lists: [try listRead("inbox", [])], completed: [],
                             completedComplete: true),
            now: baseTime)
        check(classified.missing.map(\.taskId) == ["t-recent"],
              "a recent completion omitted by a complete window is queued for confirmation")
        // A completion older than the window is absent by design, not missing.
        let byDesign = TickTickMerge.merge(
            previousTasks: [try task(id: "t-ancient", status: 2,
                                     completedTime: baseTime.addingTimeInterval(-25 * 3600))],
            pending: [],
            outcome: outcome(lists: [try listRead("inbox", [])], completed: [],
                             completedComplete: true),
            now: baseTime)
        check(byDesign.missing.isEmpty, "an expired completion is not a missing candidate")
    }

    /// 排序分组 (proposal §5.4): the merged population, laid out through the
    /// shared rules, groups in binding order and sorts by sortOrder.
    private static func testMergeSortingAndGrouping(check: Check) throws {
        let merged = TickTickMerge.merge(
            previousTasks: [],
            pending: [],
            outcome: outcome(lists: [
                TickTickListRead(projectId: "inbox",
                                 tasks: [
                                    try task(id: "b", title: "买牛奶", sortOrder: 20),
                                    try task(id: "a", title: "写周报", sortOrder: 10),
                                    try task(id: "c", title: "无序", sortOrder: 0),
                                 ],
                                 possiblyTruncated: false),
                TickTickListRead(projectId: workProjectID,
                                 tasks: [try task(id: "w", projectId: workProjectID,
                                                  title: "工作", sortOrder: 5)],
                                 possiblyTruncated: false),
            ]),
            now: baseTime)
        check(merged.tasks.count == 4, "the merge carries every read task")
        let groups = TickTickTaskListLayout.undoneGroups(
            rows: merged.tasks.map(TickTickTaskRow.init(task:)),
            boundProjectIds: ["inbox", workProjectID])
        check(groups.map(\.projectKey) == ["inbox", workProjectID],
              "merged tasks group in the binding's order")
        check(groups.first?.tasks.map(\.taskId) == ["c", "a", "b"],
              "merged tasks sort by sortOrder ascending inside a group")

        // The shared body derivation (§4.3): header, groups, recent section.
        let body = TickTickTaskListLayout.noteBody(
            tasks: merged.tasks + [try task(id: "done", title: "寄快递", status: 2,
                                            completedTime: baseTime)],
            boundProjectIds: ["inbox"],
            projectNames: [workProjectID: "工作"],
            now: baseTime)
        check(body.contains(Tasks.openPrefix + "写周报")
                  && body.contains(Tasks.openPrefix + "买牛奶")
                  && body.contains(Tasks.donePrefix + "寄快递"),
              "the derived body renders ☐/☑ row prefixes from the merged population")
        check(body.contains(L10n.format("ticktick.recent.section", 1)),
              "the derived body carries the recent-completions heading with its count")
        check(!body.contains("inbox62240517") && !body.contains("taskId"),
              "raw ids never enter the derived body (proposal §1)")
    }

    // MARK: - Pure rules: window splitting (proposal §5.2)

    private static func testCompletedWindowSplitter(check: Check) {
        let splitter = TickTickCompletedSplitter.self
        let window = TickTickCompletedSplitter.Window(start: baseTime,
                                                      end: baseTime.addingTimeInterval(24 * 3600))
        check(splitter.verdict(count: 199, for: window) == .accepted,
              "a window below the cap is proven complete")
        check(splitter.verdict(count: 200, for: window) != .accepted,
              "a saturated window is never assumed complete")
        guard case .split(let first, let second) = splitter.verdict(count: 200, for: window) else {
            check(false, "a wide saturated window must split at its midpoint")
            return
        }
        check(first.start == window.start && second.end == window.end
                  && first.end == second.start,
              "the halves cover the window exactly and share the boundary")
        check(first.end.timeIntervalSince(first.start) == 12 * 3600,
              "the split happens at the time midpoint")
        let tiny = TickTickCompletedSplitter.Window(start: baseTime,
                                                    end: baseTime.addingTimeInterval(1))
        check(splitter.verdict(count: 200, for: tiny) == .saturatedAtMinimum,
              "a saturated window at the one-second floor stops splitting")

        // Dedupe keeps one row per taskId, preferring the freshest read.
        let older = try! task(id: "d", modifiedTime: baseTime)
        let newer = try! task(id: "d", title: "renamed",
                              modifiedTime: baseTime.addingTimeInterval(60))
        let deduped = splitter.dedupe([older, newer])
        check(deduped.count == 1 && deduped.first?.title == "renamed",
              "overlapping windows dedupe by taskId, keeping the freshest observation")
        check(splitter.dedupe([]).isEmpty, "an empty result dedupes to nothing")
    }

    // MARK: - Pure rules: backoff (proposal §7.1)

    private static func testBackoffLadder(check: Check) {
        check(TickTickBackoff.delay(failures: 1, jitter: { 0 }) == 15
                  && TickTickBackoff.delay(failures: 2, jitter: { 0 }) == 30
                  && TickTickBackoff.delay(failures: 3, jitter: { 0 }) == 60
                  && TickTickBackoff.delay(failures: 4, jitter: { 0 }) == 120
                  && TickTickBackoff.delay(failures: 5, jitter: { 0 }) == 300,
              "the backoff ladder climbs 15 → 30 → 60 → 120 → 300 seconds")
        check(TickTickBackoff.delay(failures: 9, jitter: { 0 }) == 300,
              "the ladder caps at 300 seconds")
        check(TickTickBackoff.delay(failures: 0, jitter: { 0 }) == 15,
              "the first failure already backs off 15 seconds")
        // Retry-After outranks the ladder, even beyond the cap (proposal §7.1).
        check(TickTickBackoff.delay(failures: 1, retryAfter: 120, jitter: { 0 }) == 120,
              "a server Retry-After replaces the ladder")
        check(TickTickBackoff.delay(failures: 1, retryAfter: 600, jitter: { 0 }) == 600,
              "a Retry-After beyond 300 seconds is honored, not clipped")
        // Jitter only ever lengthens the wait, and only a little.
        let jittered = TickTickBackoff.delay(failures: 1, jitter: { 0.1 })
        check(jittered > 15 && jittered <= 16.5,
              "jitter adds a small amount on top of the base delay")
    }

    // MARK: - Pure rules: write policy (proposal §6)

    private static func testWritePolicyRules(check: Check) throws {
        let classification: [(TickTickError, TickTickWritePolicy.SendFailure, String)] = [
            (.timedOut, .uncertain, "a timeout leaves the outcome unknown"),
            (.network("offline"), .uncertain, "a connection loss leaves the outcome unknown"),
            (.server, .uncertain, "a 5xx leaves the outcome unknown"),
            (.rateLimited(retryAfter: nil), .uncertain, "throttling leaves the outcome unknown"),
            (.unauthorized, .unauthorized, "401 pauses the engine"),
            (.forbidden, .rejected, "403 is a definitive refusal"),
            (.notFound, .rejected, "404 is a definitive refusal"),
            (.invalidResponse("bad"), .rejected, "a broken response is a definitive refusal"),
            (.httpStatus(400, "no"), .rejected, "other 4xx statuses are definitive refusals"),
        ]
        for (error, expected, message) in classification {
            check(TickTickWritePolicy.classifySendFailure(error) == expected, message)
        }

        check(TickTickWritePolicy.confirms(pending: pending(taskId: "t", targetStatus: 2),
                                           readBackStatus: 2),
              "a read-back showing the target status confirms")
        check(!TickTickWritePolicy.confirms(pending: pending(taskId: "t", targetStatus: 2),
                                            readBackStatus: 0),
              "a read-back showing any other status does not confirm")

        let undone = try task(id: "t")
        check(TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                existingTask: undone, hasPending: false,
                                                writesForbidden: false),
              "a healthy undone task may be completed")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: undone, hasPending: true,
                                                 writesForbidden: false),
              "a task with a pending write is deduplicated — no second request")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: undone, hasPending: false,
                                                 writesForbidden: true),
              "a connection that forbids writes blocks new writes")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: nil, hasPending: false,
                                                 writesForbidden: false),
              "an unknown task cannot be written")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: try task(id: "t", kind: "NOTE"),
                                                 hasPending: false, writesForbidden: false),
              "kind NOTE carries no completion semantics (proposal §5.4)")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: try task(id: "t", repeatFlag: true),
                                                 hasPending: false, writesForbidden: false),
              "a repeating task accepts no completion write — its next instance is unverified (proposal §5.4)")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 0,
                                                 existingTask: try task(id: "t", status: 2,
                                                                        completedTime: baseTime,
                                                                        repeatFlag: true),
                                                 hasPending: false, writesForbidden: false),
              "a repeating task accepts no restore write either — read-only in both directions")
        check(!TickTickWritePolicy.mayStartWrite(taskId: "t", targetStatus: 2,
                                                 existingTask: try task(id: "t", status: 2),
                                                 hasPending: false, writesForbidden: false),
              "a task already in the target state needs no request")

        check(TickTickWritePolicy.activeConfirmationWindow == 30,
              "the active confirmation window is 30 seconds (proposal §6.2)")
    }

    // MARK: - Pure rules: missing-task evidence (proposal §5.3)

    private static func testMissingTrackerEvidence(check: Check) throws {
        var tracker = TickTickMissingTracker()
        // Two independent 404s remove; one does not.
        tracker.notFound("t-404")
        check(tracker.removalTaskIDs().isEmpty, "a single 404 removes nothing")
        tracker.notFound("t-404")
        check(tracker.removalTaskIDs() == ["t-404"],
              "two independent 404s remove the task from display")
        // Reappearing resets the evidence.
        tracker.seen("t-404")
        check(tracker.removalTaskIDs().isEmpty, "a task that reappears resets its 404 evidence")

        // Two unchanged read-backs remove; a fresh modification does not.
        tracker = TickTickMissingTracker()
        let frozen = try task(id: "t-absent", modifiedTime: baseTime)
        tracker.readBack(taskId: "t-absent", observed: frozen, lastObservedModified: baseTime)
        check(tracker.removalTaskIDs().isEmpty, "one unchanged read-back removes nothing")
        tracker.readBack(taskId: "t-absent", observed: frozen, lastObservedModified: baseTime)
        check(tracker.removalTaskIDs() == ["t-absent"],
              "a second unchanged read-back confirms the absence (soft-delete rule)")
        tracker = TickTickMissingTracker()
        let edited = try task(id: "t-absent", modifiedTime: baseTime.addingTimeInterval(600))
        tracker.readBack(taskId: "t-absent", observed: edited, lastObservedModified: baseTime)
        check(tracker.removalTaskIDs().isEmpty,
              "a read-back with a fresh modification is not absence evidence")
        tracker.readBack(taskId: "t-absent", observed: frozen,
                         lastObservedModified: baseTime.addingTimeInterval(600))
        check(tracker.removalTaskIDs().isEmpty,
              "evidence from before an edit does not count after it")
    }

    // MARK: - Engine harness

    /// The engine's synchronous main-queue stand-in: blocks collect until the
    /// test drains them on its own thread, so NoteStore is only ever touched
    /// where the test can see it.
    private final class RecordedMain {
        private let lock = NSLock()
        private var blocks: [() -> Void] = []

        var dispatch: (@escaping () -> Void) -> Void {
            { [weak self] block in
                guard let self else { return }
                self.lock.lock()
                self.blocks.append(block)
                self.lock.unlock()
            }
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return blocks.count
        }

        func drain() {
            lock.lock()
            let pending = blocks
            blocks.removeAll()
            lock.unlock()
            pending.forEach { $0() }
        }
    }

    /// The engine's timer seam, driven by hand: scheduling records an entry,
    /// firing runs it on the test thread (which is where the engine's
    /// nonisolated entry points expect to capture the note snapshot).
    private final class ManualScheduler: TickTickScheduling {
        struct Entry {
            let id: String
            let interval: TimeInterval
            let fire: () -> Void
        }

        private let lock = NSLock()
        private var entries: [Entry] = []

        var scheduled: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return entries
        }

        func entry(id: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries.first { $0.id == id }
        }

        func schedule(id: String, interval: TimeInterval, _ fire: @escaping () -> Void) {
            lock.lock()
            entries.removeAll { $0.id == id }
            entries.append(Entry(id: id, interval: interval, fire: fire))
            lock.unlock()
        }

        func cancel(id: String) {
            lock.lock(); entries.removeAll { $0.id == id }; lock.unlock()
        }

        func cancelAll() {
            lock.lock(); entries.removeAll(); lock.unlock()
        }

        @discardableResult
        func fire(id: String) -> Bool {
            lock.lock()
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                lock.unlock(); return false
            }
            let entry = entries.remove(at: index)
            lock.unlock()
            entry.fire()
            return true
        }
    }

    /// A hand-advanced clock, so the 30-second confirmation window and the
    /// round cadences test without real waiting.
    private final class ManualClock {
        var current = baseTime
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
        var now: () -> Date { { self.current } }
    }

    /// Thread-safe request scripting. Each path holds one response; a later
    /// enqueue replaces it, so scenarios that change the world mid-test take
    /// effect on the very next request. A response with a gate blocks in the
    /// transport until the test opens it — the round is then "in flight" with
    /// a late answer, even once the route has been re-scripted.
    private final class ScriptedTransport {
        struct Response {
            var status: Int = 200
            var body: Data = Data("[]".utf8)
            var headers: [String: String] = ["Content-Type": "application/json"]
            var error: Error?
            var gate: DispatchSemaphore?

            init(status: Int = 200, body: Data = Data("[]".utf8),
                 headers: [String: String] = ["Content-Type": "application/json"],
                 error: Error? = nil, gate: DispatchSemaphore? = nil) {
                self.status = status
                self.body = body
                self.headers = headers
                self.error = error
                self.gate = gate
            }

            init(body: String) {
                self.init(body: Data(body.utf8))
            }
        }

        private let lock = NSLock()
        private var routes: [String: Response] = [:]

        func enqueue(path: String, _ response: Response) {
            lock.lock()
            routes[path] = response
            lock.unlock()
        }

        func requests(to path: String) -> Int {
            TickTickTests.StubURLProtocol.recorded.filter { $0.url?.path == path }.count
        }

        func respond(to request: URLRequest) -> TickTickTests.StubURLProtocol.Stub {
            let path = request.url?.path ?? ""
            lock.lock()
            let response = routes[path] ?? Response(status: 404, body: Data("[]".utf8))
            lock.unlock()
            if let gate = response.gate { gate.wait() }
            var stub = TickTickTests.StubURLProtocol.Stub()
            stub.status = response.status
            stub.body = response.body
            stub.headers = response.headers
            stub.error = response.error
            return stub
        }
    }

    /// One engine scenario: a temp directory, a test keychain with a token, a
    /// bound task note, and every seam injected.
    private final class EngineFixture {
        let directory: URL
        let keychain: TickTickKeychain
        let bindings: TickTickBindingsStore
        let cache: TickTickTaskCache
        let storage: Store
        let noteStore: NoteStore
        let portal = TickTickPortal()
        let main = RecordedMain()
        let scheduler = ManualScheduler()
        let clock = ManualClock()
        let transport = ScriptedTransport()
        let session: URLSession
        let noteID = "note-1"

        let inboxPath = "/open/v1/project/inbox/data"
        let projectsPath = "/open/v1/project"
        let completedPath = "/open/v1/task/completed"

        init(label: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("noty-ticktick-sync-\(label)-\(UUID().uuidString)",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            keychain = TickTickKeychain(service: "app.noty.synctests.\(UUID().uuidString)",
                                        account: "ticktick")
            try keychain.save("token-1")
            bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("bindings.json"))
            cache = TickTickTaskCache(fileURL: directory.appendingPathComponent("cache.bin"),
                                      keyURL: directory.appendingPathComponent("cache.key"))
            storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                            keyURL: directory.appendingPathComponent("note.key"))
            noteStore = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
            noteStore.absorb(Note(id: noteID, title: "任务便签", body: "", source: .ticktick))
            try bindings.save([TickTickBinding(noteId: noteID, projectIds: ["inbox"])])

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TickTickTests.StubURLProtocol.self]
            session = URLSession(configuration: configuration)
            TickTickTests.StubURLProtocol.reset()
            let transport = self.transport
            TickTickTests.StubURLProtocol.handler = { request in transport.respond(to: request) }
        }

        deinit { try? keychain.delete() }

        /// The read-back path for a task of the bound inbox.
        func readBackPath(taskId: String) -> String {
            "/open/v1/project/\(inboxProjectID)/task/\(taskId)"
        }

        /// The read-back path prefix shared by every task of the bound inbox.
        var readBackPrefix: String { "/open/v1/project/\(inboxProjectID)/task/" }

        /// How many single-task read-backs (not completions) have been sent.
        var readBackRequestCount: Int {
            TickTickTests.StubURLProtocol.recorded.filter {
                guard let path = $0.url?.path else { return false }
                return path.hasPrefix(readBackPrefix) && !path.hasSuffix("/complete")
            }.count
        }

        /// The completion path for a task of the bound inbox.
        func completePath(taskId: String) -> String {
            "/open/v1/project/\(inboxProjectID)/task/\(taskId)/complete"
        }

        func makeEngine(cache: TickTickTaskCache? = nil,
                        scheduler: TickTickScheduling? = nil) -> TickTickSyncEngine {
            let noteStore = self.noteStore
            let session = self.session
            return TickTickSyncEngine(
                keychain: keychain,
                bindingsStore: bindings,
                cache: cache ?? self.cache,
                portal: portal,
                noteStore: noteStore,
                noteReader: {
                    // Mirrors the production default: a note inside its undo
                    // window keeps its binding alive (proposal §8.4).
                    noteStore.notes + (noteStore.pendingUndo.map { [$0.note] } ?? [])
                },
                makeClient: { token in TickTickClient(token: token, session: session) },
                scheduler: scheduler ?? self.scheduler,
                main: main.dispatch,
                now: clock.now)
        }

        /// Scripts the account inventory, an inbox read, and an empty
        /// completed window — the round a fresh engine performs first.
        func scriptRound(inboxTasksJSON: [String],
                         completedJSON: String = "[]") {
            transport.enqueue(path: projectsPath, ScriptedTransport.Response(body: projectsJSON))
            transport.enqueue(path: inboxPath, ScriptedTransport.Response(
                body: "{\"tasks\":[\(inboxTasksJSON.joined(separator: ","))],\"columns\":[]}"))
            transport.enqueue(path: completedPath, ScriptedTransport.Response(body: completedJSON))
        }

        func snapshot() -> TickTickTaskCache.Snapshot? {
            var attempt = 0
            while attempt < 50 {
                if let snapshot = try? cache.load() { return snapshot }
                attempt += 1
                usleep(20_000)
            }
            return nil
        }

        var noteBody: String { noteStore.note(id: noteID)?.body ?? "" }
    }

    /// Polls `condition` while draining the fixture's main queue, so UI and
    /// NoteStore mutations land before assertions read them.
    private static func waitUntil(_ fixture: EngineFixture,
                                  timeout: TimeInterval = 5,
                                  _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            fixture.main.drain()
            if condition() { return true }
            usleep(20_000)
        }
        fixture.main.drain()
        return condition()
    }

    // MARK: - Engine: write timing (proposal §9.3)

    /// 缓存落盘失败不发请求 — a pending that is not durable never leaves.
    private static func testWriteTimingCacheSaveFailureSendsNothing(check: Check) throws {
        let fixture = try EngineFixture(label: "cache-failure")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // A cache directory that cannot be written: reads still work (nothing
        // to read), every save fails.
        let locked = fixture.directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: locked.path) }
        let unwritableCache = TickTickTaskCache(fileURL: locked.appendingPathComponent("cache.bin"),
                                                keyURL: locked.appendingPathComponent("cache.key"))
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])

        let engine = fixture.makeEngine(cache: unwritableCache)
        engine.start()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.inboxPath) == 1
        }, "the round must still read the list")

        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        // Give the engine every chance to (wrongly) send, then prove it never did.
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 0,
              "a completion whose pending cannot be persisted must never be sent (proposal §6.1)")
        check((try? unwritableCache.load()) == nil,
              "nothing was persisted for the refused write")
    }

    /// 重复点击只发一次 — one pending per task, the engine deduplicates.
    private static func testWriteTimingRepeatedClicksSendOnce(check: Check) throws {
        let fixture = try EngineFixture(label: "dedupe")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") },
              "the first round must publish the task snapshot")

        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1
        }, "the first click sends the completion")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1,
              "a repeated click while the task is pending or already completed sends nothing (§6.2)")
    }

    /// 成功回读收敛 — HTTP success alone confirms nothing; the authoritative
    /// read-back does.
    private static func testWriteTimingSuccessReadBackConverges(check: Check) throws {
        let fixture = try EngineFixture(label: "converge")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶", sortOrder: 20)])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") },
              "the first round must publish the task snapshot")

        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the read-back must confirm the completion and clear the pending")
        check(fixture.transport.requests(to: fixture.readBackPath(taskId: "t-1")) >= 1,
              "confirmation is the single-task read-back, not the write response")

        let body = fixture.noteBody
        check(body.contains(Tasks.donePrefix + "买牛奶"),
              "the confirmed completion renders ☑ in the derived body")
        check(body.contains(L10n.format("ticktick.recent.section", 1)),
              "the confirmed completion sits in the recent-completions section")
        check(fixture.portal.cacheVersion > 0,
              "the engine publishes the merge through the portal's cache version")
        if case .updated = fixture.portal.phase {} else {
            check(false, "a fully successful round reports the updated phase — got \(fixture.portal.phase)")
        }
    }

    /// 超时后服务端实际已完成 — the outcome is unknown, the pending stays,
    /// nothing is re-sent, and the read-back eventually converges.
    private static func testWriteTimingTimeoutThenServerActuallyCompleted(check: Check) throws {
        let fixture = try EngineFixture(label: "timeout")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        // The completion request dies in transit; the server completed it.
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response(error: URLError(.timedOut)))
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") }, "the round must publish")

        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.pending.contains { $0.taskId == "t-1" } == true
        }, "a timed-out completion keeps its pending — the outcome is unknown (proposal §6.2)")
        check(fixture.scheduler.entry(id: "ticktick.confirm.t-1") != nil,
              "an uncertain write keeps reading back on the confirmation schedule")

        // The active window moves on; the retry read-back converges.
        fixture.clock.advance(3)
        fixture.scheduler.fire(id: "ticktick.confirm.t-1")
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the read-back after the timeout confirms the server-side completion")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1,
              "a timed-out write is never automatically re-sent (proposal §6.2)")
    }

    /// 旧响应晚到 — credentials changed while a round was in flight: every
    /// response in that round is void.
    private static func testWriteTimingStaleResponseArrivesLate(check: Check) throws {
        let fixture = try EngineFixture(label: "stale")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Round 1's list read blocks in the transport and answers with the
        // old account's data.
        let gate = DispatchSemaphore(value: 0)
        fixture.transport.enqueue(path: fixture.projectsPath,
                                  ScriptedTransport.Response(body: projectsJSON))
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: Data("{\"tasks\":[\(taskJSON(id: "t-stale", title: "旧账号任务"))],\"columns\":[]}".utf8),
            gate: gate))
        fixture.transport.enqueue(path: fixture.completedPath,
                                  ScriptedTransport.Response(body: "[]"))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.inboxPath) == 1
        }, "round 1 must have issued its list read")

        // The response the *next* round (with the new token) will read, and
        // the credential change itself — the generation moves while round 1
        // is still in the air.
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[\(taskJSON(id: "t-fresh", title: "新账号任务"))],\"columns\":[]}"))
        try fixture.keychain.save("token-2")
        engine.credentialsDidChange()
        // A round requested now merges with round 1 still in flight.
        fixture.scheduler.fire(id: TickTickSyncEngine.roundTimerID)

        // Release the stale response — the whole round must be discarded.
        gate.signal()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completedPath) == 1
        }, "round 1 finished its queries after the release")
        check(waitUntil(fixture) {
            fixture.scheduler.entry(id: TickTickSyncEngine.roundTimerID) != nil
        }, "the discarded round schedules its merged follow-up")
        fixture.scheduler.fire(id: TickTickSyncEngine.roundTimerID)
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.inboxPath) == 2
        }, "the follow-up round must have read the list with the new credentials")
        check(waitUntil(fixture) { fixture.noteBody.contains("新账号任务") },
              "the fresh round's data must be applied")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(!fixture.noteBody.contains("旧账号任务"),
              "a response from before the credential change never lands (proposal §6.3)")
        let snapshot = fixture.snapshot()
        check(snapshot?.tasks.map(\.id) == ["t-fresh"],
              "the cache carries only the fresh round's tasks — got \(snapshot?.tasks.map(\.id) ?? [])")
    }

    /// 远端反向编辑 — after a confirmed completion, a remote restore aligns
    /// the display without Noty writing anything back.
    private static func testWriteTimingRemoteReverseEdit(check: Check) throws {
        let fixture = try EngineFixture(label: "reverse")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") }, "the round must publish")
        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
        }, "the completion must be confirmed first")

        // The phone restores the task: the next round reads it undone.
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[\(taskJSON(id: "t-1", title: "买牛奶"))],\"columns\":[]}"))
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 0
        }, "a remote restore realigns the task to undone")
        check(waitUntil(fixture) { fixture.noteBody.contains(Tasks.openPrefix + "买牛奶") },
              "the derived body follows the remote edit")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1,
              "a remote reverse edit never triggers a write back (proposal §6.2)")
    }

    /// 重启后 pending 只回读不重放 — the restarted engine reads the pending
    /// back and confirms; it never repeats the POST.
    private static func testWriteTimingRestartedPendingOnlyReadsBack(check: Check) throws {
        let fixture = try EngineFixture(label: "restart")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        // The write leaves; the immediate read-back still sees it undone.
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 0)))

        let firstEngine = fixture.makeEngine()
        firstEngine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") }, "the round must publish")
        firstEngine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.pending.contains { $0.taskId == "t-1" } == true
        }, "the pending must be persisted before the request leaves")
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1
        }, "the first engine sent the completion exactly once")
        // Wait until the first engine's confirming read-back consumed the
        // not-yet-landed answer, then script the landed one.
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.readBackPath(taskId: "t-1")) >= 1
        }, "the first engine read the task back before the restart")

        // Restart: a fresh engine over the same cache, its own scheduler so
        // the first engine's retry timers stay cold. The server has landed
        // the completion by now.
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))
        let secondScheduler = ManualScheduler()
        let secondEngine = fixture.makeEngine(scheduler: secondScheduler)
        secondEngine.start()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the restarted engine confirms the pending by read-back (proposal §4.2)")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1,
              "a restarted pending is only read back, never re-sent")
        check(fixture.transport.requests(to: fixture.readBackPath(taskId: "t-1")) >= 2,
              "the restarted engine did perform the confirming read-back")
        check(fixture.noteBody.contains(Tasks.donePrefix + "买牛奶"),
              "the confirmed completion reaches the derived body after the restart")
    }

    /// 取消完成 — the verified restore path through the same full machine
    /// (proposal §6.4, contract report §2.2).
    private static func testUncompleteRunsTheSameStateMachine(check: Check) throws {
        let fixture = try EngineFixture(label: "uncomplete")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // The task starts completed: it arrives through the completed window.
        let completedTaskJSON = taskJSON(id: "t-1", title: "寄快递", status: 2,
                                         completedTime: fixture.clock.current)
        fixture.scriptRound(inboxTasksJSON: [], completedJSON: "[\(completedTaskJSON)]")
        // The restore write (POST /task/{taskId}) and its confirming
        // read-back (status 0).
        fixture.transport.enqueue(path: "/open/v1/task/t-1", ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "寄快递", status: 0)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains(Tasks.donePrefix + "寄快递") },
              "the completed task must arrive through the completed window first")

        engine.uncompleteTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.transport.requests(to: "/open/v1/task/t-1") == 1
        }, "the restore must POST the task update endpoint")
        let restoreRequest = TickTickTests.StubURLProtocol.recorded
            .first { $0.url?.path == "/open/v1/task/t-1" }
        let restoreBody = restoreRequest?.body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check(restoreBody.map { ($0 as NSDictionary).isEqual(to: ["id": "t-1",
                                                                  "projectId": inboxProjectID,
                                                                  "status": 0]) } == true,
              "the restore sends the minimal verified field set {id, projectId, status: 0}")
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 0
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the read-back must confirm the restore and clear the pending")
        check(waitUntil(fixture) { fixture.noteBody.contains(Tasks.openPrefix + "寄快递") },
              "the restored task returns to the undone group")
    }

    /// 重复任务只读 (proposal §5.4, contract report §四): the write path itself
    /// refuses a repeating task — nothing is persisted, nothing is sent.
    private static func testRepeatedTaskStaysReadOnly(check: Check) throws {
        let fixture = try EngineFixture(label: "repeated")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-r", title: "每周复盘", repeatFlag: true)])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-r"),
                                  ScriptedTransport.Response())

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("每周复盘") },
              "the repeating task is displayed like any other")
        engine.completeTask(taskId: "t-r", noteID: fixture.noteID)
        // Give the engine every chance to (wrongly) write, then prove it never did.
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-r")) == 0,
              "a repeating task never receives a completion request (proposal §5.4)")
        check(fixture.snapshot()?.pending.isEmpty == true,
              "no pending operation is persisted for a repeating task")
        check(fixture.noteBody.contains(Tasks.openPrefix + "每周复盘"),
              "the read-only row stays undone")
    }

    /// 同任务多个便签 (proposal §4.2/§9.3): two notes bound to the same list
    /// render the same tasks, share one pending write and one request — the
    /// second note's click adds nothing — and converge together.
    private static func testMultipleNotesShareTaskState(check: Check) throws {
        let fixture = try EngineFixture(label: "shared")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.noteStore.absorb(Note(id: "note-2", title: "第二张任务便签", body: "",
                                       source: .ticktick))
        try fixture.bindings.save([
            TickTickBinding(noteId: fixture.noteID, projectIds: ["inbox"]),
            TickTickBinding(noteId: "note-2", projectIds: ["inbox"])])
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.noteBody.contains("买牛奶")
                && (fixture.noteStore.note(id: "note-2")?.body.contains("买牛奶") ?? false)
        }, "both notes bound to the list render the same tasks")
        check(waitUntil(fixture) { fixture.transport.requests(to: fixture.inboxPath) == 1 },
              "reads go per deduped list, not per note (proposal §5.1)")

        // The completion is shared: whichever note's row is clicked, the task
        // already has one pending and one request.
        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        engine.completeTask(taskId: "t-1", noteID: "note-2")
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completePath(taskId: "t-1")) == 1
        }, "a task shown by two notes sends its completion once (proposal §4.2)")
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the shared completion is confirmed once")
        check(waitUntil(fixture) {
            fixture.noteBody.contains(Tasks.donePrefix + "买牛奶")
                && (fixture.noteStore.note(id: "note-2")?.body.contains(Tasks.donePrefix + "买牛奶") ?? false)
        }, "both notes' derived bodies converge on the shared state")
    }

    /// 撤销后回读 (proposal §6.3/§8.4/§9.3): after the undo the binding is
    /// live again, the engine keeps reading and publishing, and the write
    /// that happened before the deletion is never replayed.
    private static func testUndoDeleteRestoresBindingAndRereads(check: Check) throws {
        let fixture = try EngineFixture(label: "undo")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains(Tasks.openPrefix + "买牛奶") },
              "the task must be published undone before the write")
        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.pending.isEmpty == true
        }, "the completion is confirmed before the note is deleted")
        let writesBeforeDelete = fixture.transport.requests(to: fixture.completePath(taskId: "t-1"))
        check(writesBeforeDelete == 1, "setup: exactly one completion left the app")

        // Delete → the undo window keeps the binding alive and the engine
        // reading, without resurrecting the note.
        fixture.noteStore.delete(id: fixture.noteID)
        engine.refreshRequested()
        check(waitUntil(fixture) { fixture.noteStore.note(id: fixture.noteID) == nil },
              "the deleted note is not resurrected during the window")
        check(waitUntil(fixture) { fixture.transport.requests(to: fixture.inboxPath) == 2 },
              "the engine keeps reading through the undo window (proposal §8.4)")

        // Undo → the note returns with its binding intact, and the next round
        // re-reads and republishes — the phone restored the task meanwhile.
        fixture.noteStore.undoDelete()
        check(fixture.noteStore.note(id: fixture.noteID)?.source == .ticktick,
              "the undo restores the task note")
        check(fixture.bindings.load(notes: fixture.noteStore.notes)
                  == .loaded([TickTickBinding(noteId: fixture.noteID, projectIds: ["inbox"])]),
              "the binding is live again after the undo")
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[\(taskJSON(id: "t-1", title: "买牛奶"))],\"columns\":[]}"))
        engine.refreshRequested()
        check(waitUntil(fixture) { fixture.noteBody.contains(Tasks.openPrefix + "买牛奶") },
              "the round after the undo re-reads and publishes the current state (proposal §6.3)")
        _ = waitUntil(fixture, timeout: 0.5) { false }
        check(fixture.transport.requests(to: fixture.completePath(taskId: "t-1"))
                  == writesBeforeDelete,
              "the write from before the deletion is not replayed after the undo (proposal §6.3)")
    }

    /// 账号切换隔离 (proposal §4.2/§7.2/§9.3): a credential change whose
    /// account inventory differs quarantines the old account's tasks and
    /// pendings instead of merging them into the new account's display.
    private static func testAccountSwitchQuarantinesOldState(check: Check) throws {
        let fixture = try EngineFixture(label: "account-switch")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-old", title: "旧账号任务")])
        // The old account leaves an unconfirmed write behind: the completion
        // times out in transit, the read-back still sees it undone.
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-old"),
                                  ScriptedTransport.Response(error: URLError(.timedOut)))
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-old"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-old", title: "旧账号任务")))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("旧账号任务") },
              "the old account's task must be visible first")
        engine.completeTask(taskId: "t-old", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.pending.contains { $0.taskId == "t-old" } == true
        }, "the old account leaves an unconfirmed pending behind")

        // Switch credentials to another account: its inventory differs, so
        // the account key moves and the old state is quarantined.
        let otherProjectsJSON = """
        [{"id":"b999999999999999999999999","name":"新账号清单","kind":"TASK","sortOrder":1}]
        """
        fixture.transport.enqueue(path: fixture.projectsPath,
                                  ScriptedTransport.Response(body: otherProjectsJSON))
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[\(taskJSON(id: "t-new", title: "新账号任务"))],\"columns\":[]}"))
        fixture.transport.enqueue(path: fixture.completedPath,
                                  ScriptedTransport.Response(body: "[]"))
        try fixture.keychain.save("token-2")
        engine.credentialsDidChange()
        engine.refreshRequested()

        check(waitUntil(fixture) { fixture.noteBody.contains("新账号任务") },
              "the new account's tasks load after the switch")
        check(waitUntil(fixture) {
            let snapshot = fixture.snapshot()
            return snapshot?.tasks.map(\.id) == ["t-new"]
        }, "the old account's tasks are quarantined, not merged (proposal §4.2)")
        check(waitUntil(fixture) { fixture.snapshot()?.pending.isEmpty == true },
              "the old account's pendings leave with its tasks")
        check(waitUntil(fixture) { fixture.noteBody.contains("旧账号任务") == false },
              "nothing of the old account survives in the display")
        check(waitUntil(fixture) {
            fixture.portal.projectNames["b999999999999999999999999"] == "新账号清单"
        }, "the account's list names follow the new account")
    }

    // MARK: - Engine: read integrity (proposal §5)

    /// 200 饱和标记 — a saturated completed window splits within the round's
    /// request budget and leaves the incomplete mark standing.
    private static func testCompletedSaturationMarksIncomplete(check: Check) throws {
        let fixture = try EngineFixture(label: "saturation")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // Every window query answers with a full page: the round must split,
        // stop at the budget, and keep the incomplete mark.
        let saturatedPage = "[" + (0..<TickTickCompletedSplitter.saturationCount)
            .map { taskJSON(id: "sat-\($0)", status: 2, completedTime: baseTime) }
            .joined(separator: ",") + "]"
        fixture.scriptRound(inboxTasksJSON: [], completedJSON: saturatedPage)

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completedPath)
                == TickTickCompletedSplitter.maxRequestsPerRound
        }, "a saturated window splits, spending at most the round's request budget")
        check(waitUntil(fixture) {
            if case .incomplete = fixture.portal.phase { return true } else { return false }
        }, "saturation marks the round as incomplete (proposal §5.2)")
        let snapshot = fixture.snapshot()
        check(snapshot?.tasks.count == TickTickCompletedSplitter.saturationCount,
              "the saturated page's tasks are kept — saturation is about completeness, not content")
        // Later rounds keep the leftover windows queued rather than exploding.
        fixture.clock.advance(TickTickSyncEngine.completedQueryInterval)
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.completedPath)
                > TickTickCompletedSplitter.maxRequestsPerRound
        }, "the next round continues the leftover windows")
        let totalCompletedRequests = fixture.transport.requests(to: fixture.completedPath)
        check(totalCompletedRequests <= 2 * TickTickCompletedSplitter.maxRequestsPerRound,
              "each round caps its own completed-query budget — got \(totalCompletedRequests)")
    }

    /// 大清单不完整 (proposal §5.1/§9.3): a `/project/{id}/data` read that comes
    /// back with saturation-many rows cannot be proven complete, so the
    /// engine assembles it as possibly truncated and the round reports the
    /// incomplete phase — the rows themselves are kept.
    private static func testLargeListSaturationMarksIncomplete(check: Check) throws {
        let fixture = try EngineFixture(label: "large-list")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let saturated = (0..<TickTickCompletedSplitter.saturationCount)
            .map { taskJSON(id: "big-\($0)", title: "任务\($0)") }
        fixture.scriptRound(inboxTasksJSON: saturated)

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            if case .incomplete = fixture.portal.phase { return true } else { return false }
        }, "a saturated list read marks the round incomplete (proposal §5.1)")
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.count == TickTickCompletedSplitter.saturationCount
        }, "the saturated rows are kept — incompleteness is about evidence, not content")
        check(waitUntil(fixture) {
            fixture.noteBody.components(separatedBy: "\n")
                .filter { $0.hasPrefix(Tasks.openPrefix) }.count
                == TickTickCompletedSplitter.saturationCount
        }, "every saturated row renders in the derived snapshot")
    }

    /// 同名任务 (proposal §9.3 身份与展示): two tasks sharing one title stay two
    /// rows, and a completion addressed by taskId lands on exactly the task
    /// that was clicked — never on its namesake.
    private static func testSameTitleTasksResolveByIdentity(check: Check) throws {
        let fixture = try EngineFixture(label: "same-title")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [
            taskJSON(id: "t-1", title: "买牛奶", sortOrder: 10),
            taskJSON(id: "t-2", title: "买牛奶", sortOrder: 20),
        ])
        fixture.transport.enqueue(path: fixture.completePath(taskId: "t-1"),
                                  ScriptedTransport.Response())
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(
                                    body: taskJSON(id: "t-1", title: "买牛奶", status: 2,
                                                   completedTime: fixture.clock.current)))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.noteBody.components(separatedBy: "\n")
                .filter { $0 == Tasks.openPrefix + "买牛奶" }.count == 2
        }, "two same-titled tasks render as two rows")

        // Completing one of them — addressed by taskId only.
        engine.completeTask(taskId: "t-1", noteID: fixture.noteID)
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.first { $0.id == "t-1" }?.status == 2
                && fixture.snapshot()?.tasks.first { $0.id == "t-2" }?.status == 0
        }, "the completion landed on the clicked taskId, not on the namesake")
        let lines = fixture.noteBody.components(separatedBy: "\n")
        check(lines.filter { $0 == Tasks.donePrefix + "买牛奶" }.count == 1
                  && lines.filter { $0 == Tasks.openPrefix + "买牛奶" }.count == 1,
              "the derived body shows one ☑ and one ☐ with the same title (proposal §9.3)")
    }

    /// 部分清单失败 — one list failing keeps its tasks and flags the round.
    private static func testPartialListFailureKeepsTasks(check: Check) throws {
        let fixture = try EngineFixture(label: "partial")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        // The note binds the inbox plus a second list.
        try fixture.bindings.save([
            TickTickBinding(noteId: fixture.noteID, projectIds: ["inbox", workProjectID])])
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-inbox", title: "收件箱任务")])
        // The second list reads fine first…
        fixture.transport.enqueue(path: "/open/v1/project/\(workProjectID)/data",
                                  ScriptedTransport.Response(
                                    body: "{\"tasks\":[\(taskJSON(id: "t-work", projectId: workProjectID, title: "工作"))],\"columns\":[]}"))

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.contains { $0.id == "t-work" } == true
        }, "a healthy second list's tasks land")

        // …then fails outright, and its tasks must survive (proposal §5.1).
        fixture.transport.enqueue(path: "/open/v1/project/\(workProjectID)/data",
                                  ScriptedTransport.Response(status: 500))
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.contains { $0.id == "t-work" } == true
        }, "a task from a list that failed to read keeps its last known state — never emptied")
        check(waitUntil(fixture) {
            if case .incomplete = fixture.portal.phase { return true } else { return false }
        }, "the partially failed round reports the incomplete phase")

        // The missing-tasks read was not needed for the inbox task, which was read.
        let snapshot = fixture.snapshot()
        check(snapshot?.tasks.contains { $0.id == "t-inbox" } == true,
              "the successfully read list's tasks are intact alongside the failed one's")
    }

    /// 缺失不等于删除 + 404/权限分流 — one 404 keeps the task, a permission
    /// failure never counts, two independent 404s remove it as inaccessible.
    private static func testMissingTaskSurvivesUntilConfirmedTwice(check: Check) throws {
        let fixture = try EngineFixture(label: "missing")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") },
              "the task must be present before it goes missing")

        // Round 2: the task vanished from the list read; the read-back
        // answers 404 once. The row must stay (proposal §5.3).
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[],\"columns\":[]}"))
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(status: 404))
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.contains { $0.id == "t-1" } == true
        }, "a task missing from one round is kept, not deleted")
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.readBackPath(taskId: "t-1")) == 1
        }, "the missing task triggered a single-task read-back")
        check(fixture.snapshot()?.inaccessible?.isEmpty == true,
              "one 404 removes nothing")

        // Round 3: a permission failure on the read-back is not deletion
        // evidence either (proposal §5.3.5).
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(status: 403))
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.readBackPath(taskId: "t-1")) == 2
        }, "the second round also attempted a read-back")
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.contains { $0.id == "t-1" } == true
        }, "a 403 read-back never removes the task")

        // Round 4: the second independent 404 removes it — described as
        // inaccessible, never as deleted (proposal §5.3.5).
        fixture.transport.enqueue(path: fixture.readBackPath(taskId: "t-1"),
                                  ScriptedTransport.Response(status: 404))
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.contains { $0.id == "t-1" } == false
        }, "two independent 404s remove the task from display")
        let snapshot = fixture.snapshot()
        check(snapshot?.inaccessible?.map(\.taskId) == ["t-1"],
              "the removal is recorded as inaccessible")
        check(snapshot?.inaccessible?.first?.title == "买牛奶",
              "the inaccessible description carries the task's title")
        check(fixture.noteBody.contains("买牛奶") == false,
              "the removed task leaves the derived body")
    }

    /// 单轮回读预算 4 项 (proposal §5.3): five tasks go missing in one round,
    /// only four read-backs leave — the rest wait in the queue for the next.
    private static func testMissingReadBackBudget(check: Check) throws {
        let fixture = try EngineFixture(label: "budget")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let ids = (0..<5).map { "b-\($0)" }
        fixture.scriptRound(inboxTasksJSON: ids.map { taskJSON(id: $0) })

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.count == 5
        }, "all five tasks must be published first")

        // They all vanish; every read-back answers 404.
        fixture.transport.enqueue(path: fixture.inboxPath, ScriptedTransport.Response(
            body: "{\"tasks\":[],\"columns\":[]}"))
        fixture.transport.enqueue(path: "\(fixture.readBackPrefix)/b-0", ScriptedTransport.Response(status: 404))
        fixture.transport.enqueue(path: "\(fixture.readBackPrefix)/b-1", ScriptedTransport.Response(status: 404))
        fixture.transport.enqueue(path: "\(fixture.readBackPrefix)/b-2", ScriptedTransport.Response(status: 404))
        fixture.transport.enqueue(path: "\(fixture.readBackPrefix)/b-3", ScriptedTransport.Response(status: 404))
        fixture.transport.enqueue(path: "\(fixture.readBackPrefix)/b-4", ScriptedTransport.Response(status: 404))
        engine.refreshRequested()
        check(waitUntil(fixture) { fixture.readBackRequestCount == 4 },
              "a round confirms at most four missing tasks — the rest stay queued")
        // All five stay: one 404 removes nothing (proposal §5.3.5).
        check(waitUntil(fixture) {
            fixture.snapshot()?.tasks.count == 5
        }, "budget or not, missing tasks are never deleted without confirmation")
    }

    /// 删除任务便签的生命周期 (proposal §8.4/§6.3): during the undo window the
    /// binding stays and the engine keeps running; once the window closes the
    /// binding leaves with the note and scheduling stops — and nothing ever
    /// calls a TickTick deletion endpoint.
    private static func testDeletedTaskNoteLifecycle(check: Check) throws {
        let fixture = try EngineFixture(label: "delete")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.scriptRound(inboxTasksJSON: [taskJSON(id: "t-1", title: "买牛奶")])

        let engine = fixture.makeEngine()
        engine.start()
        check(waitUntil(fixture) { fixture.noteBody.contains("买牛奶") },
              "the task must be published before the note is deleted")

        // Deleting the note opens the ten-second undo window: the binding is
        // kept, the engine keeps reading, and the note is not resurrected.
        fixture.noteStore.delete(id: fixture.noteID)
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.transport.requests(to: fixture.inboxPath) == 2
        }, "the undo window keeps the binding alive and the engine reading (§8.4)")
        check(fixture.noteStore.note(id: fixture.noteID) == nil,
              "a deleted task note is not resurrected by the round")
        var bindingSurvivedWindow = false
        if case .loaded(let remaining) = fixture.bindings.load(
                notes: [Note(id: fixture.noteID, title: "", body: "", source: .ticktick)]) {
            bindingSurvivedWindow = !remaining.isEmpty
        }
        check(bindingSurvivedWindow, "the binding survives the undo window")

        // The window closes: the binding is pruned and scheduling stops.
        fixture.noteStore.pendingUndo = nil
        engine.refreshRequested()
        check(waitUntil(fixture) {
            fixture.bindings.load(notes: []) == .loaded([])
        }, "the binding is pruned once the undo window closes (§8.4)")
        check(waitUntil(fixture) { fixture.portal.phase == .idle },
              "with no task note left the engine goes idle")
        // Deleting a task note never deletes anything remotely: the only
        // requests on record are reads.
        let requestPaths = TickTickTests.StubURLProtocol.recorded.compactMap(\.url?.path)
        check(requestPaths.allSatisfy { !$0.contains("/delete") },
              "no deletion request was ever sent")
    }

    // MARK: - iCloud isolation (proposal §8)
    /// The plan: task notes leave the decision view entirely — no push, no
    /// deleteLocal, no pull, and leftover cloud files claiming their ids get
    /// no action at all. Plain notes keep their existing behavior.
    private static func testICloudPlanExcludesTaskNotes(check: Check) {
        let modified = Date(timeIntervalSince1970: 1_757_000_000)
        func plain(_ id: String) -> Note {
            var n = Note()
            n.id = id
            n.title = "plain"
            n.body = "text"
            n.modified = modified
            return n
        }
        func taskNote(_ id: String) -> Note {
            var n = plain(id)
            n.source = .ticktick
            return n
        }
        func file(_ name: String, id: String?) -> SyncPlan.RemoteFile {
            SyncPlan.RemoteFile(fileName: name, noteID: id,
                                declaredModified: modified, fileModified: modified)
        }

        // A task note with no remote file: never pushed, even with no index
        // entry (which would push a plain note).
        let actions = SyncPlan.actions(notes: [taskNote("tt")],
                                       remote: [], unresolved: [], index: CloudSyncIndex())
        check(actions.isEmpty,
              "a task note never pushes — not even on a first sync")

        // A task note with a remote file claiming its id: nothing at all for
        // it. A plain note in the same pass with an agreeing file just
        // re-indexes — the old behavior, untouched.
        let mixed = SyncPlan.actions(notes: [taskNote("tt"), plain("pl")],
                                     remote: [file("Task.md", id: "tt"),
                                              file("Plain.md", id: "pl")],
                                     unresolved: [], index: CloudSyncIndex())
        check(mixed == [.reindex(noteID: "pl", fileName: "Plain.md")],
              "the leftover file claiming a task note's id gets no action, and the plain "
                  + "note keeps its existing behavior")

        // An index entry that remembers a task note's file must not produce a
        // deleteLocal when the file is gone, nor a deleteRemote when the note
        // is gone: the identity is protected either way.
        var index = CloudSyncIndex()
        index.record(noteID: "tt", fileName: "Task.md",
                     noteModified: modified, fileModified: modified)
        let gone = SyncPlan.actions(notes: [taskNote("tt")],
                                    remote: [], unresolved: [], index: index)
        check(gone.isEmpty,
              "a task note whose indexed file is gone is never deleted locally")
        // The same leftover with no protected local note is a plain stale
        // file again — the paused set is what preserves the quarantine.
        let notProtected = SyncPlan.actions(notes: [], remote: [file("Task.md", id: "tt")],
                                            unresolved: [], index: index)
        check(notProtected == [.deleteRemote(fileName: "Task.md")],
              "without protection the stale-file rule keeps its old shape")
        let stillProtected = SyncPlan.actions(notes: [], remote: [file("Task.md", id: "tt")],
                                              unresolved: [], index: index,
                                              pausedNoteIDs: ["tt"])
        check(stillProtected.isEmpty,
              "a quarantined identity stays excluded even with no local note behind it")

        // Plain notes keep every existing behavior: an unpushed plain note
        // pushes, an unindexed remote file is pulled.
        let plainPush = SyncPlan.actions(notes: [plain("pl")], remote: [],
                                         unresolved: [], index: CloudSyncIndex())
        check(plainPush == [.push(noteID: "pl", existingFileName: nil)],
              "plain notes keep pushing on a first sync")
    }

    /// The runner: a leftover cloud file claiming a task note's identity is
    /// quarantined — not deleted, not pulled — and plain notes around it
    /// keep syncing normally.
    private static func testICloudRunnerExcludesTaskNotes(check: Check) {
        let folder = SyncFakeFolder()
        let store = SyncFakeStore()
        var plain = Note()
        plain.id = "pl"
        plain.title = "plain"
        plain.body = "text"
        var taskNote = plain
        taskNote.id = "tt"
        taskNote.title = "任务便签"
        taskNote.body = "snapshot"
        taskNote.source = .ticktick
        store.notes = [plain, taskNote]
        // A leftover cloud copy claiming the task note's identity.
        folder.files["Task.md"] = NoteDocument.render(taskNote)
        folder.dates["Task.md"] = Date(timeIntervalSince1970: 1_757_000_000)

        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-index-\(UUID().uuidString).json")
        let pausedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-paused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: pausedURL) }
        let wasEnabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = wasEnabled }

        let sync = CloudSync(folder: folder, store: store, indexURL: indexURL,
                             pausedURL: pausedURL)
        sync.syncNow()

        check(folder.files["Task.md"] != nil,
              "the leftover cloud file is never deleted (proposal §8.5)")
        check(folder.removed.isEmpty, "nothing was removed from the folder")
        check(store.notes.contains { $0.id == "tt" },
              "the task note itself is untouched")
        check(sync.pausedNoteIDs.contains("tt"),
              "the leftover's identity is quarantined")
        // The plain note still synced: pushed, indexed, its file present.
        check(folder.files.values.contains { $0.contains("plain") },
              "plain notes keep syncing around the quarantine")
        check(store.notes.contains { $0.id == "pl" },
              "the plain note stays in the store")
        // No second note was adopted from the task note's file.
        check(store.notes.count == 2, "the leftover file did not become a note")

        // A second pass stays quiet about the quarantine: the file survives.
        sync.syncNow()
        check(folder.files["Task.md"] != nil, "the quarantine holds across passes")
        check(sync.pausedNoteIDs == ["tt"], "the quarantine does not grow")
    }

    /// 执行前复查受保护身份 — the runner re-checks before performing, so a
    /// plan naming a task note (a stale plan, a future caller) does nothing.
    private static func testICloudExecutionRechecksProtectedIdentity(check: Check) {
        let folder = SyncFakeFolder()
        let store = SyncFakeStore()
        var taskNote = Note()
        taskNote.id = "tt"
        taskNote.title = "任务便签"
        taskNote.body = "snapshot"
        taskNote.source = .ticktick
        var plain = Note()
        plain.id = "pl"
        plain.title = "plain"
        plain.body = "text"
        store.notes = [taskNote, plain]
        folder.files["Plain.md"] = NoteDocument.render(plain)

        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-index-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL) }
        let wasEnabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = wasEnabled }

        // Seed the index so deleteRemote's identity re-check has something
        // to find.
        var index = CloudSyncIndex()
        index.record(noteID: "tt", fileName: "Task.md",
                     noteModified: Date(timeIntervalSince1970: 1_757_000_000),
                     fileModified: Date(timeIntervalSince1970: 1_757_000_000))
        index.save(to: indexURL)
        let pausedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-paused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pausedURL) }
        let sync = CloudSync(folder: folder, store: store, indexURL: indexURL,
                             pausedURL: pausedURL)
        folder.files["Task.md"] = NoteDocument.render(taskNote)

        sync.perform(.push(noteID: "tt", existingFileName: nil))
        check(folder.written.filter { $0.1.contains("snapshot") }.isEmpty,
              "performing a push for a task note writes nothing (§8.2)")
        let fileNames = folder.files.keys.sorted()
        check(!fileNames.contains { $0 != "Plain.md" && $0 != "Task.md" },
              "no file was created for the task note")

        sync.perform(.deleteLocal(noteID: "tt"))
        check(store.notes.contains { $0.id == "tt" },
              "performing a deleteLocal for a task note deletes nothing (§8.2)")
        check(store.deleted.isEmpty, "the store saw no deletion")

        sync.perform(.deleteRemote(fileName: "Task.md"))
        check(folder.files["Task.md"] != nil,
              "performing a deleteRemote for a protected identity removes nothing (§8.2)")
        check(folder.removed.isEmpty, "the folder saw no removal")
    }

    /// 同 ID 云文件不重建便签,跨重启 (proposal §8.5/§9.3): the quarantine is
    /// persisted, so after a relaunch — with the task note long deleted and
    /// its binding pruned — the leftover cloud file is neither deleted nor
    /// re-imported as a note.
    private static func testICloudQuarantineSurvivesRestart(check: Check) {
        let folder = SyncFakeFolder()
        let store = SyncFakeStore()
        var plain = Note()
        plain.id = "pl"
        plain.title = "plain"
        plain.body = "text"
        var taskNote = plain
        taskNote.id = "tt"
        taskNote.title = "任务便签"
        taskNote.body = "snapshot"
        taskNote.source = .ticktick
        // A leftover cloud copy claiming the task note's identity, plus an
        // index entry that remembers the pairing (the deleteRemote-side path).
        folder.files["Task.md"] = NoteDocument.render(taskNote)
        folder.dates["Task.md"] = Date(timeIntervalSince1970: 1_757_000_000)
        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-index-\(UUID().uuidString).json")
        let pausedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-paused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: pausedURL) }
        var seed = CloudSyncIndex()
        seed.record(noteID: "tt", fileName: "Task.md",
                    noteModified: Date(timeIntervalSince1970: 1_757_000_000),
                    fileModified: Date(timeIntervalSince1970: 1_757_000_000))
        seed.save(to: indexURL)

        let wasEnabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = wasEnabled }

        // Pass 1, note alive: the leftover is quarantined — durably.
        store.notes = [plain, taskNote]
        let first = CloudSync(folder: folder, store: store, indexURL: indexURL,
                              pausedURL: pausedURL)
        first.syncNow()
        check(first.pausedNoteIDs == ["tt"], "the leftover's identity is quarantined")
        check(CloudSyncQuarantine.load(from: pausedURL).pausedNoteIDs == ["tt"],
              "the quarantine is written to disk (proposal §8.5)")
        check(folder.files["Task.md"] != nil, "the leftover cloud file survives pass 1")

        // Restart: the task note was deleted before the relaunch (its undo
        // window closed, its binding pruned) — only the persisted quarantine
        // still protects the id. Without it, the indexed file would look like
        // a plain stale file and be deleted remotely.
        let restartedStore = SyncFakeStore()
        restartedStore.notes = [plain]
        let second = CloudSync(folder: folder, store: restartedStore, indexURL: indexURL,
                               pausedURL: pausedURL)
        second.syncNow()
        check(second.pausedNoteIDs.contains("tt"),
              "the quarantine was reloaded from disk after the restart")
        check(folder.files["Task.md"] != nil,
              "the cloud file is not deleted after the restart (proposal §8.5)")
        check(folder.removed.isEmpty, "the folder saw no removal across the restart")
        check(restartedStore.notes.allSatisfy { $0.id != "tt" },
              "the cloud file did not come back as a note after the restart")
        check(restartedStore.deleted.isEmpty, "no local note was deleted either")
    }

    /// 绑定异常仍保护 (proposal §8.2/§9.3): the sync-time protection reads the
    /// notes' own `source` field and never consults the bindings file — a
    /// broken or missing binding file cannot turn a task note back into a
    /// syncable plain one.
    private static func testICloudProtectsTaskNotesWithBrokenBindings(check: Check) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noty-ticktick-sync-broken-bindings-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A bindings file that is outright garbage: the engine would report
        // misconfigured, but that state must not unprotect the note.
        let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
        try Data("not json".utf8).write(to: bindings.fileURL, options: .atomic)
        var taskNote = Note()
        taskNote.id = "tt"
        taskNote.title = "任务便签"
        taskNote.body = "snapshot"
        taskNote.source = .ticktick
        var plain = Note()
        plain.id = "pl"
        plain.title = "plain"
        plain.body = "text"
        if case .invalid = bindings.load(notes: [taskNote, plain]) {} else {
            check(false, "setup: the bindings file must be in the broken state")
            return
        }

        let folder = SyncFakeFolder()
        let store = SyncFakeStore()
        store.notes = [taskNote, plain]
        let indexURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-index-\(UUID().uuidString).json")
        let pausedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noty-ticktick-sync-paused-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: indexURL)
            try? FileManager.default.removeItem(at: pausedURL) }
        let wasEnabled = Settings.cloudSyncEnabled
        Settings.cloudSyncEnabled = true
        defer { Settings.cloudSyncEnabled = wasEnabled }

        let sync = CloudSync(folder: folder, store: store, indexURL: indexURL,
                             pausedURL: pausedURL)
        sync.syncNow()
        check(folder.written.filter { $0.1.contains("snapshot") }.isEmpty,
              "a task note is never pushed, even with a broken bindings file (§8.2)")
        check(folder.files.values.allSatisfy { !$0.contains("snapshot") },
              "no cloud file carries the task snapshot")
        check(store.notes.contains { $0.id == "tt" } && store.deleted.isEmpty,
              "the task note itself is untouched")
        check(folder.written.contains { $0.1.contains("plain") },
              "plain notes keep syncing around the broken configuration")
    }

    // MARK: - iCloud fakes

    /// Minimal folder fake: enough of the protocol for the isolation paths.
    private final class SyncFakeFolder: SyncFolderGateway {
        var files: [String: String] = [:]
        var dates: [String: Date] = [:]
        var written: [(String, String)] = []
        var removed: [String] = []
        var reads: [String] = []

        var isAvailable: Bool { true }
        func ensureFolder() -> Bool { true }

        func scan() -> FolderScan {
            var scan = FolderScan()
            for (name, _) in files { scan.documents[name] = dates[name] ?? Date() }
            return scan
        }

        func read(_ fileName: String) -> String? {
            reads.append(fileName)
            return files[fileName]
        }

        func modificationDate(of fileName: String) -> Date? { dates[fileName] ?? Date() }

        @discardableResult
        func write(_ text: String, named fileName: String) -> Bool {
            written.append((fileName, text))
            files[fileName] = text
            dates[fileName] = Date()
            return true
        }

        @discardableResult
        func remove(_ fileName: String) -> Bool {
            removed.append(fileName)
            files[fileName] = nil
            dates[fileName] = nil
            return true
        }

        @discardableResult
        func writeConflict(_ text: String, named fileName: String) -> Bool {
            files["Conflicts/" + fileName] = text
            return true
        }
    }

    private final class SyncFakeStore: NoteStoring {
        var notes: [Note] = []
        var deleted: [String] = []

        var active: [Note] { notes.filter { !$0.archived }.sorted { $0.order < $1.order } }
        func note(id: String) -> Note? { notes.first { $0.id == id } }

        func absorb(_ note: Note) {
            if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
            else { notes.append(note) }
        }

        func delete(id: String) {
            deleted.append(id)
            notes.removeAll { $0.id == id }
        }
    }
}
