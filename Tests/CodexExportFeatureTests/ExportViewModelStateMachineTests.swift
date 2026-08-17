import CodexExportCore
import Foundation
import XCTest
@testable import CodexExportFeature

@MainActor
final class ExportViewModelStateMachineTests: XCTestCase {
    func testTaskSearchPublishesTitleMatchesBeforeBodyResultsAndKeepsPriority() async {
        let titleMatch = TaskSummary(
            id: "title-match",
            title: "Needle in the title",
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let contentMatch = TaskSummary(
            id: "content-match",
            title: "Unrelated title",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let taskBrowser = ControlledSearchTaskBrowser(titleIndex: [titleMatch])
        let client = EmptyTaskConversationClient()
        let viewModel = makeViewModel(client: client, taskBrowser: taskBrowser)

        viewModel.presentTaskBrowser()
        viewModel.updateTaskBrowserQuery("needle")

        let requestedTerm = await taskBrowser.waitForContentSearchRequest()
        XCTAssertEqual(requestedTerm, "needle")
        XCTAssertTrue(viewModel.isLoadingTaskBrowser)
        XCTAssertEqual(viewModel.taskBrowserResults.map(\.id), [titleMatch.id])

        await taskBrowser.resolveContentSearch(TaskSummaryPage(
            tasks: [titleMatch, contentMatch],
            nextCursor: nil
        ))
        await waitUntil { !viewModel.isLoadingTaskBrowser }

        XCTAssertNil(viewModel.taskBrowserError)
        XCTAssertEqual(
            viewModel.taskBrowserResults.map(\.id),
            [titleMatch.id, contentMatch.id]
        )
        XCTAssertEqual(
            viewModel.taskBrowserResults.filter { $0.id == titleMatch.id }.count,
            1
        )
        viewModel.dismissTaskBrowser()
    }

    func testSelectAllLoadsEveryPageThenCancelRestoresLatestTurn() async {
        let latestMessageIDs: Set<String> = ["latest-user", "latest-assistant"]
        let client = PagedConversationClient(
            initialPage: SelectableMessagePage(
                messages: fiveVisibleTurns(),
                nextCursor: "older-1"
            ),
            olderPages: [
                "older-1": SelectableMessagePage(
                    messages: [message("older-middle", turn: "older-middle")],
                    nextCursor: "older-2"
                ),
                "older-2": SelectableMessagePage(
                    messages: [message("oldest", turn: "oldest")],
                    nextCursor: nil
                ),
            ]
        )
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasMoreMessages)
        XCTAssertEqual(viewModel.selectedMessageIDs, latestMessageIDs)

        viewModel.toggleSelectAllMessages()
        await waitUntil {
            viewModel.isWholeConversationSelectionActive
                && !viewModel.isSelectingAll
        }

        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertEqual(
            viewModel.selectedMessageIDs,
            Set(viewModel.messages.map(\.id))
        )
        let selectAllCursors = await client.requestedCursors()
        XCTAssertEqual(selectAllCursors, [nil, "older-1", "older-2"])

        viewModel.toggleSelectAllMessages()

        XCTAssertFalse(viewModel.isWholeConversationSelectionActive)
        XCTAssertTrue(viewModel.canSelectAll)
        XCTAssertEqual(viewModel.selectedMessageIDs, latestMessageIDs)
        XCTAssertNil(viewModel.statusMessage)
    }

    func testOrdinaryOlderLoadingAdvancesCursorUntilHistoryIsComplete() async {
        let client = PagedConversationClient(
            initialPage: SelectableMessagePage(
                messages: fiveVisibleTurns(),
                nextCursor: "older-1"
            ),
            olderPages: [
                "older-1": SelectableMessagePage(
                    messages: [message("older-middle", turn: "older-middle")],
                    nextCursor: "older-2"
                ),
                "older-2": SelectableMessagePage(
                    messages: [message("oldest", turn: "oldest")],
                    nextCursor: nil
                ),
            ]
        )
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasMoreMessages)

        viewModel.loadMoreOlderMessages()
        await waitUntil {
            viewModel.messages.contains(where: { $0.id == "older-middle" })
        }

        XCTAssertTrue(viewModel.hasMoreMessages)
        XCTAssertNil(viewModel.olderMessagesError)
        let firstLoadCursors = await client.requestedCursors()
        XCTAssertEqual(firstLoadCursors, [nil, "older-1"])

        viewModel.loadMoreOlderMessages()
        await waitUntil {
            viewModel.messages.contains(where: { $0.id == "oldest" })
        }

        XCTAssertFalse(viewModel.hasMoreMessages)
        XCTAssertNil(viewModel.olderMessagesError)
        let completedCursors = await client.requestedCursors()
        XCTAssertEqual(completedCursors, [nil, "older-1", "older-2"])
    }

    private func makeViewModel<Client>(
        client: Client,
        taskBrowser: any TaskBrowserServing = EmptyTaskBrowser()
    ) -> ExportViewModel where Client: RecentTaskServing & ConversationServing {
        ExportViewModel(
            recentTasks: client,
            taskBrowser: taskBrowser,
            conversations: client,
            appServerLifecycle: StateMachineStubLifecycle(),
            imageRenderer: StateMachineStubRenderer(),
            exportDestination: StateMachineStubDestination()
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private func fiveVisibleTurns() -> [SelectableMessage] {
        [
            message("recent-1", turn: "recent-1"),
            message("recent-2", turn: "recent-2"),
            message("recent-3", turn: "recent-3"),
            message("recent-4", turn: "recent-4"),
            message("latest-user", turn: "latest", role: .user),
            message("latest-assistant", turn: "latest", role: .assistant),
        ]
    }

    private func message(
        _ id: String,
        turn: String,
        role: MessageRole = .user
    ) -> SelectableMessage {
        SelectableMessage(id: id, turnId: turn, role: role, text: id)
    }
}

private actor ControlledSearchTaskBrowser: TaskBrowserServing {
    private let titleIndex: [TaskSummary]
    private var contentSearchTerm: String?
    private var contentSearchWaiters: [CheckedContinuation<String, Never>] = []
    private var contentSearchContinuation:
        CheckedContinuation<TaskSummaryPage, Error>?

    init(titleIndex: [TaskSummary]) {
        self.titleIndex = titleIndex
    }

    func listTaskPage(
        cursor: String?,
        limit: Int
    ) async throws -> TaskSummaryPage {
        TaskSummaryPage(tasks: [], nextCursor: nil)
    }

    func listTaskTitleIndex() async throws -> [TaskSummary] {
        titleIndex
    }

    func searchTaskContentPage(
        cursor: String?,
        searchTerm: String,
        limit: Int
    ) async throws -> TaskSummaryPage {
        contentSearchTerm = searchTerm
        let waiters = contentSearchWaiters
        contentSearchWaiters = []
        for waiter in waiters {
            waiter.resume(returning: searchTerm)
        }
        return try await withCheckedThrowingContinuation { continuation in
            precondition(contentSearchContinuation == nil)
            contentSearchContinuation = continuation
        }
    }

    func waitForContentSearchRequest() async -> String {
        if let contentSearchTerm { return contentSearchTerm }
        return await withCheckedContinuation { continuation in
            contentSearchWaiters.append(continuation)
        }
    }

    func resolveContentSearch(_ page: TaskSummaryPage) {
        precondition(contentSearchContinuation != nil)
        contentSearchContinuation?.resume(returning: page)
        contentSearchContinuation = nil
    }
}

private actor EmptyTaskConversationClient:
    RecentTaskServing,
    ConversationServing {
    func listTasks() async throws -> [TaskSummary] { [] }

    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        SelectableMessagePage(messages: [], nextCursor: nil)
    }
}

private actor PagedConversationClient: RecentTaskServing, ConversationServing {
    private let task = TaskSummary(
        id: "thread-paged",
        title: "Paged thread",
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    private let initialPage: SelectableMessagePage
    private let olderPages: [String: SelectableMessagePage]
    private var cursors: [String?] = []

    init(
        initialPage: SelectableMessagePage,
        olderPages: [String: SelectableMessagePage]
    ) {
        self.initialPage = initialPage
        self.olderPages = olderPages
    }

    func listTasks() async throws -> [TaskSummary] { [task] }

    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        cursors.append(cursor)
        guard let cursor else { return initialPage }
        guard let page = olderPages[cursor] else {
            throw StateMachineTestError.unexpectedCursor(cursor)
        }
        return page
    }

    func requestedCursors() -> [String?] { cursors }
}

private actor EmptyTaskBrowser: TaskBrowserServing {
    func listTaskPage(
        cursor: String?,
        limit: Int
    ) async throws -> TaskSummaryPage {
        TaskSummaryPage(tasks: [], nextCursor: nil)
    }

    func listTaskTitleIndex() async throws -> [TaskSummary] { [] }

    func searchTaskContentPage(
        cursor: String?,
        searchTerm: String,
        limit: Int
    ) async throws -> TaskSummaryPage {
        TaskSummaryPage(tasks: [], nextCursor: nil)
    }
}

private actor StateMachineStubLifecycle: AppServerLifecycle {
    func shutdown() async {}
}

@MainActor
private final class StateMachineStubRenderer: ConversationImageRendering {
    func render(
        messages: [RenderMessage],
        progress: ((Double) -> Void)?
    ) async throws -> RenderResult {
        RenderResult(pngData: Data(), width: 1, height: 1, warning: nil)
    }
}

@MainActor
private final class StateMachineStubDestination: ImageExportDestination {
    func copy(_ result: RenderResult) throws {}

    func save(_ result: RenderResult) async throws -> URL {
        URL(fileURLWithPath: "/tmp/unused-state-machine.png")
    }
}

private enum StateMachineTestError: Error {
    case unexpectedCursor(String)
}
