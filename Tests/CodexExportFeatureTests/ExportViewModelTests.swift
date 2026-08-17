import CodexExportCore
import XCTest
@testable import CodexExportFeature

@MainActor
final class ExportViewModelTests: XCTestCase {
    func testInitialRefreshFailureUsesOnlyTheBlockingError() async {
        let client = RefreshFailureClient(
            task: TaskSummary(id: "unused", title: "Unused", updatedAt: Date()),
            failInitialList: true
        )
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.errorMessage, "refresh failed")
        XCTAssertNil(viewModel.statusMessage)
        XCTAssertNil(viewModel.selectedTaskID)
    }

    func testTaskListFailureStaysBlockingAfterMessageLoadFailure() async {
        let task = TaskSummary(
            id: "thread-failed",
            title: "Failed thread",
            updatedAt: Date()
        )
        let client = RefreshFailureClient(task: task, failMessageLoad: true)
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.errorMessage, "message load failed")
        XCTAssertNil(viewModel.statusMessage)

        await viewModel.refresh(reloadSelectedMessages: false)

        XCTAssertEqual(viewModel.errorMessage, "refresh failed")
        XCTAssertNil(viewModel.statusMessage)
    }

    func testRefreshFailureKeepsALoadedEmptyConversationVisible() async {
        let task = TaskSummary(
            id: "thread-empty",
            title: "Empty thread",
            updatedAt: Date()
        )
        let client = RefreshFailureClient(task: task)
        let viewModel = makeViewModel(client: client)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedTaskID, task.id)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.errorMessage)

        await viewModel.refresh(reloadSelectedMessages: false)

        XCTAssertEqual(viewModel.selectedTaskID, task.id)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.statusMessage, "refresh failed")
        XCTAssertTrue(viewModel.statusIsError)
    }

    func testEmptyRefreshInvalidatesALateMessagePage() async throws {
        let task = TaskSummary(
            id: "thread-a",
            title: "Thread A",
            updatedAt: Date()
        )
        let newest = SelectableMessage(
            id: "newest",
            turnId: "turn-newest",
            role: .user,
            text: "newest"
        )
        let staleOlder = SelectableMessage(
            id: "stale-older",
            turnId: "turn-older",
            role: .assistant,
            text: "must not return"
        )
        let client = ControlledCodexClient(
            taskPages: [[task], []],
            firstMessagePage: SelectableMessagePage(
                messages: [newest],
                nextCursor: "older"
            )
        )
        let viewModel = ExportViewModel(
            recentTasks: client,
            taskBrowser: StubTaskBrowser(),
            conversations: client,
            appServerLifecycle: StubLifecycle(),
            imageRenderer: StubRenderer(),
            exportDestination: StubDestination()
        )

        await viewModel.refresh()
        await waitUntil { await client.hasPendingOlderRequest }
        XCTAssertEqual(viewModel.messages.map(\.id), ["newest"])

        await viewModel.refresh(
            reloadSelectedMessages: false,
            preferLatestTask: true,
            resetSelectionToLatestOnReload: true
        )
        XCTAssertNil(viewModel.selectedTaskID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.selectedMessageIDs.isEmpty)
        XCTAssertFalse(viewModel.isLoadingMessages)
        XCTAssertFalse(viewModel.isLoadingOlderMessages)
        XCTAssertFalse(viewModel.isPrefetchingRecentMessages)
        XCTAssertFalse(viewModel.hasMoreMessages)

        await client.resolveOlderPage(SelectableMessagePage(
            messages: [staleOlder],
            nextCursor: nil
        ))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertNil(viewModel.selectedTaskID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.selectedMessageIDs.isEmpty)
    }

    func testUpdateReservationWaitsForExportAndBlocksNewWork() async {
        let client = ExportReadyClient()
        let renderer = ControlledExportRenderer()
        let viewModel = ExportViewModel(
            recentTasks: client,
            taskBrowser: StubTaskBrowser(),
            conversations: client,
            appServerLifecycle: StubLifecycle(),
            imageRenderer: renderer,
            exportDestination: StubDestination()
        )
        await viewModel.refresh()
        XCTAssertTrue(viewModel.canExport)

        let export = Task { await viewModel.copyImage() }
        await renderer.waitUntilStarted()
        XCTAssertTrue(viewModel.isExporting)
        XCTAssertFalse(viewModel.reserveForSoftwareUpdateRestart())

        renderer.finish()
        await export.value
        XCTAssertFalse(viewModel.isExporting)
        XCTAssertTrue(viewModel.reserveForSoftwareUpdateRestart())
        XCTAssertTrue(viewModel.isQuiescingForSoftwareUpdate)
        XCTAssertFalse(viewModel.canExport)

        viewModel.cancelSoftwareUpdateRestartReservation()
        XCTAssertFalse(viewModel.isQuiescingForSoftwareUpdate)
        XCTAssertTrue(viewModel.canExport)
    }

    private func makeViewModel<Client>(client: Client) -> ExportViewModel
    where Client: RecentTaskServing & ConversationServing {
        ExportViewModel(
            recentTasks: client,
            taskBrowser: StubTaskBrowser(),
            conversations: client,
            appServerLifecycle: StubLifecycle(),
            imageRenderer: StubRenderer(),
            exportDestination: StubDestination()
        )
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private actor RefreshFailureClient: RecentTaskServing, ConversationServing {
    private let task: TaskSummary
    private let failInitialList: Bool
    private let failMessageLoad: Bool
    private var listCallCount = 0

    init(
        task: TaskSummary,
        failInitialList: Bool = false,
        failMessageLoad: Bool = false
    ) {
        self.task = task
        self.failInitialList = failInitialList
        self.failMessageLoad = failMessageLoad
    }

    func listTasks() async throws -> [TaskSummary] {
        listCallCount += 1
        if listCallCount == 1, failInitialList {
            throw RefreshFailure.list
        }
        if listCallCount == 1 { return [task] }
        throw RefreshFailure.list
    }

    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        if failMessageLoad {
            throw RefreshFailure.message
        }
        return SelectableMessagePage(messages: [], nextCursor: nil)
    }
}

private enum RefreshFailure: LocalizedError {
    case list
    case message

    var errorDescription: String? {
        switch self {
        case .list: return "refresh failed"
        case .message: return "message load failed"
        }
    }
}

private actor ControlledCodexClient: RecentTaskServing, ConversationServing {
    private var taskPages: [[TaskSummary]]
    private let firstMessagePage: SelectableMessagePage
    private var olderContinuation: CheckedContinuation<SelectableMessagePage, Error>?

    init(
        taskPages: [[TaskSummary]],
        firstMessagePage: SelectableMessagePage
    ) {
        self.taskPages = taskPages
        self.firstMessagePage = firstMessagePage
    }

    var hasPendingOlderRequest: Bool { olderContinuation != nil }

    func resolveOlderPage(_ page: SelectableMessagePage) {
        olderContinuation?.resume(returning: page)
        olderContinuation = nil
    }

    func listTasks() async throws -> [TaskSummary] {
        guard !taskPages.isEmpty else { return [] }
        return taskPages.removeFirst()
    }

    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        guard cursor != nil else { return firstMessagePage }
        return try await withCheckedThrowingContinuation { continuation in
            olderContinuation = continuation
        }
    }

}

private actor StubTaskBrowser: TaskBrowserServing {
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

private actor StubLifecycle: AppServerLifecycle {
    func shutdown() async {}
}

private actor ExportReadyClient: RecentTaskServing, ConversationServing {
    private let task = TaskSummary(
        id: "export-ready",
        title: "Export ready",
        updatedAt: Date()
    )

    func listTasks() async throws -> [TaskSummary] { [task] }

    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        SelectableMessagePage(
            messages: [
                SelectableMessage(
                    id: "message",
                    turnId: "turn",
                    role: .user,
                    text: "export me"
                ),
            ],
            nextCursor: nil
        )
    }
}

@MainActor
private final class ControlledExportRenderer: ConversationImageRendering {
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var renderContinuation: CheckedContinuation<RenderResult, Error>?

    func render(
        messages: [RenderMessage],
        progress: ((Double) -> Void)?
    ) async throws -> RenderResult {
        didStart = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            renderContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        renderContinuation?.resume(returning: RenderResult(
            pngData: Data(),
            width: 1,
            height: 1,
            warning: nil
        ))
        renderContinuation = nil
    }
}

@MainActor
private final class StubRenderer: ConversationImageRendering {
    func render(
        messages: [RenderMessage],
        progress: ((Double) -> Void)?
    ) async throws -> RenderResult {
        RenderResult(pngData: Data(), width: 1, height: 1, warning: nil)
    }
}

@MainActor
private final class StubDestination: ImageExportDestination {
    func copy(_ result: RenderResult) throws {}
    func save(_ result: RenderResult) async throws -> URL {
        URL(fileURLWithPath: "/tmp/unused.png")
    }
}
