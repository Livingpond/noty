import Foundation

// MARK: - Binding model

/// One task note's subscription to TickTick lists: which note aggregates
/// which lists. The file carries only ids — never the token, task bodies, or
/// full task titles (proposal §4.2).
struct TickTickBinding: Codable, Equatable {
    let noteId: String
    /// "inbox" addresses the inbox alias; every other entry is a real project
    /// id from the account.
    let projectIds: [String]
}

/// Typed failure reasons. Each maps to a distinct user-visible condition in
/// the configuration-error state; none of them may ever be swallowed into
/// "no bindings".
enum TickTickBindingsError: Error, Equatable, CustomStringConvertible {
    /// The file exists but could not be read (permissions, I/O).
    case unreadable(String)
    /// The file is not the expected JSON shape.
    case malformed(String)
    /// The file's version is not one this build understands.
    case unsupportedVersion(Int)
    /// Two bindings claim the same note.
    case duplicateNote(String)
    /// A binding points at a note that no longer exists.
    case noteNotFound(String)
    /// A binding points at a note that is not a task note.
    case notTaskNote(String)
    /// The atomic save failed; the previous file, if any, is untouched.
    case writeFailed(String)
    /// The task cache exists but cannot be trusted (decryption or parse
    /// failure).
    case cacheCorrupt(String)

    var description: String {
        switch self {
        case .unreadable(let detail): return "TickTick bindings file is unreadable: \(detail)"
        case .malformed(let detail): return "TickTick bindings file is malformed: \(detail)"
        case .unsupportedVersion(let version): return "TickTick bindings file has unsupported version \(version)"
        case .duplicateNote(let noteId): return "Two TickTick bindings claim note \(noteId)"
        case .noteNotFound(let noteId): return "A TickTick binding points at missing note \(noteId)"
        case .notTaskNote(let noteId): return "A TickTick binding points at non-task note \(noteId)"
        case .writeFailed(let detail): return "TickTick bindings could not be saved: \(detail)"
        case .cacheCorrupt(let detail): return "TickTick task cache is corrupt: \(detail)"
        }
    }
}

// MARK: - Bindings file

/// The outcome of loading the bindings file. A failed read is a condition the
/// app must stop and show ("configuration error"), never a value — an
/// unreadable or invalid file must not degrade to "no bindings", or the notes'
/// snapshots would pass for plain notes again (proposal §4.2). `absent` is the
/// only empty state, and it exists only when no file was ever written.
enum TickTickBindingsState: Equatable {
    case absent
    case loaded([TickTickBinding])
    case invalid(TickTickBindingsError)
}

/// Strict reader/writer for `~/Library/Application Support/Noty/
/// ticktick-bindings.json`.
struct TickTickBindingsStore {
    static let standardURL = Paths.support.appendingPathComponent("ticktick-bindings.json")
    /// The only version this build writes and accepts.
    static let currentVersion = 1

    let fileURL: URL

    init(fileURL: URL = TickTickBindingsStore.standardURL) {
        self.fileURL = fileURL
    }

    /// Loads and strictly validates the file against the notes that exist
    /// right now: version, shape, duplicate note ids, and every noteId must
    /// resolve to a note that still exists and is a task note. Bindings are
    /// only as valid as the notes they point at, so callers pass the current
    /// note snapshot rather than reaching into the store themselves.
    func load(notes: [Note]) -> TickTickBindingsState {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
            return .absent
        } catch {
            return .invalid(.unreadable(error.localizedDescription))
        }

        let document: BindingsDocument
        do {
            document = try TickTickJSON.makeDecoder().decode(BindingsDocument.self, from: data)
        } catch {
            return .invalid(.malformed(error.localizedDescription))
        }
        if document.version != Self.currentVersion {
            return .invalid(.unsupportedVersion(document.version))
        }

        var seen = Set<String>()
        for binding in document.bindings {
            if binding.noteId.isEmpty {
                return .invalid(.malformed("a binding has an empty noteId"))
            }
            if !seen.insert(binding.noteId).inserted {
                return .invalid(.duplicateNote(binding.noteId))
            }
            if binding.projectIds.isEmpty {
                return .invalid(.malformed("binding \(binding.noteId) has no projectIds"))
            }
            if Set(binding.projectIds).count != binding.projectIds.count
                || binding.projectIds.contains(where: \.isEmpty) {
                return .invalid(.malformed("binding \(binding.noteId) has empty or duplicate projectIds"))
            }
        }

        // The notes themselves are the authority on note identity and kind.
        let byID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
        for binding in document.bindings {
            guard let note = byID[binding.noteId] else {
                return .invalid(.noteNotFound(binding.noteId))
            }
            guard note.source == .ticktick else {
                return .invalid(.notTaskNote(binding.noteId))
            }
        }
        return .loaded(document.bindings)
    }

    /// Writes the file atomically and validates the structural rules (shape,
    /// duplicates) so a file this build writes always passes load. Note
    /// existence is deliberately not checked: a binding is saved *before* its
    /// note is published to the shared store (proposal §8.3), and the load
    /// path re-checks it anyway. A failed save throws — a binding that only
    /// lives in memory never existed.
    func save(_ bindings: [TickTickBinding]) throws {
        var seen = Set<String>()
        for binding in bindings {
            if binding.noteId.isEmpty {
                throw TickTickBindingsError.malformed("a binding has an empty noteId")
            }
            if !seen.insert(binding.noteId).inserted {
                throw TickTickBindingsError.duplicateNote(binding.noteId)
            }
            if binding.projectIds.isEmpty {
                throw TickTickBindingsError.malformed("binding \(binding.noteId) has no projectIds")
            }
            if Set(binding.projectIds).count != binding.projectIds.count
                || binding.projectIds.contains(where: \.isEmpty) {
                throw TickTickBindingsError.malformed("binding \(binding.noteId) has empty or duplicate projectIds")
            }
        }
        let document = BindingsDocument(version: Self.currentVersion, bindings: bindings)
        do {
            let data = try TickTickJSON.makeEncoder().encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw TickTickBindingsError.writeFailed(error.localizedDescription)
        }
    }

    private struct BindingsDocument: Codable {
        let version: Int
        var bindings: [TickTickBinding]
    }

    /// Drops the binding of a task note whose undo window has closed
    /// (proposal §8.4: deleting a task note removes only the local display,
    /// so its binding leaves with it — after the undo window, not during).
    /// The strict loader has already passed every structural check by the
    /// time it reports a missing note, so the filtered document goes back
    /// through the same validating save. Returns false when the note has no
    /// binding or the file could not be rewritten.
    @discardableResult
    func pruneBinding(noteID: String) -> Bool {
        guard let data = try? Data(contentsOf: fileURL),
              var document = try? TickTickJSON.makeDecoder().decode(BindingsDocument.self, from: data),
              document.version == Self.currentVersion,
              document.bindings.contains(where: { $0.noteId == noteID }) else { return false }
        document.bindings.removeAll { $0.noteId == noteID }
        do {
            let rewritten = try TickTickJSON.makeEncoder().encode(document)
            try rewritten.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Task cache

/// Encrypted local cache of task snapshots and pending (unconfirmed) write
/// operations, sealed with the app's own AES-GCM handling (Core's Crypto) and
/// a key file of its own, so the note-body key and the cache key never share
/// fate. A missing cache is legitimate — before the first successful read the
/// note's own body is the snapshot — but a cache that exists and cannot be
/// decrypted or parsed is an error, never a silent empty state.
struct TickTickTaskCache {
    static let standardURL = Paths.support.appendingPathComponent("ticktick-cache.bin")
    static let standardKeyURL = Paths.support.appendingPathComponent("ticktick-cache.key")

    let fileURL: URL
    private let cipher: Crypto

    init(fileURL: URL = TickTickTaskCache.standardURL,
         keyURL: URL = TickTickTaskCache.standardKeyURL) {
        self.fileURL = fileURL
        self.cipher = Crypto(keyURL: keyURL, allowCreation: true)
    }

    /// A write the server has not confirmed yet. Enough to identify the
    /// operation later: which note and task it belonged to, the real project
    /// it was sent to, the intended status, the connection generation it was
    /// valid in (stale generations are dropped, never replayed — proposal
    /// §6.3), and when it left. After a restart these are only read back,
    /// never automatically re-sent.
    struct PendingOperation: Codable, Equatable {
        let noteId: String
        let taskId: String
        let projectId: String
        let targetStatus: Int
        let generation: Int
        let sentAt: Date
    }

    /// A task that left the display after its absence was confirmed twice
    /// (proposal §5.3.5) — described as inaccessible, never as deleted. The
    /// projectId stays so each note can tell whether the removal belonged
    /// to one of its lists.
    struct InaccessibleTask: Codable, Equatable {
        let taskId: String
        let projectId: String
        let title: String
    }

    struct Snapshot: Codable, Equatable {
        let tasks: [TickTickTask]
        let pending: [PendingOperation]
        let savedAt: Date
        /// Present since the sync phase; older caches decode without it.
        var inaccessible: [InaccessibleTask]?
    }

    /// The cached snapshot, or nil when no cache file exists yet. Throws when
    /// a file exists but cannot be decrypted or parsed.
    func load() throws -> Snapshot? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileReadNoSuchFileError {
            return nil
        }
        // Crypto throws its own typed PersistenceError when the bytes do not
        // decrypt (wrong or missing key, tampering).
        let plain = try cipher.open(data)
        do {
            return try TickTickJSON.makeDecoder().decode(Snapshot.self, from: Data(plain.utf8))
        } catch {
            throw TickTickBindingsError.cacheCorrupt(error.localizedDescription)
        }
    }

    /// Seals and atomically replaces the cache. A failed save leaves the
    /// previous cache intact and throws — "cache not saved" must never look
    /// like success (proposal §4.2).
    func save(_ snapshot: Snapshot) throws {
        do {
            let data = try TickTickJSON.makeEncoder().encode(snapshot)
            let sealed = try cipher.seal(String(decoding: data, as: UTF8.self))
            try sealed.write(to: fileURL, options: .atomic)
        } catch let error as TickTickBindingsError {
            throw error
        } catch {
            throw TickTickBindingsError.writeFailed(error.localizedDescription)
        }
    }
}
