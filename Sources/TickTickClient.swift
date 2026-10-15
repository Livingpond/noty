import Foundation
import Security

// MARK: - Errors

/// Transport and protocol failures the sync layer must be able to branch on.
/// The HTTP classes map one status family to one case so callers can decide
/// credential, permission, throttling and retry behaviour without re-parsing
/// (proposal §7.1): 401 pauses until credentials change, 403 disables writes,
/// 429 honors Retry-After, 5xx and timeouts back off.
enum TickTickError: Error, Equatable, CustomStringConvertible {
    /// 401 — the token was rejected. Retrying with the same token cannot help.
    case unauthorized
    /// 403 — the account may read but not write this scope.
    case forbidden
    /// 404 — the addressed task (or its project pairing) does not exist. Never
    /// evidence of deletion on its own: soft-deleted tasks still read 200
    /// (contract report §四.2).
    case notFound
    /// 429 — throttled. Retry-After when the server sent a usable value.
    case rateLimited(retryAfter: TimeInterval?)
    /// 5xx — server-side failure; safe to retry later.
    case server
    /// The request hit its 10 s ceiling.
    case timedOut
    /// Any other transport failure (offline, DNS, reset, cancelled).
    case network(String)
    /// A 2xx body that will not decode. A contract break must surface as an
    /// error — never as an empty result (proposal §5.1).
    case invalidResponse(String)
    /// Any status outside the classes above, with the server's message if the
    /// body carried the standard error envelope.
    case httpStatus(Int, String?)

    var description: String {
        switch self {
        case .unauthorized: return "TickTick rejected the credentials (401)"
        case .forbidden: return "TickTick refused the operation (403)"
        case .notFound: return "TickTick has no such task (404)"
        case .rateLimited(let retryAfter):
            let detail = retryAfter.map { "retry after \($0) s" } ?? "no Retry-After given"
            return "TickTick throttled the request (429), \(detail)"
        case .server: return "TickTick server error (5xx)"
        case .timedOut: return "TickTick request timed out"
        case .network(let detail): return "TickTick network failure: \(detail)"
        case .invalidResponse(let detail): return "TickTick response broke the contract: \(detail)"
        case .httpStatus(let code, let message):
            return "TickTick returned HTTP \(code)\(message.map { ": \($0)" } ?? "")"
        }
    }
}

// MARK: - Dates

/// The API's timestamp dialect: ISO-8601 with milliseconds and a UTC offset,
/// `"2026-10-14T09:52:43.922+0000"`. Second precision and extended offsets
/// (`+00:00`) also occur, so both shapes parse; the millisecond form is what
/// encoding writes back.
enum TickTickDate {
    private static let lock = NSLock()
    private static let withMillis: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withMillis.date(from: string) ?? plain.date(from: string)
    }

    static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withMillis.string(from: date)
    }
}

// MARK: - JSON codec

/// The JSON dialect shared by the API and the encrypted local cache, so a
/// task decoded from the network re-encodes into the cache byte-stably.
/// Fresh instances per call — JSONEncoder/JSONDecoder are not safe to share
/// across threads.
enum TickTickJSON {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = TickTickDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "unrecognized TickTick date: \(raw)")
            }
            return date
        }
        return decoder
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TickTickDate.format(date))
        }
        return encoder
    }
}

// MARK: - Models

/// One list. The inbox never appears in `/project` results; it is addressed
/// through the "inbox" alias (contract report §1.1).
struct TickTickProject: Codable, Equatable {
    let id: String
    let name: String
    var color: String?
    /// "TASK" or "NOTE" — a list kind, not a task kind.
    var kind: String?
    var sortOrder: Int?
    var viewMode: String?
    var groupId: String?
}

struct TickTickColumn: Codable, Equatable {
    let id: String
    let projectId: String
    let name: String
    var sortOrder: Int?
}

/// The `/project/{id}/data` response. Inbox responses carry no `project`
/// object at all, so that stays optional — but `tasks` is required: a missing
/// or undecodable task array is a contract break, never an empty list
/// (proposal §5.1).
struct TickTickProjectData: Codable, Equatable {
    let tasks: [TickTickTask]
    var project: TickTickProject?
    var columns: [TickTickColumn]?
}

/// A CHECKLIST child item. Read-only for now: the open API refuses to change
/// item status (contract report §2.4), so only the parent task completes.
struct TickTickChecklistItem: Codable, Equatable {
    var id: String?
    let title: String
    var status: Int?
    var completedTime: Date?
    var isAllDay: Bool?
    var sortOrder: Int?
    var timeZone: String?
}

/// One task. The non-optional fields were present in every one of 788 task
/// objects captured during contract verification (including single-task reads
/// and years-old tasks); `content`, `desc`, `progress`, `columnId`,
/// `columnName` and `repeatFlag` were absent from some real responses and stay
/// optional.
struct TickTickTask: Codable, Equatable {
    let id: String
    let projectId: String
    let title: String
    /// 0 undone, 2 completed, -1 abandoned (never observed on the wire).
    let status: Int
    /// "TEXT", "NOTE" or "CHECKLIST".
    let kind: String
    let sortOrder: Int
    let priority: Int
    let timeZone: String
    let isAllDay: Bool
    let isFloating: Bool
    let etag: String
    /// Server change stamp, epoch milliseconds.
    let etimestamp: Int
    let modifiedTime: Date
    let createdTime: Date

    var content: String?
    var desc: String?
    var progress: Int?
    var columnId: String?
    var columnName: String?
    var completedTime: Date?
    var startDate: Date?
    var dueDate: Date?
    var parentId: String?
    var childIds: [String]?
    var items: [TickTickChecklistItem]?
    /// True when the task repeats (contract report §1.2: the field appears
    /// only on some tasks). A repeating task's next instance is unverified,
    /// so it stays read-only here — no completion or restore write (proposal
    /// §5.4, contract report §四).
    var repeatFlag: Bool?

    /// Status is the only completion evidence — completedTime survives an
    /// un-complete with its stale value (contract report §四.1).
    var isCompleted: Bool { status == 2 }
}

// MARK: - Keychain

/// The personal API token as a generic-password item in the user's keychain.
/// The keychain is the only place the token lives besides the request header —
/// no file, cache, log or export may carry it (proposal §7.2).
struct TickTickKeychain {
    /// Keychain items are namespaced by the app's bundle identifier.
    static let standard = TickTickKeychain(service: "app.noty.Noty", account: "ticktick")

    let service: String
    let account: String

    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        case unreadableItem

        var description: String {
            switch self {
            case .status(let status): return "Keychain returned status \(status)"
            case .unreadableItem: return "The stored TickTick token is not readable text"
            }
        }
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Upserts the token: updates the item if one exists, adds it otherwise.
    /// The add-then-race window is closed by retrying the update.
    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let attributes = [kSecValueData as String: data]
        switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
        case errSecSuccess: return
        case errSecItemNotFound: break
        case let status: throw KeychainError.status(status)
        }
        var add = query
        add[kSecValueData as String] = data
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return
        case errSecDuplicateItem:
            switch SecItemUpdate(query as CFDictionary, attributes as CFDictionary) {
            case errSecSuccess: return
            case let status: throw KeychainError.status(status)
            }
        case let status: throw KeychainError.status(status)
        }
    }

    /// The stored token, or nil when none was ever saved.
    func load() throws -> String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(search as CFDictionary, &out) {
        case errSecSuccess:
            guard let data = out as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw KeychainError.unreadableItem
            }
            return token
        case errSecItemNotFound: return nil
        case let status: throw KeychainError.status(status)
        }
    }

    /// Removes the token. Deleting twice is not an error.
    func delete() throws {
        switch SecItemDelete(query as CFDictionary) {
        case errSecSuccess, errSecItemNotFound: return
        case let status: throw KeychainError.status(status)
        }
    }
}

// MARK: - Client

/// Minimal REST client for the TickTick open API: one method per verified
/// endpoint, one error taxonomy, no retries and no caching — sequencing and
/// confirmation are the sync layer's job. The session is injectable so tests
/// can stub the transport with a URLProtocol.
final class TickTickClient {
    /// Requests go only to this host; the token never follows a redirect
    /// elsewhere (proposal §7.2). The trailing slash is load-bearing: relative
    /// path resolution would otherwise drop the version segment.
    static let defaultBaseURL = URL(string: "https://api.dida365.com/open/v1/")!
    /// Single-request ceiling (proposal §7.1): both the per-request and the
    /// whole-resource cap, so a stalled download cannot outlive 10 s either.
    static let requestTimeout: TimeInterval = 10

    private let token: String
    private let baseURL: URL
    private let session: URLSession

    init(token: String,
         baseURL: URL = TickTickClient.defaultBaseURL,
         session: URLSession = TickTickClient.makeSession()) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    /// The production session: ephemeral storage, the 10 s ceilings, and a
    /// delegate that refuses cross-host redirects so the Authorization header
    /// cannot leave the TickTick API host.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }

    // MARK: Endpoints

    /// Every list except the inbox.
    func listProjects() async throws -> [TickTickProject] {
        try await performDecoded("project", as: [TickTickProject].self)
    }

    /// Undone tasks of one list: the inbox through its "inbox" alias, other
    /// lists by id.
    func projectData(projectId: String) async throws -> TickTickProjectData {
        try await performDecoded("project/\(Self.escaped(projectId))/data", as: TickTickProjectData.self)
    }

    /// Server-side task filter. The body key is `projectIds` — the singular
    /// form is a contract break — and `status` takes 0 (undone) and 2
    /// (completed). Results cap at 200 rows.
    func filterTasks(projectIds: [String], statuses: [Int]) async throws -> [TickTickTask] {
        try await performDecoded("task/filter", method: "POST",
                                 body: try encode(FilterBody(projectIds: projectIds, status: statuses)),
                                 as: [TickTickTask].self)
    }

    /// Tasks completed inside the window. The date filter applies to
    /// completedTime, never startDate — the two endpoints' date semantics are
    /// not interchangeable — and the window must always be explicit: without
    /// dates this endpoint saturates at 200 rows of full history (contract
    /// report §1.4).
    func completedTasks(projectIds: [String], from: Date, to: Date) async throws -> [TickTickTask] {
        try await performDecoded("task/completed", method: "POST",
                                 body: try encode(CompletedBody(projectIds: projectIds,
                                                                startDate: TickTickDate.format(from),
                                                                endDate: TickTickDate.format(to))),
                                 as: [TickTickTask].self)
    }

    /// One task, addressed by the project it actually belongs to (a real id
    /// or "inbox"). A mismatched project returns 404 even though the task
    /// exists, so callers must use the task's own projectId (contract
    /// report §1.5).
    func task(projectId: String, taskId: String) async throws -> TickTickTask {
        try await performDecoded("project/\(Self.escaped(projectId))/task/\(Self.escaped(taskId))",
                                 as: TickTickTask.self)
    }

    /// Marks a task done. The response body carries nothing to decode (empty
    /// or `[]`); completion is only proven by a later authoritative read.
    func completeTask(projectId: String, taskId: String) async throws {
        _ = try await perform("project/\(Self.escaped(projectId))/task/\(Self.escaped(taskId))/complete",
                              method: "POST")
    }

    /// Sets a task's completion status through the task update endpoint. The
    /// minimal verified body for restoring a task is {id, projectId,
    /// status: 0}; status 2 completes directly (contract report §2.2).
    /// Whatever the response carries, the new state is only trusted after an
    /// authoritative read back.
    func updateTaskStatus(taskId: String, projectId: String, status: Int) async throws {
        _ = try await perform("task/\(Self.escaped(taskId))", method: "POST",
                              body: try encode(UpdateStatusBody(id: taskId, projectId: projectId, status: status)))
    }

    // MARK: Transport

    private struct FilterBody: Encodable {
        let projectIds: [String]
        let status: [Int]
    }

    private struct CompletedBody: Encodable {
        let projectIds: [String]
        let startDate: String
        let endDate: String
    }

    private struct UpdateStatusBody: Encodable {
        let id: String
        let projectId: String
        let status: Int
    }

    /// The error envelope every 4xx/5xx body uses:
    /// {errorId, errorCode, errorMessage, data} (contract report §四.9).
    private struct APIErrorEnvelope: Decodable {
        var errorCode: String?
        var errorMessage: String?
    }

    private func perform(_ path: String, method: String, body: Data? = nil) async throws -> Data {
        let request = try makeRequest(path: path, method: method, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.classify(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TickTickError.network("response was not HTTP")
        }
        if let failure = Self.classify(http, body: data) { throw failure }
        return data
    }

    private func performDecoded<T: Decodable>(_ path: String, method: String = "GET",
                                              body: Data? = nil, as type: T.Type) async throws -> T {
        let data = try await perform(path, method: method, body: body)
        do {
            return try TickTickJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            // A 2xx body that will not decode is a broken contract — mapping
            // it to an empty result would read as "no tasks" (proposal §5.1).
            throw TickTickError.invalidResponse("\(T.self): \(error.localizedDescription)")
        }
    }

    private func makeRequest(path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw TickTickError.invalidResponse("unusable request path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func encode(_ body: Encodable) throws -> Data {
        try TickTickJSON.makeEncoder().encode(body)
    }

    /// Ids are server-generated, but the URL must not break if one ever
    /// carries a path character.
    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")))
            ?? id
    }

    // MARK: Error classification

    private static func classify(_ response: HTTPURLResponse, body: Data) -> TickTickError? {
        switch response.statusCode {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429: return .rateLimited(retryAfter: retryAfter(from: response))
        case 500..<600: return .server
        default:
            if let envelope = try? TickTickJSON.makeDecoder().decode(APIErrorEnvelope.self, from: body) {
                return .httpStatus(response.statusCode, envelope.errorMessage)
            }
            return .httpStatus(response.statusCode, nil)
        }
    }

    private static func classify(_ error: Error) -> TickTickError {
        if let urlError = error as? URLError, urlError.code == .timedOut { return .timedOut }
        return .network(error.localizedDescription)
    }

    /// Retry-After as delay-seconds or an HTTP-date; nil when absent or
    /// unusable, which the caller treats like any other retryable failure.
    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}

/// URLSession follows redirects by default and would carry the Authorization
/// header wherever the server points. A redirect that leaves the API host (or
/// drops to a non-HTTPS scheme) is refused; the task then finishes with the
/// 3xx response itself, which the error classifier reports as an unexpected
/// status. Internal so tests can build a stubbed session with the same guard
/// the production session uses (proposal §9.3: redirects are part of the HTTP
/// contract coverage).
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url,
              request.url?.host == original.host,
              request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
