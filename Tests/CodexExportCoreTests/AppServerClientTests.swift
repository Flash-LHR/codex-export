import Foundation
import XCTest
@testable import CodexExportCore

final class AppServerClientTests: XCTestCase {
    func testInitializationUsesTheInjectedClientVersion() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(
            transport: transport,
            configuration: .init(clientVersion: "9.8.7")
        )

        _ = try await client.listTaskPage(limit: 1)

        let requests = try decodeRequests(await transport.recordedRequests())
        let initialize = try XCTUnwrap(requests.first)
        let params = try XCTUnwrap(initialize["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["version"] as? String, "9.8.7")
    }

    func testConcurrentFirstRequestsShareOneInitialization() async throws {
        let transport = YieldingInitializationTransport()
        let client = CodexAppServerClient(transport: transport)
        let requestCount = 20

        let completedPages = try await withThrowingTaskGroup(
            of: TaskSummaryPage.self
        ) { group in
            for _ in 0..<requestCount {
                group.addTask {
                    try await client.listTaskPage(limit: 1)
                }
            }

            var pages: [TaskSummaryPage] = []
            for try await page in group {
                pages.append(page)
            }
            return pages
        }

        XCTAssertEqual(completedPages.count, requestCount)
        XCTAssertTrue(completedPages.allSatisfy { $0.tasks.isEmpty })
        let counts = await transport.recordedCounts()
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.initializeRequests, 1)
        XCTAssertEqual(counts.initializedNotifications, 1)
        XCTAssertEqual(counts.listRequests, requestCount)
    }

    func testSharedInitializationFailureFailsAllWaitersAndCanRetry() async throws {
        let transport = FailingThenRecoveringInitializationTransport()
        let client = CodexAppServerClient(transport: transport)

        let firstRequest = Task {
            try await client.listTaskPage(limit: 1)
        }
        await transport.waitUntilFirstInitializationStarts()

        let waiters = (0..<12).map { _ in
            Task {
                try await client.listTaskPage(limit: 1)
            }
        }
        for _ in 0..<200 { await Task.yield() }
        await transport.releaseFirstInitializationFailure()

        for request in [firstRequest] + waiters {
            do {
                _ = try await request.value
                XCTFail("Expected the shared initialization to fail")
            } catch ControlledInitializationError.expected {
                // Every caller must observe the same shared attempt's failure.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        var counts = await transport.recordedCounts()
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.initializeRequests, 1)
        XCTAssertEqual(counts.initializedNotifications, 0)
        XCTAssertEqual(counts.listRequests, 0)
        XCTAssertEqual(counts.shutdowns, 1)

        _ = try await client.listTaskPage(limit: 1)

        counts = await transport.recordedCounts()
        XCTAssertEqual(counts.starts, 2)
        XCTAssertEqual(counts.initializeRequests, 2)
        XCTAssertEqual(counts.initializedNotifications, 1)
        XCTAssertEqual(counts.listRequests, 1)
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testCancellingOneWaiterDoesNotCancelSharedInitialization() async throws {
        let transport = RestartableInitializationTransport()
        let client = CodexAppServerClient(transport: transport)

        let owner = Task {
            try await client.listTaskPage(limit: 1)
        }
        await transport.waitUntilFirstInitializationStarts()

        let cancelledWaiter = Task {
            try await client.listTaskPage(limit: 1)
        }
        for _ in 0..<100 { await Task.yield() }
        cancelledWaiter.cancel()
        await transport.releaseFirstInitialization()

        _ = try await owner.value
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected the cancelled waiter to stop")
        } catch is CancellationError {
            // Cancelling this waiter must not cancel the shared task.
        }

        let counts = await transport.recordedCounts()
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.initializeRequests, 1)
        XCTAssertEqual(counts.initializedNotifications, 1)
        XCTAssertEqual(counts.listRequests, 1)
        XCTAssertEqual(counts.shutdowns, 0)
    }

    func testShutdownDuringInitializationCannotClearANewerAttempt() async throws {
        let transport = RestartableInitializationTransport()
        let client = CodexAppServerClient(transport: transport)

        let obsoleteRequest = Task {
            try await client.listTaskPage(limit: 1)
        }
        await transport.waitUntilFirstInitializationStarts()
        await client.shutdown()

        let currentRequest = Task {
            try await client.listTaskPage(limit: 1)
        }
        await transport.waitUntilSecondInitializationStarts()

        // Complete the cancelled attempt only after the replacement attempt is
        // already installed. Its late catch/cleanup must be token-guarded.
        await transport.releaseFirstInitialization()
        do {
            _ = try await obsoleteRequest.value
            XCTFail("Expected the obsolete initialization to be cancelled")
        } catch is CancellationError {
            // Expected.
        }

        let concurrentWaiter = Task {
            try await client.listTaskPage(limit: 1)
        }
        for _ in 0..<100 { await Task.yield() }
        await transport.releaseSecondInitialization()

        _ = try await currentRequest.value
        _ = try await concurrentWaiter.value
        _ = try await client.listTaskPage(limit: 1)

        let counts = await transport.recordedCounts()
        XCTAssertEqual(counts.starts, 2)
        XCTAssertEqual(counts.initializeRequests, 2)
        XCTAssertEqual(counts.initializedNotifications, 1)
        XCTAssertEqual(counts.listRequests, 3)
        XCTAssertEqual(counts.shutdowns, 1)
    }

    func testDefaultTaskPickerRequestsOnlyTenRecentTasks() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        _ = try await client.listTasks()

        let requests = try decodeRequests(await transport.recordedRequests())
        let firstList = try XCTUnwrap(requests.first { request in
            request["method"] as? String == "thread/list"
        })
        let params = try XCTUnwrap(firstList["params"] as? [String: Any])
        XCTAssertEqual(params["limit"] as? Int, 10)
        XCTAssertEqual(params["sortKey"] as? String, "updated_at")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(params["archived"] as? Bool, false)
    }

    func testInitializesThenPaginatesNewestTasks() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(
            transport: transport,
            configuration: .init(maximumTaskCount: 2, pageSize: 1)
        )

        let tasks = try await client.listTasks()

        XCTAssertEqual(tasks.map(\.id), ["new", "old"])
        XCTAssertEqual(tasks.map(\.title), ["New task", "Older preview"])
        let events = await transport.recordedEvents()
        XCTAssertEqual(
            events,
            [
                "start",
                "request:initialize",
                "notify:initialized",
                "request:thread/list",
                "request:thread/list",
            ]
        )

        let requests = try decodeRequests(await transport.recordedRequests())
        let firstList = try XCTUnwrap(requests.first { request in
            request["method"] as? String == "thread/list"
        })
        let firstParams = try XCTUnwrap(firstList["params"] as? [String: Any])
        XCTAssertEqual(firstParams["limit"] as? Int, 1)
        XCTAssertEqual(firstParams["sortKey"] as? String, "updated_at")
        XCTAssertEqual(firstParams["useStateDbOnly"] as? Bool, true)
        XCTAssertEqual(firstParams["archived"] as? Bool, false)

        let listRequests = requests.filter { $0["method"] as? String == "thread/list" }
        let secondParams = try XCTUnwrap(listRequests[1]["params"] as? [String: Any])
        XCTAssertEqual(secondParams["cursor"] as? String, "next")
        XCTAssertEqual(secondParams["archived"] as? Bool, false)

        let initialize = try XCTUnwrap(requests.first)
        let initializeParams = try XCTUnwrap(initialize["params"] as? [String: Any])
        let capabilities = try XCTUnwrap(
            initializeParams["capabilities"] as? [String: Any]
        )
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
    }

    func testTaskBrowserBrowsesHistoryByPageWithoutFastIndexShortcut() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        let page = try await client.listTaskPage(limit: 20)

        XCTAssertEqual(page.tasks.map(\.id), ["new"])
        XCTAssertEqual(page.nextCursor, "next")
        let requests = try decodeRequests(await transport.recordedRequests())
        let request = try XCTUnwrap(
            requests.first {
                $0["method"] as? String == "thread/list"
            }
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["limit"] as? Int, 20)
        XCTAssertEqual(params["archived"] as? Bool, false)
        XCTAssertNil(params["searchTerm"])
        XCTAssertEqual(params["useStateDbOnly"] as? Bool, true)
    }

    func testTaskTitleIndexReadsEveryIndexedPageWithoutServerTitleFilter() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        let tasks = try await client.listTaskTitleIndex()

        XCTAssertEqual(tasks.map(\.id), ["new", "old"])
        let requests = try decodeRequests(await transport.recordedRequests()).filter {
            $0["method"] as? String == "thread/list"
        }
        XCTAssertEqual(requests.count, 2)
        let firstParams = try XCTUnwrap(requests.first?["params"] as? [String: Any])
        XCTAssertEqual(firstParams["limit"] as? Int, 100)
        XCTAssertEqual(firstParams["archived"] as? Bool, false)
        XCTAssertEqual(firstParams["useStateDbOnly"] as? Bool, true)
        XCTAssertNil(firstParams["searchTerm"])
        let secondParams = try XCTUnwrap(requests.last?["params"] as? [String: Any])
        XCTAssertEqual(secondParams["cursor"] as? String, "next")
    }

    func testTaskTitleIndexRejectsARepeatedCursor() async throws {
        let transport = MockLineRPCTransport(repeatingListCursor: true)
        let client = CodexAppServerClient(transport: transport)

        do {
            _ = try await client.listTaskTitleIndex()
            XCTFail("Expected a repeated cursor to fail")
        } catch AppServerClientError.invalidResponse {
            // Expected.
        }

        let requestCount = try decodeRequests(await transport.recordedRequests()).filter {
            $0["method"] as? String == "thread/list"
        }.count
        XCTAssertEqual(requestCount, 2)
    }

    func testCancellingTaskTitleIndexStopsBeforeTheNextPage() async throws {
        let transport = PausedTitleIndexTransport()
        let client = CodexAppServerClient(transport: transport)
        let scan = Task {
            try await client.listTaskTitleIndex()
        }

        await transport.waitUntilFirstListRequest()
        scan.cancel()
        await transport.releaseFirstListResponse()

        do {
            _ = try await scan.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let listRequestCount = await transport.listRequestCount()
        XCTAssertEqual(listRequestCount, 1)
    }

    func testContentSearchUsesIndependentFullTextCursor() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        let page = try await client.searchTaskContentPage(
            cursor: "content-page-2",
            searchTerm: "  matrix proof  ",
            limit: 25
        )

        XCTAssertEqual(page.tasks.map(\.id), ["search-hit"])
        XCTAssertEqual(page.tasks.map(\.title), ["Matching task"])
        XCTAssertEqual(page.nextCursor, "search-next")
        let requests = try decodeRequests(await transport.recordedRequests())
        let request = try XCTUnwrap(
            requests.first {
                $0["method"] as? String == "thread/search"
            }
        )
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["searchTerm"] as? String, "matrix proof")
        XCTAssertEqual(params["cursor"] as? String, "content-page-2")
        XCTAssertEqual(params["archived"] as? Bool, false)
        XCTAssertEqual(params["limit"] as? Int, 25)
        XCTAssertEqual(params["sortKey"] as? String, "updated_at")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
    }

    func testUnavailableContentSearchDoesNotRepeatTitleSearch() async throws {
        let transport = MockLineRPCTransport(unsupportedSearch: true)
        let client = CodexAppServerClient(transport: transport)

        let page = try await client.searchTaskContentPage(
            searchTerm: "legacy title",
            limit: 20
        )

        XCTAssertTrue(page.tasks.isEmpty)
        XCTAssertNil(page.nextCursor)
        let requests = try decodeRequests(await transport.recordedRequests())
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["initialize", "thread/search"]
        )
    }

    func testOrdinaryContentSearchErrorIsNotTreatedAsUnavailable() async throws {
        let transport = MockLineRPCTransport(failSearch: true)
        let client = CodexAppServerClient(transport: transport)

        do {
            _ = try await client.searchTaskContentPage(searchTerm: "proof")
            XCTFail("Expected an RPC error")
        } catch AppServerClientError.rpcError(let code) {
            XCTAssertEqual(code, -32_000)
        }

        let methods = try decodeRequests(await transport.recordedRequests()).compactMap {
            $0["method"] as? String
        }
        XCTAssertEqual(methods, ["initialize", "thread/search"])
    }

    func testBlankContentSearchDoesNotCallThreadSearch() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        let page = try await client.searchTaskContentPage(searchTerm: "  \n ")

        XCTAssertTrue(page.tasks.isEmpty)
        XCTAssertNil(page.nextCursor)
        let methods = try decodeRequests(await transport.recordedRequests()).compactMap {
            $0["method"] as? String
        }
        XCTAssertEqual(methods, ["initialize"])
    }

    func testFirstMessagePageUsesSmallDescendingFullRequest() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(
            transport: transport,
            configuration: .init(messagePageSize: 2)
        )

        let page = try await client.readSelectableMessagePage(threadId: "new")

        XCTAssertEqual(
            page.messages.map(\.role),
            [.user, .assistant, .user, .assistant]
        )
        XCTAssertEqual(
            page.messages.map(\.turnId),
            ["turn-3", "turn-3", "turn-4", "turn-4"]
        )
        XCTAssertEqual(
            page.messages.map(\.text),
            ["Question 3", "Answer 3", "Question 4", "Answer 4"]
        )
        XCTAssertEqual(page.nextCursor, "older-1")
        XCTAssertTrue(page.hasMore)

        let requests = try decodeRequests(await transport.recordedRequests())
        let turnRequests = requests.filter {
            $0["method"] as? String == "thread/turns/list"
        }
        // Returning the first page must not wait for any older page.
        XCTAssertEqual(turnRequests.count, 1)

        let params = try XCTUnwrap(turnRequests[0]["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "new")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(params["itemsView"] as? String, "full")
        XCTAssertEqual(params["limit"] as? Int, 2)
        XCTAssertNil(params["cursor"])
    }

    func testMessagePageUsesOpaqueCursorAndOrdersOlderPageAscending() async throws {
        let transport = MockLineRPCTransport()
        let client = CodexAppServerClient(transport: transport)

        let newest = try await client.readSelectableMessagePage(threadId: "new")
        let older = try await client.readSelectableMessagePage(
            threadId: "new",
            cursor: try XCTUnwrap(newest.nextCursor),
            limit: 3
        )

        XCTAssertEqual(
            older.messages.map(\.turnId),
            ["turn-1", "turn-1", "turn-2", "turn-2"]
        )
        XCTAssertEqual(older.messages.map(\.text), [
            "Question 1", "Answer 1", "Question 2", "Answer 2",
        ])
        XCTAssertNil(older.nextCursor)
        XCTAssertFalse(older.hasMore)

        let requests = try decodeRequests(await transport.recordedRequests()).filter {
            $0["method"] as? String == "thread/turns/list"
        }
        XCTAssertEqual(requests.count, 2)
        let secondParams = try XCTUnwrap(requests[1]["params"] as? [String: Any])
        XCTAssertEqual(secondParams["cursor"] as? String, "older-1")
        XCTAssertEqual(secondParams["sortDirection"] as? String, "desc")
        XCTAssertEqual(secondParams["itemsView"] as? String, "full")
        XCTAssertEqual(secondParams["limit"] as? Int, 3)
    }

    func testMessagePageDeduplicatesTheSameMessageAcrossDifferentTurns() async throws {
        let transport = MockLineRPCTransport(duplicateMessageAcrossTurns: true)
        let client = CodexAppServerClient(transport: transport)

        let page = try await client.readSelectableMessagePage(threadId: "new")

        XCTAssertEqual(
            page.messages.map(\.id),
            ["u3", "shared-answer", "u4"]
        )
        XCTAssertEqual(
            page.messages.map(\.text),
            ["Question 3", "Answer 3", "Question 4"]
        )
    }

    func testUnsupportedTurnsListFailsFast() async throws {
        let transport = MockLineRPCTransport(unsupportedTurnsList: true)
        let client = CodexAppServerClient(transport: transport)

        do {
            _ = try await client.readSelectableMessagePage(threadId: "new")
            XCTFail("Expected fast pagination to be required")
        } catch AppServerClientError.fastPaginationUnavailable {
            // Expected.
        }
        let requests = try decodeRequests(await transport.recordedRequests())
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["initialize", "thread/turns/list"]
        )
    }

    func testOrdinaryTurnsListErrorIsReturnedDirectly() async throws {
        let transport = MockLineRPCTransport(failTurnsList: true)
        let client = CodexAppServerClient(transport: transport)

        do {
            _ = try await client.readSelectableMessagePage(threadId: "new")
            XCTFail("Expected an RPC error")
        } catch AppServerClientError.rpcError(let code) {
            XCTAssertEqual(code, -32_000)
        }
    }

    func testRPCErrorUsesSafeLocalizedDescription() async throws {
        let transport = MockLineRPCTransport(failList: true)
        let client = CodexAppServerClient(transport: transport)

        do {
            _ = try await client.listTasks()
            XCTFail("Expected an RPC error")
        } catch {
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "Codex 无法完成这次读取。"
            )
            XCTAssertFalse(error.localizedDescription.contains("/Users/private"))
        }
    }
}

private actor YieldingInitializationTransport: LineRPCTransport {
    private var starts = 0
    private var initializeRequests = 0
    private var initializedNotifications = 0
    private var listRequests = 0

    func start() async throws {
        starts += 1
    }

    func send(request: Data, id: Int) async throws -> Data {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        let method = try XCTUnwrap(object["method"] as? String)

        if method == "initialize" {
            initializeRequests += 1
            // Force the client actor to become reentrant while every concurrent
            // caller is still attempting its first request. Without a shared
            // initialization task, each caller reaches start + initialize.
            for _ in 0..<100 { await Task.yield() }
            return try response(id: id, result: [:])
        }

        guard method == "thread/list" else {
            XCTFail("Unexpected method \(method)")
            return try response(id: id, result: [:])
        }
        listRequests += 1
        return try response(id: id, result: [
            "data": [],
            "nextCursor": NSNull(),
        ])
    }

    func notify(_ notification: Data) async throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: notification) as? [String: Any]
        )
        if object["method"] as? String == "initialized" {
            initializedNotifications += 1
        }
    }

    func shutdown() async {}

    func recordedCounts() -> (
        starts: Int,
        initializeRequests: Int,
        initializedNotifications: Int,
        listRequests: Int
    ) {
        (starts, initializeRequests, initializedNotifications, listRequests)
    }

    private func response(id: Int, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }
}

private enum ControlledInitializationError: Error {
    case expected
}

private actor FailingThenRecoveringInitializationTransport: LineRPCTransport {
    private var starts = 0
    private var initializeRequests = 0
    private var initializedNotifications = 0
    private var listRequests = 0
    private var shutdowns = 0
    private var firstInitializationStarted = false
    private var firstStartWaiter: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?

    func start() async throws {
        starts += 1
    }

    func send(request: Data, id: Int) async throws -> Data {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        let method = try XCTUnwrap(object["method"] as? String)

        if method == "initialize" {
            initializeRequests += 1
            if initializeRequests == 1 {
                firstInitializationStarted = true
                firstStartWaiter?.resume()
                firstStartWaiter = nil
                await withCheckedContinuation { firstRelease = $0 }
                throw ControlledInitializationError.expected
            }
            return try response(id: id, result: [:])
        }

        guard method == "thread/list" else {
            XCTFail("Unexpected method \(method)")
            return try response(id: id, result: [:])
        }
        listRequests += 1
        return try response(id: id, result: [
            "data": [],
            "nextCursor": NSNull(),
        ])
    }

    func notify(_ notification: Data) async throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: notification) as? [String: Any]
        )
        if object["method"] as? String == "initialized" {
            initializedNotifications += 1
        }
    }

    func shutdown() async {
        shutdowns += 1
    }

    func waitUntilFirstInitializationStarts() async {
        guard !firstInitializationStarted else { return }
        await withCheckedContinuation { firstStartWaiter = $0 }
    }

    func releaseFirstInitializationFailure() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func recordedCounts() -> (
        starts: Int,
        initializeRequests: Int,
        initializedNotifications: Int,
        listRequests: Int,
        shutdowns: Int
    ) {
        (
            starts,
            initializeRequests,
            initializedNotifications,
            listRequests,
            shutdowns
        )
    }

    private func response(id: Int, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }
}

private actor RestartableInitializationTransport: LineRPCTransport {
    private var starts = 0
    private var initializeRequests = 0
    private var initializedNotifications = 0
    private var listRequests = 0
    private var shutdowns = 0
    private var firstInitializationStarted = false
    private var secondInitializationStarted = false
    private var firstStartWaiter: CheckedContinuation<Void, Never>?
    private var secondStartWaiter: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var secondRelease: CheckedContinuation<Void, Never>?

    func start() async throws {
        starts += 1
    }

    func send(request: Data, id: Int) async throws -> Data {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        let method = try XCTUnwrap(object["method"] as? String)

        if method == "initialize" {
            initializeRequests += 1
            if initializeRequests == 1 {
                firstInitializationStarted = true
                firstStartWaiter?.resume()
                firstStartWaiter = nil
                await withCheckedContinuation { firstRelease = $0 }
            } else if initializeRequests == 2 {
                secondInitializationStarted = true
                secondStartWaiter?.resume()
                secondStartWaiter = nil
                await withCheckedContinuation { secondRelease = $0 }
            }
            return try response(id: id, result: [:])
        }

        guard method == "thread/list" else {
            XCTFail("Unexpected method \(method)")
            return try response(id: id, result: [:])
        }
        listRequests += 1
        return try response(id: id, result: [
            "data": [],
            "nextCursor": NSNull(),
        ])
    }

    func notify(_ notification: Data) async throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: notification) as? [String: Any]
        )
        if object["method"] as? String == "initialized" {
            initializedNotifications += 1
        }
    }

    func shutdown() async {
        shutdowns += 1
    }

    func waitUntilFirstInitializationStarts() async {
        guard !firstInitializationStarted else { return }
        await withCheckedContinuation { firstStartWaiter = $0 }
    }

    func waitUntilSecondInitializationStarts() async {
        guard !secondInitializationStarted else { return }
        await withCheckedContinuation { secondStartWaiter = $0 }
    }

    func releaseFirstInitialization() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func releaseSecondInitialization() {
        secondRelease?.resume()
        secondRelease = nil
    }

    func recordedCounts() -> (
        starts: Int,
        initializeRequests: Int,
        initializedNotifications: Int,
        listRequests: Int,
        shutdowns: Int
    ) {
        (
            starts,
            initializeRequests,
            initializedNotifications,
            listRequests,
            shutdowns
        )
    }

    private func response(id: Int, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }
}

private actor MockLineRPCTransport: LineRPCTransport {
    private let failList: Bool
    private let unsupportedTurnsList: Bool
    private let failTurnsList: Bool
    private let unsupportedSearch: Bool
    private let failSearch: Bool
    private let repeatingListCursor: Bool
    private let duplicateMessageAcrossTurns: Bool
    private var events: [String] = []
    private var requests: [Data] = []
    private var listPage = 0
    private var turnsPage = 0

    init(
        failList: Bool = false,
        unsupportedTurnsList: Bool = false,
        failTurnsList: Bool = false,
        unsupportedSearch: Bool = false,
        failSearch: Bool = false,
        repeatingListCursor: Bool = false,
        duplicateMessageAcrossTurns: Bool = false
    ) {
        self.failList = failList
        self.unsupportedTurnsList = unsupportedTurnsList
        self.failTurnsList = failTurnsList
        self.unsupportedSearch = unsupportedSearch
        self.failSearch = failSearch
        self.repeatingListCursor = repeatingListCursor
        self.duplicateMessageAcrossTurns = duplicateMessageAcrossTurns
    }

    func start() async throws {
        events.append("start")
    }

    func send(request: Data, id: Int) async throws -> Data {
        requests.append(request)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: request) as? [String: Any]
        )
        let method = try XCTUnwrap(object["method"] as? String)
        events.append("request:\(method)")

        switch method {
        case "initialize":
            return try response(id: id, result: [:])

        case "thread/list" where failList:
            return try JSONSerialization.data(withJSONObject: [
                "id": id,
                "error": [
                    "code": -32_000,
                    "message": "sensitive /Users/private/transcript text",
                ],
            ])

        case "thread/list":
            defer { listPage += 1 }
            if listPage == 0 {
                return try response(id: id, result: [
                    "data": [[
                        "id": "new",
                        "name": "New task",
                        "preview": "Newest preview",
                        "updatedAt": 200,
                        "turns": [],
                    ]],
                    "nextCursor": "next",
                ])
            }
            return try response(id: id, result: [
                "data": [
                    [
                        "id": "new",
                        "name": "New task",
                        "preview": "Newest preview",
                        "updatedAt": 200,
                        "turns": [],
                    ],
                    [
                        "id": "old",
                        "preview": "Older preview",
                        "updatedAt": 100.0,
                    ],
                ],
                "nextCursor": repeatingListCursor ? "next" : NSNull(),
            ])

        case "thread/search" where unsupportedSearch:
            return try rpcError(
                id: id,
                code: -32_600,
                message: "thread/search requires experimentalApi capability"
            )

        case "thread/search" where failSearch:
            return try rpcError(
                id: id,
                code: -32_000,
                message: "Temporary search failure"
            )

        case "thread/search":
            return try response(id: id, result: [
                "data": [[
                    "thread": [
                        "id": "search-hit",
                        "name": "Matching task",
                        "preview": "Ordinary preview",
                        "updatedAt": 300,
                        "turns": [],
                    ],
                    "snippet": "Matched   conversation\ntext",
                ]],
                "nextCursor": "search-next",
            ])

        case "thread/turns/list" where unsupportedTurnsList:
            return try rpcError(
                id: id,
                code: -32_601,
                message: "Method not found; private /Users/example/task"
            )

        case "thread/turns/list" where failTurnsList:
            return try rpcError(
                id: id,
                code: -32_000,
                message: "Failed to load private /Users/example/task"
            )

        case "thread/turns/list":
            defer { turnsPage += 1 }
            if turnsPage == 0 {
                return try response(id: id, result: [
                    // App Server's desc page is newest-first.
                    "data": [numberedTurn(4), numberedTurn(3)],
                    "nextCursor": "older-1",
                ])
            }
            return try response(id: id, result: [
                // Duplicate turn 2 in one page exercises page-level dedupe.
                "data": [numberedTurn(2), numberedTurn(2), numberedTurn(1)],
                "nextCursor": NSNull(),
            ])

        default:
            XCTFail("Unexpected method \(method)")
            return try response(id: id, result: [:])
        }
    }

    func notify(_ notification: Data) async throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: notification) as? [String: Any]
        )
        events.append("notify:\(try XCTUnwrap(object["method"] as? String))")
    }

    func shutdown() async {
        events.append("shutdown")
    }

    func recordedEvents() -> [String] {
        events
    }

    func recordedRequests() -> [Data] {
        requests
    }

    private func response(id: Int, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }

    private func rpcError(id: Int, code: Int, message: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id,
            "error": ["code": code, "message": message],
        ])
    }

    private func numberedTurn(_ number: Int) -> [String: Any] {
        turn(
            id: "turn-\(number)",
            userID: "u\(number)",
            question: "Question \(number)",
            answerID: duplicateMessageAcrossTurns && number >= 3
                ? "shared-answer"
                : "a\(number)",
            answer: "Answer \(number)"
        )
    }

    private func turn(
        id: String,
        userID: String,
        question: String,
        answerID: String,
        answer: String
    ) -> [String: Any] {
        [
            "id": id,
            "items": [
                [
                    "id": userID,
                    "type": "userMessage",
                    "content": [
                        ["type": "text", "text": question],
                        ["type": "image", "url": "file:///private.png"],
                    ],
                ],
                [
                    "id": "comment-\(id)",
                    "type": "agentMessage",
                    "text": "Commentary",
                    "phase": "commentary",
                ],
                [
                    "id": answerID,
                    "type": "agentMessage",
                    "text": answer,
                    "phase": "final_answer",
                ],
                [
                    "id": "tool-\(id)",
                    "type": "commandExecution",
                    "aggregatedOutput": "secret output",
                ],
            ],
        ]
    }
}

private actor PausedTitleIndexTransport: LineRPCTransport {
    private var firstListStarted = false
    private var firstListWaiter: CheckedContinuation<Void, Never>?
    private var firstListRelease: CheckedContinuation<Void, Never>?
    private var listRequests = 0

    func start() async throws {}

    func send(request: Data, id: Int) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with: request) as? [String: Any]
        let method = object?["method"] as? String
        if method == "initialize" {
            return try response(id: id, result: [:])
        }

        guard method == "thread/list" else {
            return try response(id: id, result: [:])
        }
        listRequests += 1
        if listRequests == 1 {
            firstListStarted = true
            firstListWaiter?.resume()
            firstListWaiter = nil
            await withCheckedContinuation { continuation in
                firstListRelease = continuation
            }
            return try response(id: id, result: [
                "data": [[
                    "id": "first",
                    "name": "First",
                    "preview": "",
                    "updatedAt": 200,
                    "turns": [],
                ]],
                "nextCursor": "next",
            ])
        }
        return try response(id: id, result: [
            "data": [],
            "nextCursor": NSNull(),
        ])
    }

    func notify(_ notification: Data) async throws {}
    func shutdown() async {}

    func waitUntilFirstListRequest() async {
        if firstListStarted { return }
        await withCheckedContinuation { continuation in
            firstListWaiter = continuation
        }
    }

    func releaseFirstListResponse() {
        firstListRelease?.resume()
        firstListRelease = nil
    }

    func listRequestCount() -> Int {
        listRequests
    }

    private func response(id: Int, result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": id, "result": result])
    }
}

private func decodeRequests(_ requests: [Data]) throws -> [[String: Any]] {
    try requests.map { data in
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
