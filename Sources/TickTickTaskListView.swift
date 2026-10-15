import SwiftUI
import AppKit
import Combine

// MARK: - Display rows

/// One task as the list renders it: identity and placement only. `sortOrder`
/// is optional because the display rule treats a missing value differently —
/// such rows sort to the end of their group (proposal §5.4). `isRepeated`
/// marks the read-only rows: a repeating task's next instance is unverified,
/// so it shows and completes in TickTick, never here.
struct TickTickTaskRow: Equatable, Identifiable {
    let taskId: String
    let projectId: String
    let title: String
    /// 0 undone, 2 completed.
    let status: Int
    /// "TEXT", "NOTE" or "CHECKLIST".
    let kind: String
    let sortOrder: Int?
    let completedTime: Date?
    let isRepeated: Bool

    var id: String { taskId }
    var isCompleted: Bool { status == 2 }

    init(task: TickTickTask) {
        taskId = task.id
        projectId = task.projectId
        title = task.title
        status = task.status
        kind = task.kind
        sortOrder = task.sortOrder
        completedTime = task.completedTime
        isRepeated = task.repeatFlag == true
    }

    init(taskId: String, projectId: String, title: String,
         status: Int, kind: String, sortOrder: Int?, completedTime: Date? = nil,
         isRepeated: Bool = false) {
        self.taskId = taskId
        self.projectId = projectId
        self.title = title
        self.status = status
        self.kind = kind
        self.sortOrder = sortOrder
        self.completedTime = completedTime
        self.isRepeated = isRepeated
    }
}

// MARK: - List layout (pure)

/// The task list's arrangement rules (proposal §5.4), as pure functions so
/// they regression-test without a live view: which tasks a note's binding
/// claims, how undone tasks group and order, how recent completions surface,
/// and what the derived text snapshot says. The engine (next phase) reuses
/// the same rules when it merges reads.
enum TickTickTaskListLayout {

    /// One group of undone tasks, keyed by the binding entry it belongs to.
    struct Group: Equatable {
        let projectKey: String
        let tasks: [TickTickTaskRow]
    }

    /// The binding entry a task's real project id resolves to, or nil when
    /// the task belongs to none of the note's lists. Bindings address the
    /// inbox through the "inbox" alias, but tasks come back carrying the
    /// account's real inbox id — "inbox" followed by digits in every shape
    /// contract verification captured, while ordinary list ids are
    /// 24-character hex strings that cannot begin with those letters. A
    /// response that literally echoes "inbox" matches too.
    static func bindingKey(forTaskProjectId projectId: String,
                           boundProjectIds: [String]) -> String? {
        if boundProjectIds.contains(projectId) { return projectId }
        if boundProjectIds.contains("inbox"), projectId.hasPrefix("inbox") { return "inbox" }
        return nil
    }

    /// Undone tasks, grouped in the user's chosen list order and sorted
    /// within each group by sortOrder ascending with taskId as the stable
    /// tiebreaker; rows without sortOrder go to their group's end. The same
    /// task appearing twice (a task moved between lists, an overlapping
    /// read) collapses to one row — the first occurrence in binding order.
    static func undoneGroups(rows: [TickTickTaskRow], boundProjectIds: [String]) -> [Group] {
        var seen = Set<String>()
        var byKey = Dictionary(boundProjectIds.map { ($0, [TickTickTaskRow]()) },
                               uniquingKeysWith: { first, _ in first })
        for row in rows {
            guard !row.isCompleted, !seen.contains(row.taskId),
                  let key = bindingKey(forTaskProjectId: row.projectId,
                                       boundProjectIds: boundProjectIds) else { continue }
            seen.insert(row.taskId)
            byKey[key, default: []].append(row)
        }
        return boundProjectIds.compactMap { key in
            guard var tasks = byKey[key], !tasks.isEmpty else { return nil }
            tasks.sort(by: taskOrder)
            return Group(projectKey: key, tasks: tasks)
        }
    }

    /// sortOrder ascending, taskId as the stable tiebreaker, a missing
    /// sortOrder last (proposal §5.4).
    private static func taskOrder(_ lhs: TickTickTaskRow, _ rhs: TickTickTaskRow) -> Bool {
        switch (lhs.sortOrder, rhs.sortOrder) {
        case (nil, nil): return lhs.taskId < rhs.taskId
        case (nil, _):   return false
        case (_, nil):   return true
        case (let l?, let r?):
            if l != r { return l < r }
            return lhs.taskId < rhs.taskId
        }
    }

    /// Completed tasks shown as "recently completed": newest first, taskId
    /// breaking exact ties, unknown completion times kept — they are never
    /// presumed stale (proposal §5.2) — but placed last. Only tasks
    /// completed inside the 24-hour window are shown; expiry removes them
    /// from display only, never from TickTick.
    static func recentCompletions(rows: [TickTickTaskRow], boundProjectIds: [String],
                                  now: Date = Date(),
                                  window: TimeInterval = 24 * 3600) -> [TickTickTaskRow] {
        rows.filter { row in
            guard row.isCompleted,
                  bindingKey(forTaskProjectId: row.projectId,
                             boundProjectIds: boundProjectIds) != nil else { return false }
            if let completed = row.completedTime {
                return now.timeIntervalSince(completed) <= window
            }
            return true
        }
        .sorted {
            switch ($0.completedTime, $1.completedTime) {
            case (nil, nil): return $0.taskId < $1.taskId
            case (nil, _):   return false
            case (_, nil):   return true
            case (let l?, let r?):
                if l != r { return l > r }
                return $0.taskId < $1.taskId
            }
        }
    }

    /// The name shown for a binding entry: the account's list name when the
    /// engine has one, the localized inbox name for the alias, nil until
    /// the first fetch supplies real names.
    static func displayName(forProjectKey key: String, names: [String: String],
                            inboxName: String) -> String? {
        if key == "inbox" { return names[key] ?? inboxName }
        return names[key]
    }

    /// The note's derived text snapshot (proposal §4.3): what search, the
    /// library preview, task progress and export see. Titles only — never a
    /// taskId, etag or request path (proposal §1). The caller resolves
    /// group names (with its fallback) and the recent heading's count.
    static func snapshotBody(header: String,
                             groups: [(name: String, tasks: [TickTickTaskRow])],
                             recentHeading: String,
                             recent: [TickTickTaskRow]) -> String {
        var lines = [header]
        for group in groups where !group.tasks.isEmpty {
            lines.append("")
            lines.append(group.name)
            lines.append(contentsOf: group.tasks.map { row in
                (row.isCompleted ? Tasks.donePrefix : Tasks.openPrefix) + row.title
            })
        }
        if !recent.isEmpty {
            lines.append("")
            lines.append(recentHeading)
            lines.append(contentsOf: recent.map { Tasks.donePrefix + $0.title })
        }
        return lines.joined(separator: "\n")
    }

    /// The feedback line for a pending completion (proposal §6.2): the
    /// active 30-second confirmation window reads as "confirming", after
    /// that as "result pending" — never as a failure.
    static func pendingFeedback(sentAt: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(sentAt) > 30
            ? L10n.text("ticktick.row.awaiting")
            : L10n.text("ticktick.row.confirming")
    }

    /// "滴答 · 收集箱 + 工作" — the brand plus the bound lists' known names
    /// in binding order; the bare brand until names arrive.
    static func headerTitle(for bound: [String], names: [String: String],
                            inboxName: String) -> String {
        let known = bound.compactMap {
            displayName(forProjectKey: $0, names: names, inboxName: inboxName)
        }
        let joined = known.joined(separator: " + ")
        return joined.isEmpty ? L10n.text("ticktick.brand")
                              : L10n.format("ticktick.note.header", joined)
    }

    /// The derived text snapshot (proposal §4.3) for one binding, from the
    /// merged task population. The engine and the per-note model both build
    /// their bodies here, so an engine refresh with no open view and a model
    /// refresh after a cache bump produce byte-identical bodies — the
    /// controlled writer then skips the no-op rewrite.
    static func noteBody(tasks: [TickTickTask], boundProjectIds: [String],
                         projectNames: [String: String], now: Date = Date(),
                         recentWindow: TimeInterval = 24 * 3600) -> String {
        let rows = tasks
            .filter { bindingKey(forTaskProjectId: $0.projectId,
                                 boundProjectIds: boundProjectIds) != nil }
            .map(TickTickTaskRow.init(task:))
        let groups = undoneGroups(rows: rows, boundProjectIds: boundProjectIds)
        let recent = recentCompletions(rows: rows, boundProjectIds: boundProjectIds,
                                       now: now, window: recentWindow)
        let inboxName = L10n.text("ticktick.inbox")
        let fallbackName = L10n.text("ticktick.project_fallback")
        return snapshotBody(
            header: headerTitle(for: boundProjectIds, names: projectNames, inboxName: inboxName),
            groups: groups.map { group in
                (name: displayName(forProjectKey: group.projectKey, names: projectNames,
                                   inboxName: inboxName) ?? fallbackName,
                 tasks: group.tasks)
            },
            recentHeading: L10n.format("ticktick.recent.section", recent.count),
            recent: recent)
    }
}

// MARK: - Recent-completions fold

/// The fold behaviour of the "recently completed" section (proposal §5.2:
/// collapsible and hideable). Kept as a value so the rules test without a
/// live view: `hidden` is the persisted user preference, `collapsed` the
/// per-session disclosure.
struct TickTickRecentFold: Equatable {
    var hidden = false
    var collapsed = false

    /// The header (with its collapse and hide controls) shows unless the
    /// whole section is hidden.
    var showsHeader: Bool { !hidden }
    /// Rows show only when the section is both shown and expanded.
    var showsRows: Bool { !hidden && !collapsed }

    mutating func toggleCollapsed() { collapsed.toggle() }
    mutating func setHidden(_ value: Bool) { hidden = value }
}

// MARK: - Sync phase

/// What a task note's title bar shows (proposal §7.3). The values and their
/// localized presentation only; the engine (next phase) drives transitions.
enum TickTickSyncPhase: Equatable {
    case idle
    case refreshing
    case updated(Date)
    case offline
    case unauthorized
    case forbidden
    case incomplete
    case misconfigured

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// The localized one-line status, e.g. "已更新 16:30".
    var localizedStatus: String {
        switch self {
        case .idle:          return L10n.text("ticktick.status.idle")
        case .refreshing:    return L10n.text("ticktick.status.refreshing")
        case .updated(let date):
            return L10n.format("ticktick.status.updated", Self.clock.string(from: date))
        case .offline:       return L10n.text("ticktick.status.offline")
        case .unauthorized:  return L10n.text("ticktick.status.unauthorized")
        case .forbidden:     return L10n.text("ticktick.status.forbidden")
        case .incomplete:    return L10n.text("ticktick.status.incomplete")
        case .misconfigured: return L10n.text("ticktick.status.misconfigured")
        }
    }
}

// MARK: - Row action policy

/// Whether the user may check a row off right now. Completion is a write to
/// TickTick, so every blocker is a reason that write must not leave: the
/// task's kind has no completion semantics, a repeating task's next instance
/// is unverified so it stays read-only (proposal §5.4), an earlier write is
/// still being confirmed, no engine is attached to carry the write, the note
/// never had a successful read (proposal §4.2), or the connection is in a
/// state that forbids writes (proposal §7.3).
enum TickTickRowActionPolicy {
    enum Blocker: Equatable {
        case noteKind
        case repeatedTask
        case pending
        case noEngine
        case neverLoaded
        case offline
        case unauthorized
        case forbidden
        case misconfigured

        /// The explanation shown as the row's help text and VoiceOver hint.
        var localizedHelp: String {
            switch self {
            case .noteKind:      return L10n.text("ticktick.row.note_kind_help")
            case .repeatedTask:  return L10n.text("ticktick.row.repeated_help")
            case .pending:       return L10n.text("ticktick.row.confirming")
            case .noEngine:      return L10n.text("ticktick.status.idle")
            case .neverLoaded:   return L10n.text("ticktick.row.waiting_help")
            case .offline:       return L10n.text("ticktick.row.offline_help")
            case .unauthorized:  return L10n.text("ticktick.status.unauthorized")
            case .forbidden:     return L10n.text("ticktick.status.forbidden")
            case .misconfigured: return L10n.text("ticktick.status.misconfigured")
            }
        }
    }

    static func blocker(for row: TickTickTaskRow,
                        pending: Bool,
                        engineAttached: Bool,
                        hasSnapshot: Bool,
                        phase: TickTickSyncPhase) -> Blocker? {
        if row.kind == "NOTE" { return .noteKind }
        if row.isRepeated { return .repeatedTask }
        if pending { return .pending }
        if !engineAttached { return .noEngine }
        if !hasSnapshot { return .neverLoaded }
        switch phase {
        case .offline:       return .offline
        case .unauthorized:  return .unauthorized
        case .forbidden:     return .forbidden
        case .misconfigured: return .misconfigured
        case .idle, .refreshing, .updated, .incomplete: return nil
        }
    }
}

// MARK: - Engine mount points

/// The sync engine's mount points (proposal §7.1, §6.1). The app-side hooks
/// — activation, wake, sleep, visibility, manual refresh, completion and
/// restore requests — call through TickTickPortal; the implementation
/// (scheduling, generations, pending persistence, confirmation) is
/// TickTickSyncEngine's.
protocol TickTickEngine: AnyObject {
    /// The app activated: merge into one immediate read (§7.1).
    func applicationDidActivate()
    /// The system left sleep: resume with one merged immediate read (§7.1).
    func applicationDidWake()
    /// The system is going to sleep: stop scheduled reads (§7.1).
    func systemWillSleep()
    /// The user asked for a refresh: one read, merged with any in-flight round.
    func refreshRequested()
    /// The user checked a task off: persist pending, POST, confirm (§6.1).
    func completeTask(taskId: String, noteID: String)
    /// The user unchecked a completed task: the verified restore path
    /// (contract report §2.2) through the same full state machine (§6.4).
    func uncompleteTask(taskId: String, noteID: String)
    /// A task list became visible: 展开便签 — one merged read, and the
    /// visible cadence applies (§7.1).
    func noteTaskViewDidAppear()
    /// The last task list went away: the hidden cadence applies (§7.1).
    func noteTaskViewDidDisappear()
    /// Credentials or the connection changed (settings connect/disconnect):
    /// bump the generation and re-evaluate everything (§6.3, §7.2).
    func credentialsDidChange()
}

/// App-wide TickTick surface: the phase every task note's title bar shows,
/// the account's list names, the cache version the engine bumps after every
/// successful merge, and the engine mount points. State and forwarding
/// only — no scheduling, network, or polling lives here (proposal §3); the
/// engine owns all of that.
final class TickTickPortal: ObservableObject {
    static let shared = TickTickPortal()

    @Published private(set) var phase: TickTickSyncPhase = .idle
    /// Real project ids to display names, from the account's GET /project.
    @Published private(set) var projectNames: [String: String] = [:]
    /// Bumped by the engine after each persisted merge; task-list models
    /// reload their rows from the encrypted cache when it moves.
    @Published private(set) var cacheVersion = 0
    /// The attached sync engine. Until one exists no completion can leave
    /// the app: task checkboxes stay disabled.
    @Published private(set) var engine: TickTickEngine?

    func attach(engine: TickTickEngine) {
        guard self.engine !== engine else { return }
        self.engine = engine
    }

    func detachEngine() { engine = nil }

    func setPhase(_ newPhase: TickTickSyncPhase) { phase = newPhase }
    func setProjectNames(_ names: [String: String]) { projectNames = names }
    func bumpCacheVersion() { cacheVersion += 1 }

    // MARK: Forwarded engine mount points

    /// 激活立即读 — AppDelegate's activation hook lands here.
    func applicationDidActivate() { engine?.applicationDidActivate() }
    /// 唤醒立即读 — the workspace wake hook lands here.
    func applicationDidWake() { engine?.applicationDidWake() }
    /// 睡眠停止 — the workspace sleep hook lands here.
    func systemWillSleep() { engine?.systemWillSleep() }
    /// Manual refresh, from a task note's title bar or the settings page.
    func refreshNow() { engine?.refreshRequested() }
    /// A completion request from a task row, addressed by taskId only.
    func completeTask(taskId: String, noteID: String) {
        engine?.completeTask(taskId: taskId, noteID: noteID)
    }
    /// A restore request from a completed row (§6.4, verified).
    func uncompleteTask(taskId: String, noteID: String) {
        engine?.uncompleteTask(taskId: taskId, noteID: noteID)
    }
    /// 展开便签 — a task list appeared; the engine merges one read (§7.1).
    func taskViewDidAppear() { engine?.noteTaskViewDidAppear() }
    func taskViewDidDisappear() { engine?.noteTaskViewDidDisappear() }
    /// Connection or credentials changed (settings connect/disconnect).
    func engineCredentialsDidChange() { engine?.credentialsDidChange() }
}

// MARK: - Display routing

/// Which surface a note opens on (proposal §2.2): task notes render the
/// task list; plain notes keep the text editor. The same predicate family
/// closes the text-editing bypasses — the task-marker shortcut and capture
/// append targets.
enum TickTickDisplayRouting {
    enum Surface { case textEditor, taskList }

    static func surface(for note: Note) -> Surface {
        note.source == .ticktick ? .taskList : .textEditor
    }

    /// The in-note task-marker shortcut edits body text, so it is inert on
    /// task notes (proposal §2.2).
    static func allowsTaskLineToggle(_ note: Note) -> Bool {
        note.source != .ticktick
    }

    /// Quick-capture append targets are plain notes only (proposal §2.2).
    static func isCaptureTarget(_ note: Note) -> Bool {
        note.source != .ticktick
    }
}

// MARK: - Task-note creation (proposal §8.3)

/// Creates a task note the way the sync design demands: nothing becomes
/// visible until it is durable. The bindings file is written first, the
/// SQLite row (with `source` already ticktick) second, the shared notes
/// collection last — so a failure at any step leaves either nothing at all,
/// or a fully protected task note; never a source=local task snapshot.
enum TickTickTaskCreation {
    /// The failure the settings page reports. Nothing is created when any
    /// of these is returned.
    enum Failure: Error, Equatable {
        case emptySelection
        case invalidSelection
        /// The bindings file is in the config-error state — never written
        /// on top of (proposal §4.2).
        case bindingsUnavailable
        case bindingSaveFailed
        case noteSaveFailed

        var localizedDescription: String {
            switch self {
            case .emptySelection, .invalidSelection:
                return L10n.text("ticktick.settings.selection_empty")
            case .bindingsUnavailable:
                return L10n.text("ticktick.status.misconfigured")
            case .bindingSaveFailed:
                return L10n.text("ticktick.create.binding_save_failed")
            case .noteSaveFailed:
                return L10n.text("ticktick.create.note_save_failed")
            }
        }
    }

    /// Creates and publishes one task note bound to `projectIds`, in that
    /// order (the order becomes the group order, proposal §5.4).
    static func createTaskNote(projectIds: [String],
                               noteStore: NoteStore,
                               bindingsStore: TickTickBindingsStore = TickTickBindingsStore()) -> Result<Note, Failure> {
        guard !projectIds.isEmpty else { return .failure(.emptySelection) }
        guard Set(projectIds).count == projectIds.count,
              !projectIds.contains(where: \.isEmpty) else { return .failure(.invalidSelection) }

        // A bindings file that failed strict loading is a configuration
        // error, not an empty state — creation refuses rather than write on
        // top of it.
        let existing: [TickTickBinding]
        switch bindingsStore.load(notes: noteStore.notes) {
        case .absent:              existing = []
        case .loaded(let bindings): existing = bindings
        case .invalid:             return .failure(.bindingsUnavailable)
        }

        var note = Note()
        note.source = .ticktick
        note.order = (noteStore.active.map(\.order).min() ?? 0) - 1   // newest sits at the top of the deck
        note.color = noteStore.notes.count % NoteColor.all.count
        let binding = TickTickBinding(noteId: note.id, projectIds: projectIds)

        // 1. Binding first — it may reference a note that has no row yet,
        //    because the note is published only after both writes succeed.
        do { try bindingsStore.save(existing + [binding]) }
        catch { return .failure(.bindingSaveFailed) }

        // 2. Row second, with `source` durable before anything can see it.
        guard noteStore.persistUnpublished(note) else {
            // Roll the binding back so the file does not dangle after a note
            // that was never written. Should the rollback itself fail, the
            // strict loader keeps reporting the dangling binding as a
            // configuration error — a protected state, never a plain note.
            try? bindingsStore.save(existing)
            return .failure(.noteSaveFailed)
        }

        // 3. Only now does the note exist for the deck and CloudSync.
        noteStore.publishPersisted(note)
        return .success(note)
    }
}

// MARK: - Settings validation

/// The checks behind the settings page's connect/create buttons, as pure
/// functions so the gating itself is regression-tested.
enum TickTickSettingsValidation {
    /// A pasted token must be non-empty after trimming; anything more
    /// specific would guess at TickTick's token shape.
    static func isValidToken(_ token: String) -> Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The selection a task note can be created from: at least one list,
    /// no duplicates, no empty entries.
    static func isValidSelection(_ projectIds: [String]) -> Bool {
        !projectIds.isEmpty
            && Set(projectIds).count == projectIds.count
            && !projectIds.contains(where: \.isEmpty)
    }

    /// The binding order for a new note (proposal §5.4): the inbox alias
    /// leads when selected, then the fetched lists in the account's order —
    /// the order the task list will group by.
    static func selectionOrder(selected: Set<String>, fetchedOrder: [TickTickProject]) -> [String] {
        var ordered: [String] = []
        if selected.contains("inbox") { ordered.append("inbox") }
        ordered.append(contentsOf: fetchedOrder.map(\.id).filter { selected.contains($0) })
        return ordered
    }
}

// MARK: - Per-note view model

/// The data one task note's list renders: rows from the encrypted task
/// cache filtered to this note's binding; pending operations read back —
/// never replayed (proposal §4.2); and the derived body snapshot pushed
/// through NoteStore's sanctioned writer (§4.3). Reads happen at init and
/// after every cache-version bump the engine publishes; the merge, pending
/// state and confirmation are the engine's.
final class TickTickTaskNoteModel: ObservableObject {
    let noteID: String

    /// This note's binding, when one resolves. A bindings file that fails
    /// strict loading leaves this nil and flags the note misconfigured —
    /// the snapshot still shows, writes stay blocked (proposal §4.1).
    @Published private(set) var binding: TickTickBinding?
    @Published private(set) var configInvalid = false
    @Published private(set) var rows: [TickTickTaskRow] = []
    /// Pending writes by taskId — shared task state (proposal §4.2): every
    /// note showing the task sees the operation, the engine deduplicates
    /// them, and here they only disable and annotate rows.
    @Published private(set) var pending: [String: Date] = [:]
    var pendingTaskIDs: Set<String> { Set(pending.keys) }
    /// True once a cache snapshot exists — Note.body alone is the fallback
    /// display before the first successful read (proposal §4.2).
    @Published private(set) var hasSnapshot = false
    @Published private(set) var projectNames: [String: String] = [:]
    @Published private(set) var phase: TickTickSyncPhase = .idle
    @Published private(set) var engineAttached = false
    @Published private(set) var inaccessibleCount = 0
    @Published var recentFold = TickTickRecentFold()

    private let cache: TickTickTaskCache
    private let noteStore: NoteStore
    private let portal: TickTickPortal
    /// The cache's tasks that belong to this note's binding — the raw
    /// population the rows and the derived body both render from.
    private var boundTasks: [TickTickTask] = []
    private var bag = Set<AnyCancellable>()

    init(noteID: String,
         cache: TickTickTaskCache = TickTickTaskCache(),
         bindingsStore: TickTickBindingsStore = TickTickBindingsStore(),
         noteStore: NoteStore = .shared,
         portal: TickTickPortal = .shared,
         recentCompletionsHidden: Bool = Settings.ticktickRecentCompletionsHidden) {
        self.noteID = noteID
        self.cache = cache
        self.noteStore = noteStore
        self.portal = portal

        recentFold.hidden = recentCompletionsHidden

        // The binding for this note, or the config-error flag.
        switch bindingsStore.load(notes: noteStore.notes) {
        case .loaded(let bindings):
            binding = bindings.first { $0.noteId == noteID }
        case .absent:
            binding = nil
        case .invalid:
            binding = nil
            configInvalid = true
        }

        // Names and connection state start from the portal's current values
        // (the sinks re-emit them) and follow it from here on.
        portal.$projectNames
            .sink { [weak self] names in
                guard let self, self.projectNames != names else { return }
                self.projectNames = names
                self.refreshSnapshotBody()
            }
            .store(in: &bag)
        portal.$phase
            .sink { [weak self] phase in self?.phase = phase }
            .store(in: &bag)
        portal.$engine
            .sink { [weak self] engine in self?.engineAttached = engine != nil }
            .store(in: &bag)
        // The engine bumps the version after every persisted merge: rows,
        // pending feedback and the inaccessible summary follow the cache.
        portal.$cacheVersion
            .sink { [weak self] _ in self?.reloadFromCache() }
            .store(in: &bag)

        reloadFromCache()
    }

    /// The phase a row or the title bar should display: a broken local
    /// configuration outranks whatever the connection last reported.
    var displayPhase: TickTickSyncPhase {
        configInvalid ? .misconfigured : phase
    }

    /// Rebuilds rows and the derived snapshot from the encrypted cache. A
    /// missing cache is the legitimate pre-first-read state; a cache that
    /// cannot be decrypted or parsed flags the note misconfigured instead
    /// of silently emptying it (proposal §4.2).
    func reloadFromCache() {
        do {
            guard let snapshot = try cache.load() else {
                hasSnapshot = false
                rows = []
                pending = [:]
                inaccessibleCount = 0
                return
            }
            hasSnapshot = true
            let bound = binding?.projectIds ?? []
            boundTasks = snapshot.tasks
                .filter { TickTickTaskListLayout.bindingKey(forTaskProjectId: $0.projectId,
                                                            boundProjectIds: bound) != nil }
            rows = boundTasks.map(TickTickTaskRow.init(task:))
            let rowIDs = Set(rows.map(\.taskId))
            pending = Dictionary(
                snapshot.pending.filter { rowIDs.contains($0.taskId) }
                    .map { ($0.taskId, $0.sentAt) },
                uniquingKeysWith: { _, latest in latest })
            inaccessibleCount = (snapshot.inaccessible ?? [])
                .filter { entry in
                    TickTickTaskListLayout.bindingKey(forTaskProjectId: entry.projectId,
                                                      boundProjectIds: bound) != nil
                }
                .count
            refreshSnapshotBody()
        } catch {
            configInvalid = true
            hasSnapshot = false
        }
    }

    /// Whether this row may be checked off, and why not.
    func blocker(for row: TickTickTaskRow) -> TickTickRowActionPolicy.Blocker? {
        TickTickRowActionPolicy.blocker(for: row,
                                        pending: pending[row.taskId] != nil,
                                        engineAttached: engineAttached,
                                        hasSnapshot: hasSnapshot,
                                        phase: displayPhase)
    }

    /// A completion request from the row's checkbox or Space key —
    /// addressed by taskId, routed to the engine, and simply refused
    /// (silently) while no engine is attached.
    func complete(taskId: String) {
        guard binding != nil else { return }
        portal.completeTask(taskId: taskId, noteID: noteID)
    }

    /// A restore request from a completed row's checkbox (proposal §6.4,
    /// verified by the contract report) — the same routing and guards.
    func uncomplete(taskId: String) {
        guard binding != nil else { return }
        portal.uncompleteTask(taskId: taskId, noteID: noteID)
    }

    /// The manual refresh affordance (proposal §7.3): one read request,
    /// merged by the engine with anything already in flight.
    func refreshNow() {
        portal.refreshNow()
    }

    /// 展开便签 (proposal §7.1): report visibility so the cadence changes
    /// and one merged read fires.
    func viewDidAppear() { portal.taskViewDidAppear() }
    func viewDidDisappear() { portal.taskViewDidDisappear() }

    /// The per-session disclosure of the recent-completions section.
    func toggleRecentCollapsed() {
        recentFold.toggleCollapsed()
    }

    /// The persisted hide preference for the recent-completions section.
    func setRecentHidden(_ hidden: Bool) {
        recentFold.setHidden(hidden)
        Settings.ticktickRecentCompletionsHidden = hidden
    }

    /// Pushes the derived text snapshot (proposal §4.3) through the
    /// controlled writer: identical bodies do not rewrite the row, and the
    /// note's own title, colour, order and pin are never touched. The same
    /// pure layout the engine uses, so both writers agree byte for byte.
    private func refreshSnapshotBody() {
        guard let binding, hasSnapshot else { return }
        let body = TickTickTaskListLayout.noteBody(tasks: boundTasks,
                                                    boundProjectIds: binding.projectIds,
                                                    projectNames: projectNames)
        noteStore.updateSnapshotBody(id: noteID, body: body)
    }
}

// MARK: - Task list view

/// The task note's body: real controls addressed by taskId (proposal §3) —
/// no text is ever rewritten to complete a task. Undone tasks group by
/// list, the foldable recently-completed section sits at the bottom, and
/// the note's own body snapshot stands in until the first successful read
/// (proposal §4.2).
struct TickTickTaskListView: View {
    let noteID: String
    var fontSize: CGFloat = Settings.noteFontSize

    @StateObject private var model: TickTickTaskNoteModel
    @ObservedObject private var store = NoteStore.shared

    init(noteID: String, fontSize: CGFloat? = nil) {
        self.noteID = noteID
        if let fontSize { self.fontSize = fontSize }
        _model = StateObject(wrappedValue: TickTickTaskNoteModel(noteID: noteID))
    }

    private var note: Note? { store.note(id: noteID) }
    private var pal: NoteColor { note?.palette ?? NoteColor.at(0) }
    private var boundProjectIds: [String] { model.binding?.projectIds ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Rectangle()
                .fill(pal.ink.opacity(0.10))
                .frame(height: 1)
            if model.hasSnapshot {
                taskScroll
            } else {
                snapshotFallback
            }
        }
        // 展开便签 (proposal §7.1): every surface that renders the list reports
        // itself — the engine merges one immediate read and switches cadence.
        .onAppear { model.viewDidAppear() }
        .onDisappear { model.viewDidDisappear() }
    }

    /// The note's own status line (proposal §7.3) plus the manual refresh
    /// affordance. Kept independent of Note.title so it never writes the
    /// database on its way to an update.
    private var statusHeader: some View {
        HStack(spacing: 8) {
            Text(model.displayPhase.localizedStatus)
                .font(Ink.bodyFont(10))
                .foregroundStyle(pal.ink.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Ink.bodyFont(10).weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.45))
            .help(L10n.text("ticktick.status.refresh"))
            .accessibilityLabel(L10n.text("ticktick.status.refresh"))
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var taskScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let groups = TickTickTaskListLayout.undoneGroups(rows: model.rows,
                                                                  boundProjectIds: boundProjectIds)
                let recent = TickTickTaskListLayout.recentCompletions(rows: model.rows,
                                                                      boundProjectIds: boundProjectIds)
                if groups.isEmpty && recent.isEmpty && model.inaccessibleCount == 0 {
                    Text(L10n.text("ticktick.note.empty"))
                        .font(Ink.bodyFont(12))
                        .foregroundStyle(pal.ink.opacity(0.5))
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let inboxName = L10n.text("ticktick.inbox")
                let fallbackName = L10n.text("ticktick.project_fallback")
                ForEach(groups, id: \.projectKey) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(TickTickTaskListLayout.displayName(forProjectKey: group.projectKey,
                                                                names: model.projectNames,
                                                                inboxName: inboxName) ?? fallbackName)
                            .font(Ink.bodyFont(10.5).weight(.semibold))
                            .foregroundStyle(pal.ink.opacity(0.55))
                            .padding(.horizontal, 12)
                        ForEach(group.tasks) { row in
                            TickTickTaskRowView(
                                row: row, pal: pal, fontSize: fontSize,
                                blocker: model.blocker(for: row),
                                pendingFeedback: model.pending[row.taskId].map {
                                    TickTickTaskListLayout.pendingFeedback(sentAt: $0)
                                },
                                onComplete: { model.complete(taskId: $0) })
                        }
                    }
                }
                recentSection(recent)
                inaccessibleFootnote
            }
            .padding(.vertical, 8)
        }
    }

    /// The quiet explanation for tasks that left the display after two
    /// independent confirmations of absence (proposal §5.3.5): removed as
    /// no longer accessible, never claimed deleted.
    @ViewBuilder
    private var inaccessibleFootnote: some View {
        if model.inaccessibleCount > 0 {
            Text(L10n.format("ticktick.inaccessible.section", model.inaccessibleCount))
                .font(Ink.bodyFont(10))
                .foregroundStyle(pal.ink.opacity(0.40))
                .padding(.horizontal, 12)
                .padding(.top, 2)
        }
    }

    /// The bottom "近期完成" section (proposal §5.2): collapsible from its
    /// header, hideable from its eye button, restorable from the quiet row
    /// left behind when hidden.
    @ViewBuilder
    private func recentSection(_ recent: [TickTickTaskRow]) -> some View {
        if model.recentFold.showsHeader {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        model.toggleRecentCollapsed()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.recentFold.collapsed ? "chevron.right" : "chevron.down")
                                .font(Ink.bodyFont(9).weight(.bold))
                            Text(L10n.format("ticktick.recent.section", recent.count))
                                .font(Ink.bodyFont(10.5).weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(pal.ink.opacity(0.55))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.format("ticktick.recent.accessibility", recent.count))
                    Spacer(minLength: 6)
                    Button {
                        model.setRecentHidden(true)
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(Ink.bodyFont(10))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pal.ink.opacity(0.40))
                    .help(L10n.text("ticktick.recent.hide"))
                    .accessibilityLabel(L10n.text("ticktick.recent.hide"))
                }
                .padding(.horizontal, 12)
                if model.recentFold.showsRows {
                    ForEach(recent) { row in
                        TickTickRecentRowView(
                            row: row, pal: pal, fontSize: fontSize,
                            blocker: model.blocker(for: row),
                            pendingFeedback: model.pending[row.taskId].map {
                                TickTickTaskListLayout.pendingFeedback(sentAt: $0)
                            },
                            onUncomplete: { model.uncomplete(taskId: $0) })
                    }
                }
            }
            .padding(.top, 2)
        } else {
            Button {
                model.setRecentHidden(false)
            } label: {
                Label(L10n.text("ticktick.recent.show"), systemImage: "eye")
                    .font(Ink.bodyFont(10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.40))
            .padding(.horizontal, 12)
            .accessibilityLabel(L10n.text("ticktick.recent.show"))
        }
    }

    /// Before the first successful read the note's own body is the display
    /// (proposal §4.2): read-only, no toggles.
    private var snapshotFallback: some View {
        ScrollView {
            Text(note?.body ?? "")
                .font(Ink.bodyFont(fontSize))
                .foregroundStyle(pal.ink.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

/// One undone task row: a real Toggle whose change requests the completion
/// through taskId (proposal §3, §6.1). The title wraps, is selectable, and
/// can be copied from its context menu; the row takes keyboard focus and
/// Space acts as the click (proposal §3).
private struct TickTickTaskRowView: View {
    let row: TickTickTaskRow
    let pal: NoteColor
    let fontSize: CGFloat
    let blocker: TickTickRowActionPolicy.Blocker?
    let pendingFeedback: String?
    let onComplete: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Toggle("", isOn: Binding(
                get: { row.isCompleted },
                set: { newValue in
                    // Only completing is wired here; restoring a completed
                    // task is the recent row's own reverse control (§6.4).
                    if newValue { onComplete(row.taskId) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(blocker != nil)
                .help(blocker?.localizedHelp ?? L10n.text("ticktick.row.complete_help"))
                .accessibilityLabel(L10n.format("ticktick.row.accessibility", row.title))
                .accessibilityHint(blocker?.localizedHelp ?? L10n.text("ticktick.row.complete_help"))
            Text(row.title)
                .font(Ink.bodyFont(fontSize))
                .foregroundStyle(pal.ink.opacity(row.kind == "NOTE" ? 0.55 : 0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contextMenu {
                    Button(L10n.text("ticktick.row.copy_title")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.title, forType: .string)
                    }
                }
            if let pendingFeedback {
                Text(pendingFeedback)
                    .font(Ink.bodyFont(9.5))
                    .foregroundStyle(pal.ink.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .focusable(true)
        .onKeyPress(.space) {
            guard blocker == nil, !row.isCompleted else { return .ignored }
            onComplete(row.taskId)
            return .handled
        }
    }
}

/// One recently completed row: a real checkbox whose un-checking requests the
/// restore through taskId (proposal §6.4, verified by the contract report) —
/// the same pending-then-read-back machine as completing. The title wraps and
/// is selectable and copyable; the row takes keyboard focus and Space acts as
/// the un-check.
private struct TickTickRecentRowView: View {
    let row: TickTickTaskRow
    let pal: NoteColor
    let fontSize: CGFloat
    let blocker: TickTickRowActionPolicy.Blocker?
    let pendingFeedback: String?
    let onUncomplete: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Toggle("", isOn: Binding(
                get: { true },
                set: { newValue in
                    if !newValue { onUncomplete(row.taskId) }
                }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(blocker != nil)
                .help(blocker?.localizedHelp ?? L10n.text("ticktick.row.uncomplete_help"))
                .accessibilityLabel(L10n.format("ticktick.recent.row_accessibility", row.title))
                .accessibilityHint(blocker?.localizedHelp ?? L10n.text("ticktick.row.uncomplete_help"))
            Text(row.title)
                .font(Ink.bodyFont(fontSize - 0.5))
                .strikethrough()
                .foregroundStyle(pal.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contextMenu {
                    Button(L10n.text("ticktick.row.copy_title")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.title, forType: .string)
                    }
                }
            if let pendingFeedback {
                Text(pendingFeedback)
                    .font(Ink.bodyFont(9.5))
                    .foregroundStyle(pal.ink.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .focusable(true)
        .onKeyPress(.space) {
            guard blocker == nil else { return .ignored }
            onUncomplete(row.taskId)
            return .handled
        }
        .accessibilityElement(children: .combine)
    }
}
