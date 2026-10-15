import Combine
import Foundation

// MARK: - Quarantine persistence (proposal §8.5)

/// The quarantine list as it lives on disk: note ids whose cloud object is
/// paused. Persisted beside the sync index so a quarantine survives a
/// restart — the local task note that justified it may be long gone by then
/// (deleted, undo window closed, binding pruned), and without the file the
/// leftover cloud copy would look like a plain stale file again and get
/// pulled or deleted. Append-only by design: entries are never pruned
/// automatically, because "the file is gone now" is not evidence that the
/// person wants the identity unprotected.
struct CloudSyncQuarantine: Codable {
    /// The only shape this build writes and reads.
    static let currentVersion = 1
    static let defaultURL = Paths.support.appendingPathComponent("cloud-quarantine.json")

    var version = CloudSyncQuarantine.currentVersion
    var pausedNoteIDs: Set<String> = []

    /// Lenient like the index: a missing file is an empty quarantine, and an
    /// unreadable one starts empty rather than blocking sync — the pass that
    /// re-encounters a claiming file re-quarantines it and rewrites the file.
    static func load(from url: URL = CloudSyncQuarantine.defaultURL) -> CloudSyncQuarantine {
        guard let data = try? Data(contentsOf: url),
              let quarantine = try? Self.decoder.decode(CloudSyncQuarantine.self, from: data),
              quarantine.version == currentVersion else {
            return CloudSyncQuarantine()
        }
        return quarantine
    }

    func save(to url: URL = CloudSyncQuarantine.defaultURL) {
        do {
            try Self.encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            NSLog("Noty cloud: cannot save the quarantine list — \(error.localizedDescription)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = JSONDecoder()
}

/// Runs sync passes against the iCloud Drive folder.
///
/// Main thread only in production. It mutates NoteStore, which every deck,
/// window and editor observes, and a pass is a few dozen small file reads — a
/// background queue would cost more in synchronisation than it could save.
/// (The test binary drives it directly with no run loop, so this is a
/// convention, not a precondition.)
final class CloudSync {
    static let shared = CloudSync(folder: CloudFolderGateway(), store: NoteStore.shared)

    private(set) var lastSync: Date?

    private let folder: SyncFolderGateway
    private let store: NoteStoring
    private var index: CloudSyncIndex
    private let indexURL: URL
    private var isRunning = false
    /// Notes parsed during the scan, so performing an action never re-parses a
    /// document that was already parsed this pass.
    private var scanned: [String: Note] = [:]
    /// Lowercased file names already spoken for this pass — everything the
    /// folder held when the pass began, plus everything written since. Built
    /// from the index alone, this missed every name on a first sync and let two
    /// notes overwrite each other.
    private var claimed: Set<String> = []
    /// Identities this pass protects (proposal §8): every task note, plus the
    /// quarantined leftovers of earlier passes. Set at the top of the pass and
    /// re-checked before every action is performed.
    private var protectedIDs: Set<String> = []

    /// Identities whose cloud object is quarantined (proposal §8.5): a file
    /// that claims a task note's identity is never pulled, pushed or deleted —
    /// the object's cloud sync is paused and reported, and the file stays for
    /// the person to remove by hand. The quarantine survives passes where the
    /// local note no longer backs it, and restarts: it is loaded from and
    /// saved to disk beside the index.
    private(set) var pausedNoteIDs: Set<String> = []
    /// Where the quarantine list persists.
    private let pausedURL: URL

    init(folder: SyncFolderGateway, store: NoteStoring,
         indexURL: URL = CloudSyncIndex.defaultURL,
         pausedURL: URL = CloudSyncQuarantine.defaultURL) {
        self.folder = folder
        self.store = store
        self.indexURL = indexURL
        self.pausedURL = pausedURL
        self.index = CloudSyncIndex.load(from: indexURL)
        // A restart must not forget a paused identity (proposal §8.5): the
        // leftover cloud file behind it would otherwise be planned against
        // like any plain stale file.
        self.pausedNoteIDs = CloudSyncQuarantine.load(from: pausedURL).pausedNoteIDs
    }

    /// One pass. Returns false when there was nothing it could do.
    @discardableResult
    func syncNow() -> Bool {
        guard Settings.cloudSyncEnabled, !isRunning else { return false }
        // Every deletion below is gated on this. With no folder, every file looks
        // deleted and the pass would empty the deck.
        guard folder.isAvailable, folder.ensureFolder() else {
            NSLog("Noty cloud: iCloud Drive is unavailable — skipping this pass")
            return false
        }

        isRunning = true
        defer { isRunning = false; scanned.removeAll(); claimed.removeAll() }

        // Task notes are local-only displays (proposal §8): this pass neither
        // plans nor performs anything for them, and cloud leftovers claiming
        // their ids are quarantined, never deleted.
        let taskNoteIDs = Set(store.notes.filter { $0.source == .ticktick }.map(\.id))
        protectedIDs = taskNoteIDs.union(pausedNoteIDs)

        let scan = folder.scan()
        claimed = Set(scan.allNames.map { $0.lowercased() })
        let remote = remoteFiles(from: scan)
        // A document that was listed but could not be read is still *there*.
        // Folding it in here is what stops it looking like a deletion.
        let seen = Set(remote.map(\.fileName))
        let unresolved = scan.unresolved.union(scan.documents.keys.filter { !seen.contains($0) })

        quarantineLeftovers(remote: remote, allNames: scan.allNames)
        protectedIDs = taskNoteIDs.union(pausedNoteIDs)

        var changed = false
        for action in SyncPlan.actions(notes: store.notes, remote: remote,
                                       unresolved: unresolved, index: index,
                                       pausedNoteIDs: pausedNoteIDs) {
            perform(action)
            changed = true
        }
        if changed { index.save(to: indexURL) }
        lastSync = Date()
        return true
    }

    /// Cloud files that claim a protected identity (proposal §8.5): an older
    /// build or a hand-made copy can leave a document in the folder carrying a
    /// task note's id. Such an object's sync is paused and reported — the file
    /// is never deleted, never adopted, never re-created as a note.
    private func quarantineLeftovers(remote: [SyncPlan.RemoteFile], allNames: Set<String>) {
        var claimedIDs = Set(remote.compactMap(\.noteID))
        for (id, entry) in index.entries where allNames.contains(entry.fileName) {
            claimedIDs.insert(id)
        }
        let newlyPaused = claimedIDs.intersection(protectedIDs).subtracting(pausedNoteIDs)
        guard !newlyPaused.isEmpty else { return }
        pausedNoteIDs.formUnion(newlyPaused)
        // Durable the moment it happens: a crash right after this pass must
        // not un-quarantine what the person was just told is paused.
        var durable = CloudSyncQuarantine()
        durable.pausedNoteIDs = pausedNoteIDs
        durable.save(to: pausedURL)
        for id in newlyPaused.sorted() {
            NSLog("Noty cloud: a folder document claims task note \(id)'s identity — "
                  + "its cloud sync is paused; the file is left for manual removal")
        }
    }

    /// Builds the planner's view of the folder, reading only what moved. A file
    /// whose date matches what the index recorded is described from the index,
    /// which is what keeps a quiet pass down to one directory listing.
    private func remoteFiles(from scan: FolderScan) -> [SyncPlan.RemoteFile] {
        var out: [SyncPlan.RemoteFile] = []
        for (name, fileModified) in scan.documents.sorted(by: { $0.key < $1.key }) {
            if let id = index.id(forFileName: name),
               let entry = index.entries[id], entry.fileModified == fileModified {
                out.append(SyncPlan.RemoteFile(fileName: name, noteID: id,
                                               declaredModified: entry.syncedModified,
                                               fileModified: fileModified))
                continue
            }
            guard let text = folder.read(name) else {
                // Listed a moment ago, unreadable now. Say nothing about it —
                // `syncNow` folds this name into the unresolved set below.
                continue
            }
            let parsed = NoteDocument.parse(
                text, fallbackTitle: (name as NSString).deletingPathExtension)
            scanned[name] = parsed.note
            out.append(SyncPlan.RemoteFile(
                fileName: name,
                noteID: parsed.hasIdentity ? parsed.note.id : nil,
                declaredModified: parsed.hasIdentity ? parsed.note.modified : .distantPast,
                fileModified: fileModified))
        }
        return out
    }

    // MARK: Performing

    /// Performs one action. Internal so the execution-side protection is
    /// directly testable. Every branch re-checks the protected identity
    /// before touching anything (proposal §8.2): the plan already excludes
    /// task notes, but the runner does not trust the plan — a note may have
    /// changed source, or a caller may have passed a plan from another pass.
    func perform(_ action: SyncPlan.Action) {
        switch action {
        case .push(let id, let existing):
            guard !protectedIDs.contains(id), !isTaskNote(id) else { return }
            push(noteID: id, existingFileName: existing)
        case .pull(let name):
            // The incoming document's identity decides: absorbing over a task
            // note would let a cloud file rewrite a read-only snapshot.
            if let incoming = scanned[name], isTaskNote(incoming.id) { return }
            if let id = index.id(forFileName: name), protectedIDs.contains(id) { return }
            pull(fileName: name)
        case .reindex(let id, let name):
            guard let note = store.note(id: id),
                  let fileModified = folder.modificationDate(of: name) else { return }
            index.record(noteID: id, fileName: name,
                         noteModified: note.modified, fileModified: fileModified)
        case .adopt(let name):
            adopt(fileName: name)
        case .deleteLocal(let id):
            guard !protectedIDs.contains(id), !isTaskNote(id) else { return }
            store.delete(id: id)          // keeps the existing ten-second undo
            index.forget(noteID: id)
        case .deleteRemote(let name):
            if let id = index.id(forFileName: name), protectedIDs.contains(id) || isTaskNote(id) {
                return
            }
            folder.remove(name)
            if let id = index.id(forFileName: name) { index.forget(noteID: id) }
        case .conflict(let id, let name, let localWins):
            guard !protectedIDs.contains(id), !isTaskNote(id) else { return }
            resolve(noteID: id, fileName: name, localWins: localWins)
        }
    }

    /// Whether the note behind `id` — when one exists — is a protected task
    /// note. A missing note is judged by the pass's protected set alone.
    private func isTaskNote(_ id: String) -> Bool {
        store.note(id: id)?.source == .ticktick
    }

    private func push(noteID: String, existingFileName: String?) {
        guard let note = store.note(id: noteID) else { return }
        let indexed = index.entries[noteID]?.fileName

        let name: String
        if let existing = existingFileName, existing != indexed {
            // Renamed on another device. Their name wins — deriving our own here
            // would recreate the old file beside theirs.
            name = existing
        } else {
            var taken = claimed
            if let existing = existingFileName { taken.remove(existing.lowercased()) }
            if let indexed { taken.remove(indexed.lowercased()) }
            name = CloudFolder.fileName(for: note, avoiding: taken)
        }
        claimed.insert(name.lowercased())

        guard folder.write(NoteDocument.render(note), named: name) else { return }

        // Remove the document this pass actually saw, not the one the index
        // remembers — that is the difference between a rename and a duplicate.
        if let obsolete = existingFileName ?? indexed, obsolete != name {
            folder.remove(obsolete)
            claimed.remove(obsolete.lowercased())
        }
        index.record(noteID: noteID, fileName: name,
                     noteModified: note.modified,
                     fileModified: folder.modificationDate(of: name) ?? Date())
    }

    private func pull(fileName: String) {
        guard var incoming = scanned[fileName],
              let fileModified = folder.modificationDate(of: fileName) else { return }
        // A foreign editor leaves the header's date stale, so take the later of
        // the two or the deck would show a time from before the edit.
        incoming.modified = max(incoming.modified, fileModified)
        store.absorb(incoming)
        index.record(noteID: incoming.id, fileName: fileName,
                     noteModified: incoming.modified, fileModified: fileModified)
    }

    private func adopt(fileName: String) {
        guard var incoming = scanned[fileName] ?? (folder.read(fileName).map {
            NoteDocument.parse($0, fallbackTitle: (fileName as NSString).deletingPathExtension).note
        }),
              let fileModified = folder.modificationDate(of: fileName) else { return }
        incoming.id = UUID().uuidString
        incoming.created = fileModified
        incoming.modified = fileModified
        incoming.order = (store.active.map(\.order).min() ?? 0) - 1
        incoming.color = abs(fileName.hashValue) % NoteColor.all.count
        store.absorb(incoming)

        // Write it back so it carries an identity from now on. Keep the filename
        // the person chose on their phone.
        guard folder.write(NoteDocument.render(incoming), named: fileName) else { return }
        index.record(noteID: incoming.id, fileName: fileName,
                     noteModified: incoming.modified,
                     fileModified: folder.modificationDate(of: fileName) ?? fileModified)
    }

    // MARK: Conflicts

    /// The version that lost, as a plain document with **no** front-matter. With
    /// no identity it can never sync back and can never become a second note —
    /// it sits in the folder to be read in the Files app and deleted by hand.
    static func conflictDocument(for note: Note) -> String {
        "# " + note.displayTitle + "\n\n" + Tasks.toMarkdown(note.body)
    }

    private func resolve(noteID: String, fileName: String, localWins: Bool) {
        guard let remoteNote = scanned[fileName],
              let localNote = store.note(id: noteID) else { return }

        let loser = localWins ? remoteNote : localNote
        folder.writeConflict(Self.conflictDocument(for: loser), named: fileName)
        NSLog("Noty cloud: conflict on \(fileName) — kept a copy in \(CloudFolder.conflictsFolderName)")

        if localWins {
            push(noteID: noteID, existingFileName: fileName)
        } else {
            pull(fileName: fileName)
        }
    }

    // MARK: Scheduling

    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var pending: DispatchWorkItem?

    /// Start or stop according to the preference. Safe to call repeatedly.
    func reload() {
        Settings.cloudSyncEnabled ? start() : stop()
    }

    private func start() {
        guard timer == nil else { return }
        // A note changed here: write it out, but not on every keystroke — the
        // editor autosaves 250 ms after typing stops and each save republishes.
        NoteStore.shared.$notes
            .sink { [weak self] _ in self?.scheduleLocalPush() }
            .store(in: &bag)

        timer = Timer.scheduledTimer(withTimeInterval: Settings.cloudSyncInterval,
                                     repeats: true) { [weak self] _ in
            self?.syncNow()
        }
        syncNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pending?.cancel()
        pending = nil
        bag.removeAll()
    }

    /// `$notes` fires while a pass is applying its own pulls; ignoring those is
    /// what keeps a sync from feeding itself.
    private func scheduleLocalPush() {
        guard !isRunning else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
