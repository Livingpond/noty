import Foundation
import Security
import SQLite3

/// Layer-1 TickTick integration: the HTTP contract against a stubbed
/// transport, the bindings file's strict validation, the encrypted task
/// cache, the note `source` migration, and the snapshot-update protections.
enum TickTickTests {

    // MARK: - Transport stub

    /// Intercepts every request the client makes, so the tests exercise the
    /// real request-building and response-classifying code with no network
    /// and no real account.
    final class StubURLProtocol: URLProtocol {
        struct Stub {
            var status: Int = 200
            var headers: [String: String] = ["Content-Type": "application/json"]
            var body: Data = Data("[]".utf8)
            var error: Error?
        }

        /// One captured outgoing request, with the body read back out of the
        /// stream URLSession hands the protocol.
        struct RecordedRequest {
            let url: URL?
            let method: String?
            let headers: [String: String]
            let timeout: TimeInterval
            let body: Data?
        }

        private static let lock = NSLock()
        private static var handlerStorage: ((URLRequest) -> Stub)?
        private static var requestStorage: [RecordedRequest] = []

        /// Set per test. Runs on the session's queue.
        static var handler: ((URLRequest) -> Stub)? {
            get { lock.lock(); defer { lock.unlock() }; return handlerStorage }
            set { lock.lock(); defer { lock.unlock() }; handlerStorage = newValue }
        }

        static var recorded: [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }; return requestStorage
        }

        static func reset() {
            lock.lock(); defer { lock.unlock() }
            handlerStorage = nil
            requestStorage = []
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let entry = RecordedRequest(url: request.url,
                                        method: request.httpMethod,
                                        headers: request.allHTTPHeaderFields ?? [:],
                                        timeout: request.timeoutInterval,
                                        body: Self.bodyData(of: request))
            Self.lock.lock()
            Self.requestStorage.append(entry)
            Self.lock.unlock()
            let stub = Self.handler?(request) ?? Stub()
            if let error = stub.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                           httpVersion: "HTTP/1.1", headerFields: stub.headers)
            client?.urlProtocol(self, didReceive: response!, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty {
                client?.urlProtocol(self, didLoad: stub.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession turns a request body into a stream before the protocol
        /// sees it, so read the stream back out for assertions.
        private static func bodyData(of request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            let capacity = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: capacity)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }

    // MARK: - Helpers

    private typealias Stub = StubURLProtocol.Stub
    private typealias RecordedRequest = StubURLProtocol.RecordedRequest

    /// A task in the exact shape contract verification captured — including
    /// the millisecond timestamps and the basic UTC offset.
    private static let fixtureTaskJSON = """
    {"id":"6acf50dee4b0f927d5153bdb","projectId":"inbox1011272817","sortOrder":-4398066434049,"title":"买牛奶","content":"","desc":"","startDate":"2026-10-20T16:00:00.000+0000","dueDate":"2026-10-20T16:00:00.000+0000","timeZone":"Asia/Shanghai","isAllDay":true,"priority":3,"progress":0,"isFloating":false,"completedTime":"2026-10-14T09:52:43.922+0000","status":2,"columnId":"65434d6d1fc2c802ee1ad67e","columnName":"未分组","etag":"mgufkz5s","etimestamp":1791971624963,"kind":"TEXT","modifiedTime":"2026-10-14T09:53:37.235+0000","createdTime":"2026-10-14T09:52:30.130+0000"}
    """

    /// The same task as a single-task read sometimes returns it: no content,
    /// desc, progress or column fields. Real responses omit these.
    private static let sparseTaskJSON = """
    {"id":"6acf50dee4b0f927d5153bdb","projectId":"inbox1011272817","sortOrder":-4398066434049,"title":"买牛奶","timeZone":"Asia/Shanghai","isAllDay":true,"priority":3,"isFloating":false,"completedTime":"2026-10-14T09:52:43.922+0000","status":2,"etag":"18s347b1","etimestamp":1791971563922,"kind":"TEXT","modifiedTime":"2026-10-14T09:52:43.922+0000","createdTime":"2026-10-14T09:52:30.130+0000"}
    """

    private static func fixtureTask() throws -> TickTickTask {
        try TickTickJSON.makeDecoder().decode(TickTickTask.self, from: Data(fixtureTaskJSON.utf8))
    }

    private static func stubClient(token: String = "token-under-test") -> TickTickClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TickTickClient(token: token, session: URLSession(configuration: configuration))
    }

    /// Bridges an async client call into the synchronous check-based style.
    /// Blocking the test thread is safe: the work runs on URLSession's queues
    /// and the cooperative pool, neither of which needs this thread back.
    private static func awaitResult<T>(_ operation: @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<T, Error>!
        Task {
            defer { semaphore.signal() }
            do { outcome = .success(try await operation()) }
            catch { outcome = .failure(error) }
        }
        semaphore.wait()
        return try outcome.get()
    }

    private static func expectSuccess<T>(_ message: String, _ check: (Bool, String) -> Void,
                                         _ operation: @escaping () async throws -> T) -> T? {
        do {
            return try awaitResult(operation)
        } catch {
            check(false, "\(message): \(error)")
            return nil
        }
    }

    private static func expectFailure<T>(_ message: String, _ expected: TickTickError,
                                         check: (Bool, String) -> Void,
                                         _ operation: @escaping () async throws -> T) {
        do {
            _ = try awaitResult(operation)
            check(false, message)
        } catch let error as TickTickError {
            check(error == expected, "\(message) — got \(error)")
        } catch {
            check(false, "\(message) — unexpected error \(error)")
        }
    }

    private static func mustThrow(_ message: String, _ check: (Bool, String) -> Void,
                                  _ operation: () throws -> Void) {
        do { try operation(); check(false, message) }
        catch { /* Expected failure. */ }
    }

    private static func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noty-ticktick-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Reads one text value straight out of the SQLite file, so tests can
    /// observe what actually landed on disk.
    private static func scalarText(_ url: URL, _ sql: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }

    /// Reads one numeric value straight out of the SQLite file.
    private static func scalarDouble(_ url: URL, _ sql: String) -> Double? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    private static func jsonBody(_ request: RecordedRequest) -> [String: Any]? {
        guard let data = request.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Equality for JSON objects, whose values are Any.
    private static func jsonEqual(_ left: [String: Any]?, _ right: [String: Any]) -> Bool {
        guard let left else { return false }
        return (left as NSDictionary).isEqual(to: right)
    }

    // MARK: - Entry point

    static func run(check: (Bool, String) -> Void) {
        StubURLProtocol.reset()
        testRequestBodies(check: check)
        testProjectDataContract(check: check)
        testTaskDecodingTolerance(check: check)
        testWriteEndpointsAcceptEmptySuccessBody(check: check)
        testErrorClassification(check: check)
        testTimeoutConfiguration(check: check)
        testRedirectGuard(check: check)
        do {
            try testKeychainTokenRoundTrip(check: check)
            try testBindingsRoundTrip(check: check)
            try testBindingsValidation(check: check)
            try testBindingsWriteFailures(check: check)
            try testTaskCacheRoundTrip(check: check)
            try testTaskCacheCorruption(check: check)
            try testSourceColumnMigration(check: check)
            try testSourceRoundTripAndUnknownValue(check: check)
            try testSnapshotUpdateProtection(check: check)
            try testUpdateBodyRejectsTaskNotes(check: check)
            try testArchiveExportImportUnbindsTaskNotes(check: check)
        } catch {
            check(false, "TickTick regression failed: \(error)")
        }
        testTaskListGroupingAndSorting(check: check)
        testRecentCompletionsWindowAndOrder(check: check)
        testRecentFoldLogic(check: check)
        testSnapshotBodyRendering(check: check)
        testDisplayRouting(check: check)
        testRowActionPolicy(check: check)
        testPhaseLocalization(check: check)
        testSettingsValidation(check: check)
        testPortalForwardsToEngine(check: check)
        do {
            try testTaskNoteCreation(check: check)
            try testTaskNoteModelPipeline(check: check)
            try testTaskNoteModelCorruptCache(check: check)
        } catch {
            check(false, "TickTick UI regression failed: \(error)")
        }
        StubURLProtocol.reset()
    }

    // MARK: - HTTP contract

    private static func testRequestBodies(check: (Bool, String) -> Void) {
        StubURLProtocol.reset()
        let client = stubClient(token: "token-under-test")
        StubURLProtocol.handler = { _ in Stub() }

        let filtered = expectSuccess("filter must succeed", check, {
            try await client.filterTasks(projectIds: ["inbox", "dd304bc59cb99e8098dc0a73"], statuses: [0])
        }) ?? []
        check(filtered.isEmpty, "the empty stub must decode as zero tasks, not fail")
        var request = StubURLProtocol.recorded.last!
        check(request.url?.absoluteString == "https://api.dida365.com/open/v1/task/filter",
              "filter must target the documented endpoint")
        check(request.method == "POST", "filter must be a POST")
        check(request.headers["Authorization"] == "Bearer token-under-test",
              "every request must carry the bearer token")
        check(request.headers["Content-Type"] == "application/json",
              "JSON bodies must declare their content type")
        check(jsonEqual(jsonBody(request), ["projectIds": ["inbox", "dd304bc59cb99e8098dc0a73"], "status": [0]]),
              "the filter body key is projectIds (plural) with the status list")

        let from = Date(timeIntervalSince1970: 1_791_930_000)
        let to = Date(timeIntervalSince1970: 1_792_016_400)
        _ = expectSuccess("completed query must succeed", check, {
            try await client.completedTasks(projectIds: ["inbox"], from: from, to: to)
        })
        request = StubURLProtocol.recorded.last!
        check(request.url?.absoluteString == "https://api.dida365.com/open/v1/task/completed",
              "completed must target the documented endpoint")
        let completedBody = jsonBody(request)
        check(completedBody?["projectIds"] as? [String] == ["inbox"],
              "the completed body must carry projectIds")
        check(completedBody?["startDate"] as? String == TickTickDate.format(from)
              && completedBody?["endDate"] as? String == TickTickDate.format(to),
              "the completed window must be explicit TickTick timestamps")

        _ = expectSuccess("status update must succeed", check, {
            try await client.updateTaskStatus(taskId: "6acf50dee4b0f927d5153bdb",
                                              projectId: "inbox1011272817", status: 0)
        })
        request = StubURLProtocol.recorded.last!
        check(request.url?.absoluteString == "https://api.dida365.com/open/v1/task/6acf50dee4b0f927d5153bdb",
              "status updates must address the task endpoint")
        check(jsonEqual(jsonBody(request), ["id": "6acf50dee4b0f927d5153bdb",
                                            "projectId": "inbox1011272817",
                                            "status": 0]),
              "un-completing must send the minimal verified field set")
    }

    private static func testProjectDataContract(check: (Bool, String) -> Void) {
        StubURLProtocol.reset()
        let client = stubClient()

        // The inbox shape: columns and tasks, no project object at all.
        StubURLProtocol.handler = { _ in
            Stub(body: Data("{\"tasks\":[\(fixtureTaskJSON)],\"columns\":[]}".utf8))
        }
        guard let inbox = expectSuccess("inbox data must load", check, {
            try await client.projectData(projectId: "inbox")
        }) else { return }
        check(StubURLProtocol.recorded.last?.url?.absoluteString
              == "https://api.dida365.com/open/v1/project/inbox/data",
              "the inbox is addressed through its alias")
        check(inbox.tasks.count == 1 && inbox.tasks[0].title == "买牛奶" && inbox.project == nil,
              "inbox data must decode tasks and tolerate the missing project object")

        // A normal list: columns, project and tasks.
        StubURLProtocol.handler = { _ in
            Stub(body: Data("""
            {"project":{"id":"dd304bc59cb99e8098dc0a73","name":"工作","kind":"TASK","sortOrder":12},
            "tasks":[\(fixtureTaskJSON)],"columns":[]}
            """.utf8))
        }
        guard let normal = expectSuccess("project data must load", check, {
            try await client.projectData(projectId: "dd304bc59cb99e8098dc0a73")
        }) else { return }
        check(normal.project?.name == "工作" && normal.columns?.isEmpty == true,
              "project data must decode the project object and columns")

        // An explicit empty task array is a valid empty list.
        StubURLProtocol.handler = { _ in Stub(body: Data("{\"tasks\":[]}".utf8)) }
        guard let empty = expectSuccess("an empty tasks array must decode", check, {
            try await client.projectData(projectId: "inbox")
        }) else { return }
        check(empty.tasks.isEmpty, "a present-but-empty tasks array is a legitimate empty list")

        // A missing tasks array is a contract break, never an empty list.
        StubURLProtocol.handler = { _ in Stub(body: Data("{\"columns\":[]}".utf8)) }
        do {
            _ = try awaitResult({ try await client.projectData(projectId: "inbox") })
            check(false, "a response without tasks must fail, not read as empty")
        } catch let error as TickTickError {
            if case .invalidResponse = error {} else {
                check(false, "a missing tasks array must be an invalidResponse — got \(error)")
            }
        } catch {
            check(false, "unexpected error \(error)")
        }
    }

    private static func testTaskDecodingTolerance(check: (Bool, String) -> Void) {
        do {
            let task = try fixtureTask()
            check(task.isCompleted && task.status == 2,
                  "status 2 must read as completed")
            check(task.progress == 0 && task.columnName == "未分组" && task.content?.isEmpty == true,
                  "the full task shape must decode every optional field")
            check(task.modifiedTime == TickTickDate.parse("2026-10-14T09:53:37.235+0000"),
                  "millisecond timestamps must parse exactly")
            check(task.etimestamp == 1_791_971_624_963,
                  "etimestamp must decode as epoch milliseconds")

            let sparse = try TickTickJSON.makeDecoder().decode(TickTickTask.self,
                                                               from: Data(sparseTaskJSON.utf8))
            check(sparse.progress == nil && sparse.columnId == nil && sparse.content == nil,
                  "single-task reads that omit optional fields must still decode")
            check(sparse.isCompleted, "the sparse shape still carries the status")
            check(sparse.repeatFlag == nil, "tasks without repeatFlag decode with it nil")

            // The repeat flag (contract report §1.2) decides the read-only
            // display of repeating tasks (proposal §5.4).
            let repeating = try taskJSON(id: "rep", projectId: "inbox1011272817",
                                         title: "每周复盘", repeatFlag: true)
            check(repeating.repeatFlag == true, "a present repeatFlag decodes as true")
        } catch {
            check(false, "task decoding failed: \(error)")
        }
    }

    private static func testWriteEndpointsAcceptEmptySuccessBody(check: (Bool, String) -> Void) {
        StubURLProtocol.reset()
        let client = stubClient()
        for body in [Data(), Data("[]".utf8)] {
            StubURLProtocol.handler = { _ in Stub(body: body) }
            _ = expectSuccess("an empty 2xx body must complete a task", check) {
                try await client.completeTask(projectId: "inbox1011272817", taskId: "6acf50dee4b0f927d5153bdb")
            }
            _ = expectSuccess("an empty 2xx body must accept a status update", check) {
                try await client.updateTaskStatus(taskId: "6acf50dee4b0f927d5153bdb",
                                                  projectId: "inbox1011272817", status: 2)
            }
        }
        let request = StubURLProtocol.recorded.first
        check(request?.url?.absoluteString
              == "https://api.dida365.com/open/v1/project/inbox1011272817/task/6acf50dee4b0f927d5153bdb/complete",
              "completion must target the documented endpoint")
    }

    private static func testErrorClassification(check: (Bool, String) -> Void) {
        StubURLProtocol.reset()
        let client = stubClient()

        let cases: [(Int, TickTickError, String)] = [
            (401, .unauthorized, "401 must pause as an auth failure"),
            (403, .forbidden, "403 must read as a permission failure"),
            (404, .notFound, "404 must read as a missing task"),
            (502, .server, "5xx must read as a server failure"),
        ]
        for (status, expected, message) in cases {
            StubURLProtocol.handler = { _ in Stub(status: status, body: Data("[]".utf8)) }
            expectFailure(message, expected, check: check) {
                try await client.task(projectId: "inbox", taskId: "any")
            }
        }

        StubURLProtocol.handler = { _ in
            Stub(status: 429, headers: ["Retry-After": "120"], body: Data("[]".utf8))
        }
        expectFailure("429 must carry the server's Retry-After", .rateLimited(retryAfter: 120),
                      check: check) {
            try await client.task(projectId: "inbox", taskId: "any")
        }

        StubURLProtocol.handler = { _ in Stub(status: 429, body: Data("[]".utf8)) }
        expectFailure("429 without a usable Retry-After stays retryable",
                      .rateLimited(retryAfter: nil), check: check) {
            try await client.task(projectId: "inbox", taskId: "any")
        }

        StubURLProtocol.handler = { _ in
            Stub(status: 400,
                 body: Data("{\"errorId\":\"e\",\"errorCode\":\"invalid_request\",\"errorMessage\":\"checklist item status is invalid\",\"data\":null}".utf8))
        }
        expectFailure("other statuses must surface the server's message",
                      .httpStatus(400, "checklist item status is invalid"), check: check) {
            try await client.updateTaskStatus(taskId: "any", projectId: "inbox", status: 0)
        }

        StubURLProtocol.handler = { _ in Stub(error: URLError(.timedOut)) }
        expectFailure("a transport timeout must classify as timedOut", .timedOut,
                      check: check) {
            try await client.task(projectId: "inbox", taskId: "any")
        }

        StubURLProtocol.handler = { _ in Stub(error: URLError(.notConnectedToInternet)) }
        do {
            _ = try awaitResult({ try await client.task(projectId: "inbox", taskId: "any") })
            check(false, "an offline transport must fail")
        } catch let error as TickTickError {
            if case .network = error {} else {
                check(false, "other transport failures must classify as network — got \(error)")
            }
        } catch {
            check(false, "unexpected error type \(error)")
        }
    }

    private static func testTimeoutConfiguration(check: (Bool, String) -> Void) {
        let session = TickTickClient.makeSession()
        check(session.configuration.timeoutIntervalForRequest == TickTickClient.requestTimeout,
              "the request idle timeout must be 10 seconds")
        check(session.configuration.timeoutIntervalForResource == TickTickClient.requestTimeout,
              "the whole-resource timeout must cap at 10 seconds too")

        StubURLProtocol.reset()
        let client = stubClient()
        StubURLProtocol.handler = { _ in Stub(body: Data("[]".utf8)) }
        _ = expectSuccess("the probe request must succeed", check) {
            try await client.listProjects()
        }
        check(StubURLProtocol.recorded.last?.timeout == TickTickClient.requestTimeout,
              "each request must carry the 10 second ceiling")
    }

    /// 重定向 (proposal §9.3 HTTP contract, §7.2): the production session
    /// installs the redirect guard, and the guard's decision is exercised
    /// directly with the inputs URLSession would hand it — a hop that leaves
    /// the API host or drops to plaintext is refused (so the Authorization
    /// header never travels), a same-host HTTPS hop is followed as proposed.
    /// (A custom URLProtocol cannot cover this end to end: the session does
    /// not run its redirect machinery on protocol-synthesized responses, so
    /// the delegate method is driven by hand.)
    private static func testRedirectGuard(check: (Bool, String) -> Void) {
        let session = TickTickClient.makeSession()
        check(session.delegate is RedirectGuard,
              "the production session carries the redirect guard (proposal §7.2)")

        let guardDelegate = session.delegate as! RedirectGuard
        let api = URL(string: "https://api.dida365.com/open/v1/task")!

        /// One delegate decision for an original request to `original` that
        /// the server wants to redirect to `redirect`.
        func decision(original: URL, redirect: URL) -> URLRequest? {
            let response = HTTPURLResponse(url: original, statusCode: 302,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": redirect.absoluteString])!
            let task = session.dataTask(with: original)
            var verdict: URLRequest?
            guardDelegate.urlSession(session, task: task,
                                     willPerformHTTPRedirection: response,
                                     newRequest: URLRequest(url: redirect)) { request in
                verdict = request
            }
            return verdict
        }

        check(decision(original: api, redirect: URL(string: "https://attacker.example/steal")!) == nil,
              "a redirect that leaves the API host is refused — the Authorization header never travels (proposal §7.2)")
        check(decision(original: api, redirect: URL(string: "http://api.dida365.com/open/v1/task")!) == nil,
              "a redirect that drops to plaintext is refused")
        let followed = decision(original: api,
                                redirect: URL(string: "https://api.dida365.com/open/v1/task-moved")!)
        check(followed == URLRequest(url: URL(string: "https://api.dida365.com/open/v1/task-moved")!),
              "a same-host HTTPS redirect is followed exactly as proposed")

        // The refused cases end as the 3xx response itself, which the error
        // classifier reports as an unexpected status rather than success.
        StubURLProtocol.reset()
        let client = stubClient()
        StubURLProtocol.handler = { _ in
            Stub(status: 302, headers: ["Location": "https://attacker.example/steal"],
                 body: Data("[]".utf8))
        }
        expectFailure("a refused redirect must surface as the 3xx itself",
                      .httpStatus(302, nil), check: check) {
            try await client.task(projectId: "inbox", taskId: "any")
        }
    }

    // MARK: - Keychain

    private static func testKeychainTokenRoundTrip(check: (Bool, String) -> Void) throws {
        let keychain = TickTickKeychain(service: "app.noty.tests.\(UUID().uuidString)",
                                        account: "ticktick")
        defer { try? keychain.delete() }
        do {
            check(try keychain.load() == nil, "a fresh keychain item must load as nil")
            try keychain.save("first-token")
            check(try keychain.load() == "first-token", "a saved token must load back")
            try keychain.save("second-token")
            check(try keychain.load() == "second-token", "saving again must update, not duplicate")
            try keychain.delete()
            check(try keychain.load() == nil, "a deleted token must be gone")
            try keychain.delete()   // idempotent on purpose
        } catch {
            check(false, "the keychain round trip failed: \(error)")
        }
    }

    // MARK: - Bindings file

    private static func testBindingsRoundTrip(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("bindings")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
        let taskNote = Note(id: "n1", title: "", body: "", source: .ticktick)
        let binding = TickTickBinding(noteId: "n1", projectIds: ["inbox", "dd304bc59cb99e8098dc0a73"])

        check(store.load(notes: [taskNote]) == .absent,
              "a missing bindings file is the only empty state")
        try store.save([binding])
        check(store.load(notes: [taskNote]) == .loaded([binding]),
              "a saved binding must load back")
        check(store.load(notes: []) == .invalid(.noteNotFound("n1")),
              "a binding whose note is gone is a config error, not an empty list")
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        check(raw.contains("\"version\"") && raw.contains("\"bindings\"")
              && raw.contains("\"noteId\"") && raw.contains("\"projectIds\""),
              "the bindings file must keep its documented shape")
    }

    private static func testBindingsValidation(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("bindings-validation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ticktick-bindings.json")
        let store = TickTickBindingsStore(fileURL: url)
        let taskNote = Note(id: "n1", title: "", body: "", source: .ticktick)
        let plainNote = Note(id: "n2", title: "", body: "")
        let notes = [taskNote, plainNote]

        func write(_ object: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        }

        // An unreadable file is a config error — never absent, never empty.
        try Data("{}".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let unreadable = store.load(notes: notes)
        if case .invalid(.unreadable) = unreadable {} else {
            check(false, "an unreadable bindings file must enter the config-error state — got \(unreadable)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try Data("not json".utf8).write(to: url, options: .atomic)
        if case .invalid(.malformed) = store.load(notes: notes) {} else {
            check(false, "garbage bytes must be rejected as malformed")
        }

        try write(["version": 2, "bindings": []])
        if case .invalid(.unsupportedVersion(2)) = store.load(notes: notes) {} else {
            check(false, "an unknown version must be rejected")
        }

        try write(["version": 1, "bindings": [
            ["noteId": "n1", "projectIds": ["inbox"]],
            ["noteId": "n1", "projectIds": ["other"]],
        ]])
        if case .invalid(.duplicateNote("n1")) = store.load(notes: notes) {} else {
            check(false, "duplicate note ids must be rejected")
        }

        try write(["version": 1, "bindings": [["noteId": "n2", "projectIds": ["inbox"]]]])
        if case .invalid(.notTaskNote("n2")) = store.load(notes: notes) {} else {
            check(false, "a binding to a plain note must be rejected")
        }

        try write(["version": 1, "bindings": [["noteId": "nX", "projectIds": ["inbox"]]]])
        if case .invalid(.noteNotFound("nX")) = store.load(notes: notes) {} else {
            check(false, "a binding to a missing note must be rejected")
        }

        try write(["version": 1, "bindings": [["noteId": "n1", "projectIds": []]]])
        if case .invalid(.malformed) = store.load(notes: notes) {} else {
            check(false, "a binding without project ids must be rejected")
        }

        try write(["version": 1])
        if case .invalid(.malformed) = store.load(notes: notes) {} else {
            check(false, "a file without a bindings array must be rejected")
        }

        // An explicitly saved empty list is valid — it means "no bindings",
        // written on purpose, unlike a read failure.
        try write(["version": 1, "bindings": []])
        check(store.load(notes: notes) == .loaded([]),
              "an explicit empty bindings list is a valid state")
    }

    private static func testBindingsWriteFailures(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("bindings-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
        let first = TickTickBinding(noteId: "n1", projectIds: ["inbox"])
        let second = TickTickBinding(noteId: "n2", projectIds: ["inbox"])

        try store.save([first])
        mustThrow("saving duplicate note ids must be refused", check) {
            try store.save([first, TickTickBinding(noteId: "n1", projectIds: ["other"])])
        }

        // A read-only directory makes the atomic write fail; the previous
        // file must survive untouched.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        mustThrow("a failed atomic write must be reported", check) { try store.save([second]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        check(store.load(notes: [Note(id: "n1", title: "", body: "", source: .ticktick)]) == .loaded([first]),
              "a failed save must leave the previous bindings intact")
    }

    // MARK: - Task cache

    private static func testTaskCacheRoundTrip(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TickTickTaskCache(fileURL: directory.appendingPathComponent("ticktick-cache.bin"),
                                      keyURL: directory.appendingPathComponent("ticktick-cache.key"))
        let keyURL = directory.appendingPathComponent("ticktick-cache.key")

        check(try cache.load() == nil, "a missing cache is the pre-first-read state, not an error")
        check(!FileManager.default.fileExists(atPath: keyURL.path),
              "reading a missing cache must not create a key")

        let task = try fixtureTask()
        let pending = TickTickTaskCache.PendingOperation(noteId: "n1",
                                                          taskId: task.id,
                                                          projectId: task.projectId,
                                                          targetStatus: 0,
                                                          generation: 3,
                                                          sentAt: Date(timeIntervalSince1970: 1_791_971_624))
        let snapshot = TickTickTaskCache.Snapshot(tasks: [task],
                                                   pending: [pending],
                                                   savedAt: Date(timeIntervalSince1970: 1_791_971_700))
        try cache.save(snapshot)
        check(try cache.load() == snapshot,
              "task snapshots and pending operations must round-trip through the encrypted cache")

        let raw = try Data(contentsOf: cache.fileURL)
        check(!raw.contains(Data(task.title.utf8)),
              "the cache file must be ciphertext — task titles never appear in the clear")
    }

    private static func testTaskCacheCorruption(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("cache-corruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TickTickTaskCache(fileURL: directory.appendingPathComponent("ticktick-cache.bin"),
                                      keyURL: directory.appendingPathComponent("ticktick-cache.key"))
        let snapshot = TickTickTaskCache.Snapshot(tasks: [try fixtureTask()],
                                                  pending: [],
                                                  savedAt: Date(timeIntervalSince1970: 0))

        try Data("garbage".utf8).write(to: cache.fileURL, options: .atomic)
        mustThrow("a corrupt cache must fail loudly, never read as empty", check) {
            _ = try cache.load()
        }

        try cache.save(snapshot)
        var tampered = try Data(contentsOf: cache.fileURL)
        tampered[tampered.count / 2] ^= 0xFF
        try tampered.write(to: cache.fileURL, options: .atomic)
        mustThrow("tampered cache bytes must fail authentication", check) {
            _ = try cache.load()
        }

        try cache.save(snapshot)
        let stranger = TickTickTaskCache(fileURL: cache.fileURL,
                                         keyURL: directory.appendingPathComponent("stranger.key"))
        mustThrow("a cache sealed with another key must not decrypt", check) {
            _ = try stranger.load()
        }
    }

    // MARK: - Source column migration

    private static func testSourceColumnMigration(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.db")

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            check(false, "test database must open")
            return
        }
        let legacySchema = """
        CREATE TABLE notes (
          id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', body BLOB NOT NULL,
          color INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL,
          modified REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0,
          sort_order REAL NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0,
          text_direction TEXT NOT NULL DEFAULT 'automatic'
        );
        """
        check(sqlite3_exec(db, legacySchema, nil, nil, nil) == SQLITE_OK,
              "legacy schema setup must succeed")
        sqlite3_close(db)

        _ = Store(dbURL: url, keyURL: directory.appendingPathComponent("key"))

        db = nil
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            check(false, "migrated database must reopen")
            return
        }
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db,
                           "INSERT INTO notes (id,body,created,modified) VALUES ('legacy',X'00',1,1);",
                           nil, nil, nil) == SQLITE_OK,
              "rows written after migration must receive the source default")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source FROM notes WHERE id='legacy';",
                                 -1, &statement, nil) == SQLITE_OK else {
            check(false, "migrated source column must be queryable")
            return
        }
        defer { sqlite3_finalize(statement) }
        check(sqlite3_step(statement) == SQLITE_ROW,
              "migrated database must return the inserted row")
        let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        check(raw == NoteSource.local.rawValue,
              "existing databases must default migrated notes to local source")
    }

    private static func testSourceRoundTripAndUnknownValue(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("source-roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.db")
        let storage = Store(dbURL: url, keyURL: directory.appendingPathComponent("key"))

        try storage.upsert(Note(id: "tt1", title: "任务便签", body: "snapshot", source: .ticktick))
        try storage.upsert(Note(id: "loc1", title: "普通便签", body: "free text"))
        let loaded = try storage.load()
        check(loaded.first { $0.id == "tt1" }?.source == .ticktick,
              "the ticktick source must round-trip through the database")
        check(loaded.first { $0.id == "loc1" }?.source == .local,
              "plain notes must stay local")

        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            check(false, "database must reopen for the unknown-source fixture")
            return
        }
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "UPDATE notes SET source='future3' WHERE id='tt1';",
                           nil, nil, nil) == SQLITE_OK,
              "unknown-source fixture must be installed")
        check(try storage.load().first { $0.id == "tt1" }?.source == .ticktick,
              "unknown source values must stay protected, never become editable local notes")
    }

    // MARK: - Snapshot protection

    private static func testSnapshotUpdateProtection(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("snapshot")
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("notes.db")
        let storage = Store(dbURL: dbURL, keyURL: directory.appendingPathComponent("key"))
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
        model.absorb(Note(id: "task-1", title: "自定义标题", body: "old snapshot", color: 3,
                          pinned: true, order: 5, source: .ticktick))

        check(model.updateSnapshotBody(id: "task-1", body: "new snapshot"),
              "a live task note must accept a snapshot update")
        let updated = model.note(id: "task-1")
        check(updated?.body == "new snapshot", "the snapshot body must change")
        check(updated?.title == "自定义标题" && updated?.color == 3
              && updated?.pinned == true && updated?.order == 5 && updated?.source == .ticktick,
              "a snapshot update must not touch title, colour, order or pin")
        check(try storage.load().first?.body == "new snapshot",
              "the snapshot update must persist")

        let before = scalarDouble(dbURL, "SELECT modified FROM notes WHERE id='task-1';")
        check(model.updateSnapshotBody(id: "task-1", body: "new snapshot"),
              "an unchanged body is already correct, not a failure")
        check(scalarDouble(dbURL, "SELECT modified FROM notes WHERE id='task-1';") == before,
              "an identical body must not rewrite the row")

        model.delete(id: "task-1")
        check(!model.updateSnapshotBody(id: "task-1", body: "zombie"),
              "a deleted note must not be resurrected by a snapshot update")
        check(model.note(id: "task-1") == nil, "the deleted note must stay gone from the model")
        check(try storage.load().isEmpty, "the deleted note must stay gone from the database")

        let plain = model.create(body: "plain")
        check(!model.updateSnapshotBody(id: plain.id, body: "x"),
              "snapshot updates only apply to task notes")
        check(model.note(id: plain.id)?.body == "plain",
              "a refused snapshot update must leave a plain note alone")
    }

    private static func testUpdateBodyRejectsTaskNotes(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("body-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                            keyURL: directory.appendingPathComponent("key"))
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
        model.absorb(Note(id: "task-1", title: "", body: "remote snapshot", source: .ticktick))

        model.updateBody(id: "task-1", body: "hijacked")
        check(model.note(id: "task-1")?.body == "remote snapshot",
              "task note bodies must refuse free-text edits")
        check(model.unsavedIDs.isEmpty, "a refused edit must not leave the note dirty")
        check(try storage.load().first?.body == "remote snapshot",
              "a refused edit must not reach the database")

        let plain = model.create(body: "plain")
        model.updateBody(id: plain.id, body: "edited")
        check(model.note(id: plain.id)?.body == "edited",
              "plain notes must keep editing normally")
        check(model.flush(id: plain.id), "plain note edits must still save")
    }

    // MARK: - Archive export/import boundaries (proposal §4.3, §8.6)

    /// 快照导出、导入解绑、旧格式 — the archive boundaries of the task-note
    /// design. An exported task note is nothing but its text snapshot; an
    /// import is always a new plain note; and nothing an archive carries can
    /// claim a note id that is not genuinely free — including the id of a
    /// task note sitting inside its ten-second undo window.
    private static func testArchiveExportImportUnbindsTaskNotes(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("archive-unbind")
        defer { try? FileManager.default.removeItem(at: directory) }
        let taskNote = Note(id: "tt-archive", title: "自定义标题", body: "☐ 买牛奶",
                            color: 2, pinned: true, source: .ticktick)

        // 快照导出 (§4.3): the archive of a task note carries the snapshot
        // text only — no source, no binding, no task identity that could
        // re-import as anything but a plain note.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(StickyArchive(notes: [StickyNote(taskNote)]))
        let raw = String(decoding: data, as: UTF8.self)
        check(raw.contains("买牛奶") && !raw.lowercased().contains("ticktick") && !raw.contains("source"),
              "an exported task note is a plain text snapshot (proposal §4.3/§8.6)")

        // 导入解绑 (§4.3): decoding strips whatever the archive carries.
        let imported = try Transfer.decodeArchive(data)
        check(imported.count == 1 && imported[0].source == .local,
              "decoding an archive yields plain notes — task identity never imports")
        // 旧格式/手工编辑: an archive from before the TickTick work has no
        // source notion at all; a hand-edited one may smuggle a key in. The
        // decoder ignores unknown keys, and the strip holds either way.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var noteObjects = object["notes"] as! [[String: Any]]
        noteObjects[0]["source"] = "ticktick"
        object["notes"] = noteObjects
        let smuggled = try Transfer.decodeArchive(JSONSerialization.data(withJSONObject: object))
        check(smuggled.allSatisfy { $0.source == .local },
              "a hand-added source key inside an archive is stripped on import")

        // Ingest beside a live task note that owns the id: the import takes a
        // fresh id and leaves the task note untouched.
        let live = NoteStore(store: Store(dbURL: directory.appendingPathComponent("live.db"),
                                          keyURL: directory.appendingPathComponent("live.key")),
                             seedWelcome: false, onError: { _ in })
        live.absorb(Note(id: "tt-archive", title: "", body: "live snapshot", source: .ticktick))
        check(live.ingest(imported) == 1, "the import lands beside the live task note")
        check(live.notes.filter { $0.id == "tt-archive" }.count == 1
                  && live.note(id: "tt-archive")?.source == .ticktick,
              "an import never overwrites or unbinds a live task note")
        let clone = live.notes.first { $0.source == .local }
        check(clone?.body == "☐ 买牛奶", "the imported clone keeps the snapshot text")
        if let clone { live.updateBody(id: clone.id, body: "编辑") }
        check(live.notes.first { $0.source == .local }?.body == "编辑",
              "the imported clone is an editable plain note")

        // The undo window: a task note deleted ten seconds ago still owns its
        // id outside `notes`. An archive carrying that id must not take it —
        // it would break the binding (the loader would see a non-task note
        // under the bound id) and make the undo append duplicate the id.
        let undo = NoteStore(store: Store(dbURL: directory.appendingPathComponent("undo.db"),
                                          keyURL: directory.appendingPathComponent("undo.key")),
                             seedWelcome: false, onError: { _ in })
        undo.absorb(taskNote)
        let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("bindings.json"))
        try bindings.save([TickTickBinding(noteId: "tt-archive", projectIds: ["inbox"])])
        undo.delete(id: "tt-archive")
        check(undo.pendingUndo != nil, "setup: the ten-second undo window is open")

        check(undo.ingest(try Transfer.decodeArchive(data)) == 1,
              "the import lands during the undo window")
        check(undo.notes.allSatisfy { $0.id != "tt-archive" },
              "an id inside the undo window is not reused by the import")
        let windowNotes = undo.notes + (undo.pendingUndo.map { [$0.note] } ?? [])
        check(bindings.load(notes: windowNotes)
                  == .loaded([TickTickBinding(noteId: "tt-archive", projectIds: ["inbox"])]),
              "the binding keeps validating while the window is open — the import claimed no task identity")

        undo.undoDelete()
        check(undo.notes.filter { $0.id == "tt-archive" }.count == 1,
              "the undo restores exactly one note with the original id")
        check(undo.note(id: "tt-archive")?.source == .ticktick,
              "the restored note is the task note again")
        check(undo.notes.count == 2, "import plus undo leaves two notes, not a duplicate third")
    }

    // MARK: - Task list layout (UI layer, proposal §5.4)

    /// A minimal row for the pure layout tests.
    private static func row(_ taskId: String, project: String, title: String = "t",
                            status: Int = 0, kind: String = "TEXT",
                            sortOrder: Int? = 0, completed: Date? = nil,
                            repeated: Bool = false) -> TickTickTaskRow {
        TickTickTaskRow(taskId: taskId, projectId: project, title: title, status: status,
                        kind: kind, sortOrder: sortOrder, completedTime: completed,
                        isRepeated: repeated)
    }

    private static func testTaskListGroupingAndSorting(check: (Bool, String) -> Void) {
        // Membership: the inbox alias resolves the account's real inbox id,
        // literal ids match, strangers do not.
        check(TickTickTaskListLayout.bindingKey(forTaskProjectId: "inbox62240517",
                                                boundProjectIds: ["inbox"]) == "inbox",
              "the inbox alias must claim the account's real inbox id")
        check(TickTickTaskListLayout.bindingKey(forTaskProjectId: "inbox",
                                                boundProjectIds: ["inbox"]) == "inbox",
              "a literal inbox projectId must match the alias")
        check(TickTickTaskListLayout.bindingKey(forTaskProjectId: "dd304bc59cb99e8098dc0a73",
                                                boundProjectIds: ["inbox", "dd304bc59cb99e8098dc0a73"])
              == "dd304bc59cb99e8098dc0a73",
              "an ordinary list id must match itself")
        check(TickTickTaskListLayout.bindingKey(forTaskProjectId: "dd304bc59cb99e8098dc0a73",
                                                boundProjectIds: ["inbox"]) == nil,
              "a task from an unbound list belongs to no group")
        check(TickTickTaskListLayout.bindingKey(forTaskProjectId: "inbox62240517",
                                                boundProjectIds: []) == nil,
              "no bindings claim nothing")

        let rows = [
            row("t-a", project: "work1", sortOrder: 20),
            row("t-b", project: "work1", sortOrder: 10),
            row("t-c", project: "inbox62240517", sortOrder: 5),
            row("t-d", project: "inbox62240517", sortOrder: nil),
            row("t-e", project: "inbox62240517", status: 2, sortOrder: 1),
            row("t-f", project: "elsewhere", sortOrder: 1),
            row("t-b", project: "work1", sortOrder: 30),   // duplicate read of t-b
            row("t-0", project: "work1", sortOrder: 10),   // ties t-b on sortOrder
        ]
        let groups = TickTickTaskListLayout.undoneGroups(rows: rows, boundProjectIds: ["inbox", "work1"])
        let groupKeys = groups.map { $0.projectKey }
        check(groupKeys == ["inbox", "work1"],
              "groups follow the user's chosen list order, not the input order")
        let inboxIDs = groups.first?.tasks.map { $0.taskId } ?? []
        check(inboxIDs == ["t-c", "t-d"],
              "the inbox group sorts by sortOrder with the missing value last")
        let workIDs = groups.last?.tasks.map { $0.taskId } ?? []
        check(workIDs == ["t-0", "t-b", "t-a"],
              "the work group sorts by sortOrder ascending, taskId as the stable tiebreaker")
        let allIDs = groups.flatMap { $0.tasks.map { $0.taskId } }
        check(!allIDs.contains("t-e"), "completed tasks never appear in the undone groups")
        check(!allIDs.contains("t-f"), "tasks from unbound lists never appear")
        check(allIDs.filter { $0 == "t-b" }.count == 1,
              "a task read twice collapses to one row — the first occurrence wins")

        // Binding order reversed: the group order follows.
        let flipped = TickTickTaskListLayout.undoneGroups(rows: rows, boundProjectIds: ["work1", "inbox"])
        check(flipped.map { $0.projectKey } == ["work1", "inbox"],
              "reversing the binding order reverses the group order")
        // A binding with no tasks disappears rather than rendering an empty header.
        let sparse = TickTickTaskListLayout.undoneGroups(rows: rows, boundProjectIds: ["inbox", "empty1"])
        check(sparse.map { $0.projectKey } == ["inbox"],
              "a list with no undone tasks renders no group")
    }

    private static func testRecentCompletionsWindowAndOrder(check: (Bool, String) -> Void) {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let bound = ["inbox"]
        let rows = [
            row("r-2h", project: "inbox62240517", status: 2, completed: now.addingTimeInterval(-2 * 3600)),
            row("r-1h-b", project: "inbox62240517", status: 2, completed: now.addingTimeInterval(-3600)),
            row("r-1h-a", project: "inbox62240517", status: 2, completed: now.addingTimeInterval(-3600)),
            row("r-stale", project: "inbox62240517", status: 2, completed: now.addingTimeInterval(-25 * 3600)),
            row("r-unknown", project: "inbox62240517", status: 2, completed: nil),
            row("r-foreign", project: "elsewhere", status: 2, completed: now.addingTimeInterval(-60)),
            row("r-undone", project: "inbox62240517", status: 0, completed: now),
        ]
        let recent = TickTickTaskListLayout.recentCompletions(rows: rows, boundProjectIds: bound, now: now)
        let recentIDs = recent.map { $0.taskId }
        check(recentIDs == ["r-1h-a", "r-1h-b", "r-2h", "r-unknown"],
              "recent completions sort newest first, taskId breaks ties, unknown times go last")
        check(recent.contains { $0.taskId == "r-stale" } == false,
              "completions outside the 24-hour window drop out of the display")
        check(recent.contains { $0.taskId == "r-unknown" },
              "an unknown completion time is kept — never presumed stale (proposal §5.2)")
        check(recent.contains { $0.taskId == "r-foreign" } == false,
              "completions from unbound lists do not surface")
        check(recent.contains { $0.taskId == "r-undone" } == false,
              "undone tasks never appear among the recent completions")
    }

    private static func testRecentFoldLogic(check: (Bool, String) -> Void) {
        var fold = TickTickRecentFold()
        check(fold.showsHeader && fold.showsRows,
              "the section starts expanded and visible")
        fold.toggleCollapsed()
        check(fold.showsHeader && !fold.showsRows,
              "collapsing hides the rows but keeps the header with its controls")
        fold.toggleCollapsed()
        check(fold.showsRows, "collapsing again expands the rows")
        fold.setHidden(true)
        check(!fold.showsHeader && !fold.showsRows,
              "hiding removes the section, header included (proposal §5.2)")
        fold.setHidden(false)
        check(fold.showsHeader && fold.showsRows, "hiding is reversible")
    }

    private static func testSnapshotBodyRendering(check: (Bool, String) -> Void) {
        let groups: [(name: String, tasks: [TickTickTaskRow])] = [
            ("收集箱", [row("t-1", project: "inbox", title: "买牛奶")]),
            ("工作", [row("t-2", project: "work", title: "写周报"),
                     row("t-3", project: "work", title: "寄快递", status: 2)]),
        ]
        let body = TickTickTaskListLayout.snapshotBody(header: "滴答 · 收集箱 + 工作",
                                                        groups: groups,
                                                        recentHeading: "近期完成 · 1",
                                                        recent: [row("t-4", project: "inbox",
                                                                     title: "旧任务", status: 2,
                                                                     completed: Date())])
        let expected = """
        滴答 · 收集箱 + 工作

        收集箱
        \(Tasks.openPrefix)买牛奶

        工作
        \(Tasks.openPrefix)写周报
        \(Tasks.donePrefix)寄快递

        近期完成 · 1
        \(Tasks.donePrefix)旧任务
        """
        check(body == expected, "the derived snapshot must render the documented shape — got \(body)")

        let empty = TickTickTaskListLayout.snapshotBody(header: "滴答",
                                                         groups: [("空", [])],
                                                         recentHeading: "近期完成 · 0",
                                                         recent: [])
        check(empty == "滴答", "an empty snapshot is the header alone — no empty group headers")

        // The snapshot is what search, progress and preview consume (§4.3):
        // task markers must round-trip through the existing task utilities.
        let note = Note(body: body)
        check(note.taskProgress?.done == 2 && note.taskProgress?.total == 4,
              "the snapshot's ☐/☑ markers must feed the existing task progress")
        check(Note.derivedTitle(from: body) == "滴答 · 收集箱 + 工作",
              "the snapshot's first line must serve as the note's derived title")
    }

    private static func testDisplayRouting(check: (Bool, String) -> Void) {
        let plain = Note(body: "free text")
        let task = Note(id: "task-note", body: "snapshot", source: .ticktick)

        check(TickTickDisplayRouting.surface(for: plain) == .textEditor,
              "plain notes keep the text editor")
        check(TickTickDisplayRouting.surface(for: task) == .taskList,
              "task notes open on the task list (proposal §2.2)")
        check(TickTickDisplayRouting.allowsTaskLineToggle(plain)
              && !TickTickDisplayRouting.allowsTaskLineToggle(task),
              "the task-marker shortcut must be inert on task notes (proposal §2.2)")
        check(TickTickDisplayRouting.isCaptureTarget(plain)
              && !TickTickDisplayRouting.isCaptureTarget(task),
              "quick capture must never append to a task note (proposal §2.2)")
    }

    private static func testRowActionPolicy(check: (Bool, String) -> Void) {
        let undone = row("t", project: "inbox", kind: "TEXT")
        let note = row("n", project: "inbox", kind: "NOTE")
        let phase: TickTickSyncPhase = .updated(Date())

        func blocker(_ row: TickTickTaskRow, pending: Bool = false,
                     engine: Bool = true, snapshot: Bool = true,
                     phase: TickTickSyncPhase = phase) -> TickTickRowActionPolicy.Blocker? {
            TickTickRowActionPolicy.blocker(for: row, pending: pending, engineAttached: engine,
                                            hasSnapshot: snapshot, phase: phase)
        }
        check(blocker(undone) == nil, "a loaded task on a live engine may be completed")
        check(blocker(note) == .noteKind, "kind NOTE carries no completion button (proposal §5.4)")
        check(blocker(row("r", project: "inbox", repeated: true)) == .repeatedTask,
              "a repeating task is read-only until its next-instance behaviour is verified (proposal §5.4)")
        check(blocker(undone, pending: true) == .pending,
              "a pending write disables the row until it is confirmed")
        check(blocker(undone, engine: false) == .noEngine,
              "no engine attached means no write path at all")
        check(blocker(undone, snapshot: false) == .neverLoaded,
              "the first successful read gates completion (proposal §4.2)")
        check(blocker(undone, phase: .offline) == .offline
              && blocker(undone, phase: .unauthorized) == .unauthorized
              && blocker(undone, phase: .forbidden) == .forbidden
              && blocker(undone, phase: .misconfigured) == .misconfigured,
              "connection states that forbid writes block the row (proposal §7.3)")

        for blockerCase in [TickTickRowActionPolicy.Blocker.noteKind, .repeatedTask, .pending, .noEngine,
                            .neverLoaded, .offline, .unauthorized, .forbidden, .misconfigured] {
            check(!blockerCase.localizedHelp.isEmpty,
                  "every blocker needs user-facing help copy")
        }
        let fresh = TickTickTaskListLayout.pendingFeedback(sentAt: Date())
        let stale = TickTickTaskListLayout.pendingFeedback(sentAt: Date().addingTimeInterval(-31))
        check(fresh == L10n.text("ticktick.row.confirming")
              && stale == L10n.text("ticktick.row.awaiting"),
              "pending feedback reads as confirming inside 30 s, result pending after (proposal §6.2)")
    }

    private static func testPhaseLocalization(check: (Bool, String) -> Void) {
        let phases: [TickTickSyncPhase] = [.idle, .refreshing, .updated(Date()), .offline,
                                           .unauthorized, .forbidden, .incomplete, .misconfigured]
        for phase in phases {
            check(!phase.localizedStatus.isEmpty,
                  "every sync phase needs localized status copy (proposal §7.3)")
        }
        check(TickTickSyncPhase.updated(Date(timeIntervalSince1970: 0)).localizedStatus.contains(":"),
              "the updated phase shows a HH:mm clock time")
    }

    private static func testSettingsValidation(check: (Bool, String) -> Void) {
        check(!TickTickSettingsValidation.isValidToken("")
              && !TickTickSettingsValidation.isValidToken("  \n ")
              && TickTickSettingsValidation.isValidToken(" abc123 "),
              "a token must be non-empty after trimming; nothing more is assumed")
        check(!TickTickSettingsValidation.isValidSelection([]),
              "an empty selection cannot create a note")
        check(!TickTickSettingsValidation.isValidSelection(["a", "a"]),
              "duplicate lists in a selection are rejected")
        check(!TickTickSettingsValidation.isValidSelection([""]),
              "an empty list id is rejected")
        check(TickTickSettingsValidation.isValidSelection(["inbox", "dd30"]),
              "a normal selection validates")

        let fetched = [TickTickProject(id: "p1", name: "一"),
                       TickTickProject(id: "p2", name: "二"),
                       TickTickProject(id: "p3", name: "三")]
        check(TickTickSettingsValidation.selectionOrder(selected: ["inbox", "p2"],
                                                         fetchedOrder: fetched) == ["inbox", "p2"],
              "the inbox alias leads the binding order, then the account's list order")
        check(TickTickSettingsValidation.selectionOrder(selected: ["p3", "p1"],
                                                         fetchedOrder: fetched) == ["p1", "p3"],
              "fetched lists keep the account's order regardless of set iteration")
        check(TickTickSettingsValidation.selectionOrder(selected: [],
                                                         fetchedOrder: fetched).isEmpty,
              "nothing selected produces no binding")
    }

    /// The engine seam: events forwarded, nothing scheduled here.
    private final class StubEngine: TickTickEngine {
        var activations = 0
        var wakes = 0
        var sleeps = 0
        var refreshes = 0
        var completions: [String] = []
        var uncompletions: [String] = []
        var viewAppeared = 0
        var viewDisappeared = 0
        var credentialChanges = 0

        func applicationDidActivate() { activations += 1 }
        func applicationDidWake() { wakes += 1 }
        func systemWillSleep() { sleeps += 1 }
        func refreshRequested() { refreshes += 1 }
        func completeTask(taskId: String, noteID: String) { completions.append("\(noteID):\(taskId)") }
        func uncompleteTask(taskId: String, noteID: String) { uncompletions.append("\(noteID):\(taskId)") }
        func noteTaskViewDidAppear() { viewAppeared += 1 }
        func noteTaskViewDidDisappear() { viewDisappeared += 1 }
        func credentialsDidChange() { credentialChanges += 1 }
    }

    private static func testPortalForwardsToEngine(check: (Bool, String) -> Void) {
        let portal = TickTickPortal()
        let engine = StubEngine()

        // No engine attached: the mount points are quiet no-ops, not polls.
        portal.applicationDidActivate()
        portal.applicationDidWake()
        portal.systemWillSleep()
        portal.refreshNow()
        portal.completeTask(taskId: "t", noteID: "n")
        portal.uncompleteTask(taskId: "t", noteID: "n")
        portal.taskViewDidAppear()
        portal.taskViewDidDisappear()
        portal.engineCredentialsDidChange()
        check(engine.activations == 0 && engine.wakes == 0 && engine.sleeps == 0
              && engine.refreshes == 0 && engine.completions.isEmpty && engine.uncompletions.isEmpty
              && engine.viewAppeared == 0 && engine.viewDisappeared == 0
              && engine.credentialChanges == 0,
              "without an engine the lifecycle hooks forward nothing")

        portal.attach(engine: engine)
        portal.applicationDidActivate()
        portal.applicationDidWake()
        portal.systemWillSleep()
        portal.refreshNow()
        portal.completeTask(taskId: "t-1", noteID: "n-1")
        portal.uncompleteTask(taskId: "t-2", noteID: "n-1")
        portal.taskViewDidAppear()
        portal.taskViewDidDisappear()
        portal.engineCredentialsDidChange()
        check(engine.activations == 1 && engine.wakes == 1 && engine.sleeps == 1
              && engine.refreshes == 1
              && engine.completions == ["n-1:t-1"] && engine.uncompletions == ["n-1:t-2"]
              && engine.viewAppeared == 1 && engine.viewDisappeared == 1
              && engine.credentialChanges == 1,
              "the portal forwards activation, wake, sleep, refresh, completion, "
                  + "restore, visibility and credential changes to the engine")

        portal.detachEngine()
        portal.refreshNow()
        check(engine.refreshes == 1, "detaching stops the forwarding")

        portal.setPhase(.incomplete)
        check(portal.phase == .incomplete, "the portal carries the shared phase")
        portal.setProjectNames(["p": "工作"])
        check(portal.projectNames == ["p": "工作"], "the portal carries the account's list names")
        portal.bumpCacheVersion()
        check(portal.cacheVersion == 1, "the portal carries the engine's cache version")
    }

    // MARK: - Task-note creation (proposal §8.3)

    private static func testTaskNoteCreation(check: (Bool, String) -> Void) throws {
        // Success: binding saved, row saved, note published — in that order of
        // durability, source already ticktick.
        do {
            let directory = try temporaryDirectory("creation")
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                                 keyURL: directory.appendingPathComponent("key"))
            let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
            let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))

            guard case .failure = TickTickTaskCreation.createTaskNote(projectIds: [], noteStore: model,
                                                                      bindingsStore: bindings) else {
                check(false, "an empty selection must refuse creation")
                return
            }
            guard case .failure = TickTickTaskCreation.createTaskNote(projectIds: ["inbox", "inbox"],
                                                                      noteStore: model,
                                                                      bindingsStore: bindings) else {
                check(false, "a duplicate selection must refuse creation")
                return
            }

            guard case .success(let note) = TickTickTaskCreation.createTaskNote(
                    projectIds: ["inbox", "dd304bc59cb99e8098dc0a73"],
                    noteStore: model, bindingsStore: bindings) else {
                check(false, "a valid selection must create the note")
                return
            }
            check(note.source == .ticktick, "the created note is a task note from the first write on")
            check(model.note(id: note.id)?.source == .ticktick,
                  "the created note is published to the shared store")
            check(try storage.load().first { $0.id == note.id }?.source == .ticktick,
                  "the created note's row carries the source durably")
            check(bindings.load(notes: model.notes)
                  == .loaded([TickTickBinding(noteId: note.id,
                                              projectIds: ["inbox", "dd304bc59cb99e8098dc0a73"])]),
                  "the binding is saved with the note's id and the chosen list order")
        }

        // A failed row write rolls the binding back and publishes nothing.
        do {
            let directory = try temporaryDirectory("creation-row-failure")
            defer { try? FileManager.default.removeItem(at: directory) }
            // A database path inside a read-only directory: the SQLite open
            // fails, the NoteStore turns read-only, the row cannot be saved.
            let locked = directory.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                            ofItemAtPath: locked.path) }
            let storage = Store(dbURL: locked.appendingPathComponent("notes.db"),
                                keyURL: directory.appendingPathComponent("key"))
            let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
            let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))

            guard case .failure(.noteSaveFailed) = TickTickTaskCreation.createTaskNote(
                    projectIds: ["inbox"], noteStore: model, bindingsStore: bindings) else {
                check(false, "a failed row write must report noteSaveFailed")
                return
            }
            check(model.notes.isEmpty, "a failed creation publishes no note")
            check(bindings.load(notes: []) == .loaded([]),
                  "the rolled-back bindings file must keep no binding for the unwritten note")
        }

        // A failed binding write leaves nothing at all — no row, no note.
        do {
            let directory = try temporaryDirectory("creation-binding-failure")
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                                keyURL: directory.appendingPathComponent("key"))
            let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
            let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                            ofItemAtPath: directory.path) }

            guard case .failure(.bindingSaveFailed) = TickTickTaskCreation.createTaskNote(
                    projectIds: ["inbox"], noteStore: model, bindingsStore: bindings) else {
                check(false, "a failed binding write must report bindingSaveFailed")
                return
            }
            check(model.notes.isEmpty, "no note is published when the binding cannot be saved")
            check(try storage.load().isEmpty, "no row is written when the binding cannot be saved")
        }

        // A bindings file in the config-error state is never written on top of.
        do {
            let directory = try temporaryDirectory("creation-config-error")
            defer { try? FileManager.default.removeItem(at: directory) }
            let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                                keyURL: directory.appendingPathComponent("key"))
            let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
            let url = directory.appendingPathComponent("ticktick-bindings.json")
            let bindings = TickTickBindingsStore(fileURL: url)
            try Data("not json".utf8).write(to: url, options: .atomic)

            guard case .failure(.bindingsUnavailable) = TickTickTaskCreation.createTaskNote(
                    projectIds: ["inbox"], noteStore: model, bindingsStore: bindings) else {
                check(false, "a broken bindings file must refuse creation")
                return
            }
            check(try String(contentsOf: url, encoding: .utf8) == "not json",
                  "creation must not repair or overwrite a broken bindings file")
            check(model.notes.isEmpty, "no note is published over a broken configuration")
        }
    }

    // MARK: - Per-note view model (cache → rows, pending, snapshot)

    /// Builds a TickTickTask from fields, in the wire shape the contract
    /// captured, for seeding the encrypted cache.
    private static func taskJSON(id: String, projectId: String, title: String,
                                 status: Int = 0, kind: String = "TEXT", sortOrder: Int = 0,
                                 completedTime: Date? = nil,
                                 repeatFlag: Bool? = nil) throws -> TickTickTask {
        var fields = "\"id\":\"\(id)\",\"projectId\":\"\(projectId)\",\"title\":\"\(title)\","
            + "\"status\":\(status),\"kind\":\"\(kind)\",\"sortOrder\":\(sortOrder),"
            + "\"priority\":3,\"timeZone\":\"Asia/Shanghai\",\"isAllDay\":false,\"isFloating\":false,"
            + "\"etag\":\"e\",\"etimestamp\":1,"
            + "\"modifiedTime\":\"2026-10-14T09:00:00.000+0000\","
            + "\"createdTime\":\"2026-10-14T08:00:00.000+0000\""
        if let completedTime {
            fields += ",\"completedTime\":\"\(TickTickDate.format(completedTime))\""
        }
        if let repeatFlag {
            fields += ",\"repeatFlag\":\(repeatFlag)"
        }
        return try TickTickJSON.makeDecoder().decode(TickTickTask.self,
                                                     from: Data("{\(fields)}".utf8))
    }

    private static func testTaskNoteModelPipeline(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("model")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TickTickTaskCache(fileURL: directory.appendingPathComponent("ticktick-cache.bin"),
                                      keyURL: directory.appendingPathComponent("ticktick-cache.key"))
        let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
        let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                            keyURL: directory.appendingPathComponent("key"))
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
        let note = Note(id: "n1", title: "自定义标题", body: "", source: .ticktick)
        model.absorb(note)

        let workID = "dd304bc59cb99e8098dc0a73"
        let bound = ["inbox", workID]
        try bindings.save([TickTickBinding(noteId: "n1", projectIds: bound)])

        let now = Date()
        let snapshot = TickTickTaskCache.Snapshot(
            tasks: [
                try taskJSON(id: "buy-milk", projectId: "inbox62240517", title: "买牛奶", sortOrder: 20),
                try taskJSON(id: "weekly", projectId: "inbox62240517", title: "写周报", sortOrder: 10),
                try taskJSON(id: "package", projectId: "inbox62240517", title: "寄快递", status: 2,
                             completedTime: now.addingTimeInterval(-3 * 3600)),
                try taskJSON(id: "old-done", projectId: "inbox62240517", title: "旧任务", status: 2,
                             completedTime: now.addingTimeInterval(-25 * 3600)),
                try taskJSON(id: "work-1", projectId: workID, title: "工作", sortOrder: 5),
                try taskJSON(id: "foreign", projectId: "elsewhere", title: "无关", sortOrder: 1),
            ],
            pending: [
                TickTickTaskCache.PendingOperation(noteId: "n1", taskId: "buy-milk",
                                                   projectId: "inbox62240517", targetStatus: 2,
                                                   generation: 1, sentAt: now.addingTimeInterval(-5)),
                TickTickTaskCache.PendingOperation(noteId: "other-note", taskId: "zzz",
                                                   projectId: workID, targetStatus: 2,
                                                   generation: 1, sentAt: now.addingTimeInterval(-5)),
            ],
            savedAt: now)
        try cache.save(snapshot)

        let taskNoteModel = TickTickTaskNoteModel(noteID: "n1", cache: cache, bindingsStore: bindings,
                                                  noteStore: model, portal: TickTickPortal(),
                                                  recentCompletionsHidden: false)

        check(taskNoteModel.binding?.projectIds == bound,
              "the model resolves the note's binding from the strict bindings file")
        check(taskNoteModel.hasSnapshot, "an existing cache counts as loaded")
        let rowIDs = taskNoteModel.rows.map { $0.taskId }.sorted()
        check(rowIDs == ["buy-milk", "old-done", "package", "weekly", "work-1"].sorted(),
              "rows carry exactly this note's bound tasks — undone and completed, never strangers")

        let groups = TickTickTaskListLayout.undoneGroups(rows: taskNoteModel.rows, boundProjectIds: bound)
        check(groups.map { $0.projectKey } == ["inbox", workID],
              "the view model's rows group in binding order")
        check((groups.first?.tasks.map { $0.taskId } ?? []) == ["weekly", "buy-milk"],
              "the inbox group sorts by sortOrder ascending")
        check(taskNoteModel.pendingTaskIDs == ["buy-milk"],
              "pending operations are read back for this note only — never replayed")

        check(taskNoteModel.blocker(for: taskNoteModel.rows.first { $0.taskId == "buy-milk" }!) == .pending,
              "a row with a pending write is blocked from re-clicking")
        check(taskNoteModel.blocker(for: taskNoteModel.rows.first { $0.taskId == "weekly" }!) == .noEngine,
              "without an engine attached no write can leave (placeholder phase)")

        // The derived snapshot (proposal §4.3) must have replaced the body,
        // without touching the note's own attributes.
        let updated = model.note(id: "n1")
        check(updated?.title == "自定义标题", "the snapshot update must not touch the note's title")
        let body = updated?.body ?? ""
        check(body.contains(Tasks.openPrefix + "买牛奶")
              && body.contains(Tasks.openPrefix + "工作")
              && body.contains(Tasks.donePrefix + "寄快递"),
              "the snapshot body carries the group titles with ☐/☑ markers")
        check(body.contains(L10n.text("ticktick.inbox")),
              "the inbox group renders under its localized name")
        check(!body.contains("旧任务"),
              "completions outside the 24-hour window drop out of the display")
        check(!body.contains("无关") && !body.contains("elsewhere"),
              "unbound tasks and raw ids never enter the snapshot (proposal §1)")
        check(body.contains(L10n.format("ticktick.recent.section", 1)),
              "the recent-completions heading carries its count")
        check(updated?.taskProgress?.done == 1 && updated?.taskProgress?.total == 4,
              "the snapshot's markers feed search, progress and preview like any note")
        check(try storage.load().first { $0.id == "n1" }?.body == body,
              "the snapshot update persisted through the controlled writer")
    }

    private static func testTaskNoteModelCorruptCache(check: (Bool, String) -> Void) throws {
        let directory = try temporaryDirectory("model-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TickTickTaskCache(fileURL: directory.appendingPathComponent("ticktick-cache.bin"),
                                      keyURL: directory.appendingPathComponent("ticktick-cache.key"))
        let bindings = TickTickBindingsStore(fileURL: directory.appendingPathComponent("ticktick-bindings.json"))
        let storage = Store(dbURL: directory.appendingPathComponent("notes.db"),
                            keyURL: directory.appendingPathComponent("key"))
        let model = NoteStore(store: storage, seedWelcome: false, onError: { _ in })
        model.absorb(Note(id: "n1", title: "", body: "last known snapshot", source: .ticktick))
        try bindings.save([TickTickBinding(noteId: "n1", projectIds: ["inbox"])])
        try Data("garbage".utf8).write(to: cache.fileURL, options: .atomic)

        let taskNoteModel = TickTickTaskNoteModel(noteID: "n1", cache: cache, bindingsStore: bindings,
                                                  noteStore: model, portal: TickTickPortal(),
                                                  recentCompletionsHidden: false)
        check(taskNoteModel.configInvalid && taskNoteModel.displayPhase == .misconfigured,
              "a corrupt cache flags the note as misconfigured (proposal §4.2)")
        check(taskNoteModel.hasSnapshot == false && taskNoteModel.rows.isEmpty,
              "a corrupt cache does not read as an empty cache")
        check(model.note(id: "n1")?.body == "last known snapshot",
              "the misconfigured note keeps its last known body untouched")
    }
}
