import CodexExportCore
import Foundation

private enum TaskBrowserPagingError: LocalizedError {
    case repeatedCursor

    var errorDescription: String? {
        "Codex 返回了重复的分页位置。"
    }
}

@MainActor
public final class ExportViewModel: ObservableObject {
    private struct StatusNotice {
        let message: String
        let isError: Bool
        let updatedAt: TimeInterval
    }

    @Published private(set) var tasks: [TaskSummary] = []
    @Published private(set) var selectedTaskID: String?
    @Published public private(set) var isTaskBrowserPresented = false
    @Published private(set) var taskBrowserResults: [TaskSummary] = []
    @Published private(set) var taskBrowserQuery = ""
    @Published private(set) var isLoadingTaskBrowser = false
    @Published private(set) var taskBrowserError: String?
    @Published private(set) var messages: [SelectableMessage] = []
    @Published private(set) var selectedMessageIDs: Set<String> = []
    @Published private(set) var isWholeConversationSelectionActive = false
    @Published private(set) var isLoadingTasks = false
    @Published private(set) var isPrefetchingRecentMessages = false
    @Published private(set) var isLoadingOlderMessages = false
    @Published private(set) var isSelectingAll = false
    @Published private var nextOlderMessagesCursor: String?
    @Published private(set) var olderMessagesError: String?
    @Published private(set) var isExporting = false
    @Published private(set) var isQuiescingForSoftwareUpdate = false
    @Published private(set) var errorMessage: String?
    @Published private var statusNotice: StatusNotice?
    @Published private(set) var scrollTargetID: String?

    private let recentTasks: any RecentTaskServing
    private let taskBrowser: any TaskBrowserServing
    private let conversations: any ConversationServing
    private let appServerLifecycle: any AppServerLifecycle
    private let imageRenderer: any ConversationImageRendering
    private let exportDestination: any ImageExportDestination
    private var loadedTaskID: String?
    @Published private var loadingTaskID: String?
    private var selectionAnchorID: String?
    private var shouldSelectFirstVisibleTurn = false
    private var messageLoadGeneration = UUID()
    private var recentMessagesPrefetchTask: Task<Void, Never>?
    private var olderMessagesTask: Task<Void, Never>?
    private var taskBrowserPageTask: Task<Void, Never>?
    private var taskBrowserGeneration = UUID()
    private var taskBrowserNextCursor: String?
    private var taskBrowserSearchResults = PrioritizedTaskSearchResults()
    private var taskBrowserActiveTitleIndex: [TaskSummary]?
    private var taskBrowserTitleStageCompleted = false
    private var taskBrowserSeenCursors = Set<String>()
    private var taskBrowserPendingLoadMore = false
    private var didLoadTasks = false
    private var pendingPresentationRefresh = false

    private static let initialTurnCount = 1
    private static let defaultVisibleTurnCount = 5
    private static let taskBrowserPageSize = 20
    private static let maximumEmptyOlderPageHops = 2

    public init(
        client: any CodexAppServing,
        imageRenderer: any ConversationImageRendering,
        exportDestination: any ImageExportDestination
    ) {
        recentTasks = client
        taskBrowser = client
        conversations = client
        appServerLifecycle = client
        self.imageRenderer = imageRenderer
        self.exportDestination = exportDestination
    }

    init(
        recentTasks: any RecentTaskServing,
        taskBrowser: any TaskBrowserServing,
        conversations: any ConversationServing,
        appServerLifecycle: any AppServerLifecycle,
        imageRenderer: any ConversationImageRendering,
        exportDestination: any ImageExportDestination
    ) {
        self.recentTasks = recentTasks
        self.taskBrowser = taskBrowser
        self.conversations = conversations
        self.appServerLifecycle = appServerLifecycle
        self.imageRenderer = imageRenderer
        self.exportDestination = exportDestination
    }

    var selectedCount: Int { selectedMessageIDs.count }
    var hasMoreMessages: Bool { nextOlderMessagesCursor != nil }
    var isLoadingMessages: Bool { loadingTaskID != nil }
    var statusMessage: String? { statusNotice?.message }
    var statusIsError: Bool { statusNotice?.isError ?? false }
    var statusUpdatedAt: TimeInterval? { statusNotice?.updatedAt }
    var selectedTaskDisplayName: String {
        guard let selectedTaskID,
              let task = tasks.first(where: { $0.id == selectedTaskID }) else {
            return tasks.isEmpty ? "没有可导出的任务" : "选择任务"
        }
        return task.displayName
    }
    var canSelectAll: Bool {
        !messages.isEmpty
            && loadedTaskID == selectedTaskID
            && !isQuiescingForSoftwareUpdate
            && !isLoadingMessages
            && !isLoadingOlderMessages
            && !isExporting
    }
    var canExport: Bool {
        !selectedMessageIDs.isEmpty
            && loadedTaskID == selectedTaskID
            && !isQuiescingForSoftwareUpdate
            && !isLoadingMessages
            && !isSelectingAll
            && !isExporting
    }
    var canAutomaticallyLoadOlderMessages: Bool {
        hasMoreMessages
            && loadedTaskID == selectedTaskID
            && !isQuiescingForSoftwareUpdate
            && !isLoadingTasks
            && !isLoadingMessages
            && !isPrefetchingRecentMessages
            && !isLoadingOlderMessages
            && !isSelectingAll
            && !isExporting
            && !isTaskBrowserPresented
            && olderMessagesError == nil
    }
    var canQueueAutomaticOlderMessages: Bool {
        hasMoreMessages
            && loadedTaskID == selectedTaskID
            && !isQuiescingForSoftwareUpdate
            && !isLoadingTasks
            && !isLoadingMessages
            && !isSelectingAll
            && !isExporting
            && !isTaskBrowserPresented
            && olderMessagesError == nil
    }

    public func loadIfNeeded() async {
        guard !isQuiescingForSoftwareUpdate else { return }
        // A menu-bar app may stay alive for days. Refresh the lightweight
        // ten-task index whenever the popover opens so its default remains the
        // most recently active conversation. Treat each presentation as a new
        // export action, so cached content immediately returns to its latest
        // visible turn instead of preserving an older ad-hoc selection.
        if isSelectingAll {
            cancelLoadingOlderMessages()
        }
        selectLatestTurn()
        pendingPresentationRefresh = true
        await runPendingPresentationRefreshIfPossible()
    }

    private func runPendingPresentationRefreshIfPossible() async {
        guard pendingPresentationRefresh, !isLoadingTasks else { return }
        pendingPresentationRefresh = false
        await refresh(
            reloadSelectedMessages: false,
            preferLatestTask: true,
            resetSelectionToLatestOnReload: true
        )
    }

    func refresh(
        reloadSelectedMessages: Bool = true,
        preferLatestTask: Bool = false,
        resetSelectionToLatestOnReload: Bool = false
    ) async {
        guard !isLoadingTasks, !isQuiescingForSoftwareUpdate else { return }
        let isInitialTaskLoad = !didLoadTasks
        let previousTasks = tasks
        if !preferLatestTask || reloadSelectedMessages {
            cancelMessageLoads(preservingOlderCursor: true)
        }
        isLoadingTasks = true
        errorMessage = nil
        setStatus(nil)
        defer {
            isLoadingTasks = false
            if pendingPresentationRefresh {
                Task { [weak self] in
                    await self?.runPendingPresentationRefreshIfPossible()
                }
            }
        }

        do {
            let summaries = try await recentTasks.listTasks()
            var refreshedTasks = summaries
            if !preferLatestTask,
               let current = selectedTaskID,
               let selectedTask = previousTasks.first(where: { $0.id == current }),
               !refreshedTasks.contains(where: { $0.id == current }) {
                // A task chosen through full-history search may be older than
                // the compact recent index. Keep its summary available so a
                // retry refresh neither loses the title nor jumps away.
                refreshedTasks.append(selectedTask)
            }
            tasks = refreshedTasks
            didLoadTasks = true

            guard !tasks.isEmpty else {
                resetConversationState()
                return
            }

            let preferredID: String
            if !preferLatestTask,
               !isInitialTaskLoad,
               let current = selectedTaskID,
               tasks.contains(where: { $0.id == current }) {
                preferredID = current
            } else {
                // Tasks arrive newest-first. Opening the popover should show
                // the conversation the user was most likely just viewing,
                // while explicit retry refreshes preserve a current choice.
                preferredID = tasks[0].id
            }

            selectedTaskID = preferredID
            let previousUpdatedAt = previousTasks.first {
                $0.id == preferredID
            }?.updatedAt
            let refreshedUpdatedAt = tasks.first {
                $0.id == preferredID
            }?.updatedAt
            let taskChangedSinceLastPresentation = preferLatestTask
                && previousUpdatedAt != refreshedUpdatedAt
            if reloadSelectedMessages
                || loadedTaskID != preferredID
                || messages.isEmpty
                || taskChangedSinceLastPresentation {
                await selectTask(
                    id: preferredID,
                    force: true,
                    resetSelectionToLatest: resetSelectionToLatestOnReload
                )
            }
        } catch {
            let message = friendlyMessage(for: error)
            if tasks.isEmpty {
                errorMessage = message
                resetConversationState()
            } else if let selectedTaskID,
                      loadedTaskID == selectedTaskID {
                // A failed index refresh must not replace a successfully
                // loaded conversation, including a valid empty conversation,
                // with the blocking error screen.
                errorMessage = nil
                setStatus(message, isError: true)
            } else {
                errorMessage = message
            }
        }
    }

    func selectTask(
        id: String,
        force: Bool = false,
        resetSelectionToLatest: Bool = false
    ) async {
        guard selectedTaskID == id else { return }
        if !force {
            if loadedTaskID == id, !messages.isEmpty { return }
            if loadingTaskID == id { return }
        }

        let isReloadingLoadedTask = loadedTaskID == id && !messages.isEmpty
        let hadCompleteHistory = isReloadingLoadedTask
            && !hasMoreMessages
            && olderMessagesError == nil
        let preservedSelection = isReloadingLoadedTask ? selectedMessageIDs : []
        let preservedWholeConversationSelectionActive = isReloadingLoadedTask
            && isWholeConversationSelectionActive
        let preservedAnchor = isReloadingLoadedTask ? selectionAnchorID : nil
        let preservedOlderCursor = isReloadingLoadedTask
            ? nextOlderMessagesCursor
            : nil
        if isReloadingLoadedTask {
            cancelMessageLoads()
        } else {
            resetConversationState(selecting: id)
        }

        selectedTaskID = id
        loadingTaskID = id
        errorMessage = nil
        setStatus(nil)
        olderMessagesError = nil
        nextOlderMessagesCursor = nil

        let generation = UUID()
        messageLoadGeneration = generation

        do {
            // Paint the newest turn first. Older turns can contain very large
            // tool histories even though this exporter ultimately discards
            // those items, so the rest of the default five-turn window is
            // prefetched without blocking the first usable screen.
            let page = try await conversations.readSelectableMessagePage(
                threadId: id,
                cursor: nil,
                limit: Self.initialTurnCount
            )
            if messageLoadGeneration == generation, selectedTaskID == id {
                if isReloadingLoadedTask {
                    mergeNewestMessages(page.messages)
                } else {
                    messages = page.messages
                }
                loadedTaskID = id
                if isReloadingLoadedTask {
                    if resetSelectionToLatest {
                        selectLatestTurn()
                    } else if preservedWholeConversationSelectionActive,
                              hadCompleteHistory {
                        selectedMessageIDs = Set(messages.map(\.id))
                        selectionAnchorID = messages.last?.id
                        isWholeConversationSelectionActive = true
                    } else {
                        let validIDs = Set(messages.map(\.id))
                        selectedMessageIDs = preservedSelection.intersection(validIDs)
                        isWholeConversationSelectionActive = false
                        selectionAnchorID = preservedAnchor.flatMap {
                            validIDs.contains($0) ? $0 : nil
                        }
                    }
                } else if messages.isEmpty {
                    shouldSelectFirstVisibleTurn = true
                } else {
                    selectLatestTurn()
                }

                loadingTaskID = nil
                if hadCompleteHistory {
                    nextOlderMessagesCursor = nil
                } else if let preservedOlderCursor {
                    nextOlderMessagesCursor = preservedOlderCursor
                } else {
                    nextOlderMessagesCursor = page.nextCursor
                }

                let visibleTurnCount = Set(messages.map(\.turnId)).count
                let missingDefaultTurns = max(
                    0,
                    Self.defaultVisibleTurnCount - visibleTurnCount
                )
                if hasMoreMessages,
                   missingDefaultTurns > 0,
                   let cursor = nextOlderMessagesCursor {
                    startPrefetchingRecentMessages(
                        threadID: id,
                        cursor: cursor,
                        generation: generation,
                        turnLimit: missingDefaultTurns
                    )
                }
            }
        } catch {
            if messageLoadGeneration == generation {
                let message = friendlyMessage(for: error)
                if isReloadingLoadedTask {
                    setStatus(message, isError: true)
                    nextOlderMessagesCursor = preservedOlderCursor
                } else {
                    loadedTaskID = nil
                    errorMessage = message
                }
            }
        }

        if messageLoadGeneration == generation {
            loadingTaskID = nil
        }
    }

    func presentTaskBrowser() {
        guard !isExporting, !isQuiescingForSoftwareUpdate else { return }
        // Keep title lookups fresh for each browser presentation, then reuse
        // that lightweight index while the user refines the same search.
        taskBrowserActiveTitleIndex = nil
        isTaskBrowserPresented = true
        startTaskBrowserQuery("", debounce: false)
    }

    public func dismissTaskBrowser() {
        taskBrowserPageTask?.cancel()
        taskBrowserPageTask = nil
        taskBrowserGeneration = UUID()
        taskBrowserPendingLoadMore = false
        isTaskBrowserPresented = false
        isLoadingTaskBrowser = false
    }

    func updateTaskBrowserQuery(_ query: String) {
        guard isTaskBrowserPresented else { return }
        startTaskBrowserQuery(query, debounce: true)
    }

    func loadMoreTaskBrowserResults(approaching taskID: String) {
        guard let index = taskBrowserResults.firstIndex(where: {
            $0.id == taskID
        }), index >= max(0, taskBrowserResults.count - 5) else {
            return
        }
        if isLoadingTaskBrowser {
            // A newly appended tail row can appear while the request that
            // produced it is still marked loading. Remember that onAppear so
            // it is not lost when the row remains visible after completion.
            if taskBrowserNextCursor != nil {
                taskBrowserPendingLoadMore = true
            }
            return
        }
        loadNextTaskBrowserPage()
    }

    func retryTaskBrowser() {
        guard isTaskBrowserPresented else { return }
        taskBrowserError = nil
        if !taskBrowserQuery.isEmpty,
           taskBrowserTitleStageCompleted,
           taskBrowserNextCursor == nil {
            retryInitialTaskBrowserContentSearch()
            return
        }
        if taskBrowserResults.isEmpty || taskBrowserNextCursor == nil {
            startTaskBrowserQuery(taskBrowserQuery, debounce: false)
        } else {
            loadNextTaskBrowserPage()
        }
    }

    func selectTaskFromBrowser(_ task: TaskSummary) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
        selectedTaskID = task.id
        dismissTaskBrowser()
        Task { [weak self] in
            await self?.selectTask(id: task.id)
        }
    }

    func isSelected(_ id: String) -> Bool {
        selectedMessageIDs.contains(id)
    }

    func toggleMessage(_ id: String, extendingRange: Bool) {
        guard let clickedIndex = messages.firstIndex(where: { $0.id == id }) else { return }
        shouldSelectFirstVisibleTurn = false
        isWholeConversationSelectionActive = false
        let shouldSelect = !selectedMessageIDs.contains(id)

        if extendingRange,
           let anchorID = selectionAnchorID,
           let anchorIndex = messages.firstIndex(where: { $0.id == anchorID }) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            for index in range {
                let messageID = messages[index].id
                if shouldSelect {
                    selectedMessageIDs.insert(messageID)
                } else {
                    selectedMessageIDs.remove(messageID)
                }
            }
        } else if shouldSelect {
            selectedMessageIDs.insert(id)
        } else {
            selectedMessageIDs.remove(id)
        }

        if !extendingRange || selectionAnchorID == nil {
            selectionAnchorID = id
        }
        let allMessageIDs = Set(messages.map(\.id))
        isWholeConversationSelectionActive = !messages.isEmpty
            && !hasMoreMessages
            && !isLoadingMessages
            && !isPrefetchingRecentMessages
            && !isLoadingOlderMessages
            && selectedMessageIDs == allMessageIDs
        setStatus(nil)
    }

    func toggleSelectAllMessages() {
        guard canSelectAll else { return }
        shouldSelectFirstVisibleTurn = false
        cancelRecentMessagesPrefetch()
        if isWholeConversationSelectionActive {
            selectLatestTurn()
        } else if hasMoreMessages {
            guard let cursor = nextOlderMessagesCursor,
                  let threadID = selectedTaskID else {
                olderMessagesError = "无法继续读取完整会话，请刷新后重试。"
                return
            }
            isSelectingAll = true
            setStatus("正在读取完整会话…")
            startLoadingOlderMessages(
                threadID: threadID,
                cursor: cursor,
                generation: messageLoadGeneration,
                loadAll: true
            )
        } else {
            selectedMessageIDs = Set(messages.map(\.id))
            selectionAnchorID = messages.last?.id
            isWholeConversationSelectionActive = true
            setStatus(nil)
        }
    }

    func selectLatestTurn() {
        isWholeConversationSelectionActive = false
        guard !messages.isEmpty else {
            selectedMessageIDs = []
            selectionAnchorID = nil
            scrollTargetID = nil
            return
        }
        shouldSelectFirstVisibleTurn = false

        let turnID = messages.last?.turnId
        guard let turnID else { return }

        let turnMessages = messages.filter { $0.turnId == turnID }
        selectedMessageIDs = Set(turnMessages.map(\.id))
        selectionAnchorID = turnMessages.first?.id
        scrollTargetID = turnMessages.last?.id
        setStatus(nil)
    }

    func clearScrollTarget() {
        scrollTargetID = nil
    }

    func copyImage() async {
        await export(action: .copy)
    }

    func saveImage() async {
        await export(action: .save)
    }

    public func shutdown() async {
        dismissTaskBrowser()
        cancelMessageLoads()
        await appServerLifecycle.shutdown()
    }

    /// Atomically prevents new export work before the updater starts its
    /// detached installer. Read-only paging can be cancelled; an active image
    /// export must finish before this reservation succeeds.
    public func reserveForSoftwareUpdateRestart() -> Bool {
        guard !isQuiescingForSoftwareUpdate, !isExporting else { return false }
        isQuiescingForSoftwareUpdate = true
        dismissTaskBrowser()
        cancelMessageLoads(preservingOlderCursor: true)
        return true
    }

    public func cancelSoftwareUpdateRestartReservation() {
        isQuiescingForSoftwareUpdate = false
    }

    private func startTaskBrowserQuery(
        _ rawQuery: String,
        debounce: Bool
    ) {
        taskBrowserPageTask?.cancel()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        taskBrowserGeneration = generation
        taskBrowserQuery = query
        taskBrowserNextCursor = nil
        taskBrowserSearchResults = PrioritizedTaskSearchResults()
        taskBrowserResults = []
        taskBrowserTitleStageCompleted = false
        taskBrowserSeenCursors = []
        taskBrowserPendingLoadMore = false
        taskBrowserError = nil
        isLoadingTaskBrowser = true

        taskBrowserPageTask = Task { [weak self] in
            if debounce, !query.isEmpty {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
            await self?.loadFirstTaskBrowserPage(
                query: query,
                generation: generation
            )
        }
    }

    private func loadFirstTaskBrowserPage(
        query: String,
        generation: UUID
    ) async {
        do {
            if query.isEmpty {
                let page = try await taskBrowser.listTaskPage(
                    cursor: nil,
                    limit: Self.taskBrowserPageSize
                )
                guard !Task.isCancelled,
                      isTaskBrowserPresented,
                      taskBrowserGeneration == generation else {
                    return
                }
                taskBrowserResults = deduplicatingTasks(page.tasks)
                taskBrowserNextCursor = page.nextCursor
                taskBrowserError = nil
            } else {
                try await loadPrioritizedTaskBrowserSearch(
                    query: query,
                    generation: generation
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard isTaskBrowserPresented,
                  taskBrowserGeneration == generation else {
                return
            }
            taskBrowserError = friendlyMessage(for: error)
        }

        finishTaskBrowserPageLoad(generation: generation)
    }

    private func loadPrioritizedTaskBrowserSearch(
        query: String,
        generation: UUID
    ) async throws {
        let titleIndex: [TaskSummary]
        if let taskBrowserActiveTitleIndex {
            titleIndex = taskBrowserActiveTitleIndex
        } else {
            titleIndex = try await taskBrowser.listTaskTitleIndex()
        }
        guard !Task.isCancelled,
              isTaskBrowserPresented,
              taskBrowserGeneration == generation else {
            throw CancellationError()
        }
        taskBrowserActiveTitleIndex = titleIndex

        var results = PrioritizedTaskSearchResults()
        results.appendTitleMatches(titleIndex.filter {
            $0.titleMatches(query)
        })
        taskBrowserSearchResults = results
        taskBrowserResults = results.tasks
        taskBrowserTitleStageCompleted = true
        // Publish every visible-title match before starting the slower
        // conversation-body search.
        taskBrowserError = nil
        await Task.yield()

        taskBrowserNextCursor = nil
        try await loadTaskBrowserContentPages(
            startingAt: nil,
            query: query,
            generation: generation
        )
    }

    private func retryInitialTaskBrowserContentSearch() {
        guard isTaskBrowserPresented,
              !isLoadingTaskBrowser,
              !taskBrowserQuery.isEmpty else {
            return
        }
        let generation = taskBrowserGeneration
        let query = taskBrowserQuery
        isLoadingTaskBrowser = true
        taskBrowserPageTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadTaskBrowserContentPages(
                    startingAt: nil,
                    query: query,
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isTaskBrowserPresented,
                      self.taskBrowserGeneration == generation else {
                    return
                }
                self.taskBrowserError = self.friendlyMessage(for: error)
            }

            self.finishTaskBrowserPageLoad(generation: generation)
        }
    }

    private func loadNextTaskBrowserPage() {
        guard isTaskBrowserPresented,
              !isLoadingTaskBrowser,
              taskBrowserError == nil,
              let cursor = taskBrowserNextCursor else {
            return
        }
        let generation = taskBrowserGeneration
        let query = taskBrowserQuery
        guard !taskBrowserSeenCursors.contains(cursor) else {
            taskBrowserNextCursor = nil
            taskBrowserError = "Codex 返回了重复的分页位置。"
            return
        }

        isLoadingTaskBrowser = true
        taskBrowserPageTask = Task { [weak self] in
            guard let self else { return }
            do {
                if query.isEmpty {
                    let page = try await self.taskBrowser.listTaskPage(
                        cursor: cursor,
                        limit: Self.taskBrowserPageSize
                    )
                    guard !Task.isCancelled,
                          self.isTaskBrowserPresented,
                          self.taskBrowserGeneration == generation else {
                        return
                    }
                    self.taskBrowserSeenCursors.insert(cursor)
                    var knownIDs = Set(self.taskBrowserResults.map(\.id))
                    self.taskBrowserResults.append(contentsOf: page.tasks.compactMap {
                        guard knownIDs.insert($0.id).inserted else { return nil }
                        return $0
                    })
                    if page.nextCursor == cursor {
                        throw TaskBrowserPagingError.repeatedCursor
                    }
                    self.taskBrowserNextCursor = page.nextCursor
                } else {
                    try await self.loadTaskBrowserContentPages(
                        startingAt: cursor,
                        query: query,
                        generation: generation
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.isTaskBrowserPresented,
                      self.taskBrowserGeneration == generation else {
                    return
                }
                self.taskBrowserError = self.friendlyMessage(for: error)
            }

            self.finishTaskBrowserPageLoad(generation: generation)
        }
    }

    private func finishTaskBrowserPageLoad(generation: UUID) {
        guard taskBrowserGeneration == generation else { return }
        isLoadingTaskBrowser = false
        taskBrowserPageTask = nil
        let shouldLoadNext = taskBrowserPendingLoadMore
        taskBrowserPendingLoadMore = false
        if shouldLoadNext, taskBrowserError == nil {
            loadNextTaskBrowserPage()
        }
    }

    private func loadTaskBrowserContentPages(
        startingAt initialCursor: String?,
        query: String,
        generation: UUID
    ) async throws {
        var cursor = initialCursor

        repeat {
            if let cursor,
               taskBrowserSeenCursors.contains(cursor) {
                throw TaskBrowserPagingError.repeatedCursor
            }

            let page = try await taskBrowser.searchTaskContentPage(
                cursor: cursor,
                searchTerm: query,
                limit: Self.taskBrowserPageSize
            )
            guard !Task.isCancelled,
                  isTaskBrowserPresented,
                  taskBrowserGeneration == generation else {
                throw CancellationError()
            }
            if let cursor {
                taskBrowserSeenCursors.insert(cursor)
                if page.nextCursor == cursor {
                    throw TaskBrowserPagingError.repeatedCursor
                }
            }

            // Only a new tail row can retrigger LazyVStack's near-bottom
            // pagination sentinel. A newly discovered title match is promoted
            // above the content bucket, so keep hopping if this page added no
            // content row even though the total result count changed.
            let previousContentCount = taskBrowserSearchResults.contentMatches.count
            let titleMatches = page.tasks.filter {
                $0.titleMatches(query)
            }
            let titleIDs = Set(titleMatches.map(\.id))
            taskBrowserSearchResults.appendTitleMatches(titleMatches)
            taskBrowserSearchResults.appendContentMatches(
                page.tasks.filter { !titleIDs.contains($0.id) }
            )
            taskBrowserResults = taskBrowserSearchResults.tasks
            taskBrowserNextCursor = page.nextCursor
            taskBrowserError = nil

            let appendedContentResult =
                taskBrowserSearchResults.contentMatches.count > previousContentCount
            guard !appendedContentResult,
                  let nextCursor = page.nextCursor else {
                return
            }
            cursor = nextCursor
            await Task.yield()
        } while true
    }

    private func deduplicatingTasks(
        _ summaries: [TaskSummary]
    ) -> [TaskSummary] {
        var seen = Set<String>()
        return summaries.compactMap { summary in
            guard seen.insert(summary.id).inserted else { return nil }
            return summary
        }
    }

    func loadMoreOlderMessages() {
        cancelRecentMessagesPrefetch()
        guard let threadID = selectedTaskID,
              loadedTaskID == threadID,
              let cursor = nextOlderMessagesCursor,
              !isLoadingOlderMessages else {
            return
        }

        olderMessagesError = nil
        startLoadingOlderMessages(
            threadID: threadID,
            cursor: cursor,
            generation: messageLoadGeneration,
            loadAll: false
        )
    }

    func loadMoreOlderMessagesAutomatically() {
        guard canAutomaticallyLoadOlderMessages else { return }
        loadMoreOlderMessages()
    }

    func cancelLoadingOlderMessages() {
        guard isLoadingOlderMessages else { return }
        olderMessagesTask?.cancel()
        olderMessagesTask = nil
        isLoadingOlderMessages = false
        isSelectingAll = false
        setStatus(nil)
    }

    private func startPrefetchingRecentMessages(
        threadID: String,
        cursor: String,
        generation: UUID,
        turnLimit: Int
    ) {
        recentMessagesPrefetchTask?.cancel()
        isPrefetchingRecentMessages = true

        recentMessagesPrefetchTask = Task { [weak self] in
            await self?.prefetchRecentMessages(
                threadID: threadID,
                cursor: cursor,
                generation: generation,
                turnLimit: turnLimit
            )
        }
    }

    private func cancelRecentMessagesPrefetch() {
        recentMessagesPrefetchTask?.cancel()
        recentMessagesPrefetchTask = nil
        isPrefetchingRecentMessages = false
    }

    private func prefetchRecentMessages(
        threadID: String,
        cursor: String,
        generation: UUID,
        turnLimit: Int
    ) async {
        do {
            let page = try await conversations.readSelectableMessagePage(
                threadId: threadID,
                cursor: cursor,
                limit: max(1, turnLimit)
            )

            guard !Task.isCancelled,
                  messageLoadGeneration == generation,
                  selectedTaskID == threadID else {
                return
            }

            prependUniqueMessages(page.messages)
            if page.nextCursor == cursor {
                nextOlderMessagesCursor = cursor
                olderMessagesError = "Codex 返回了重复的分页位置，请重试。"
                isPrefetchingRecentMessages = false
                recentMessagesPrefetchTask = nil
                return
            }
            nextOlderMessagesCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            // The newest turn is already usable. Keep the original cursor so
            // the explicit “load older” action can retry without turning a
            // background convenience request into a blocking error.
        }

        guard messageLoadGeneration == generation,
              selectedTaskID == threadID else {
            return
        }
        isPrefetchingRecentMessages = false
        recentMessagesPrefetchTask = nil
    }

    private enum ExportAction {
        case copy
        case save
    }

    private func startLoadingOlderMessages(
        threadID: String,
        cursor: String,
        generation: UUID,
        loadAll: Bool
    ) {
        olderMessagesTask?.cancel()
        isLoadingOlderMessages = true
        olderMessagesError = nil

        olderMessagesTask = Task { [weak self] in
            await self?.loadOlderMessages(
                threadID: threadID,
                initialCursor: cursor,
                generation: generation,
                loadAll: loadAll
            )
        }
    }

    private func loadOlderMessages(
        threadID: String,
        initialCursor: String,
        generation: UUID,
        loadAll: Bool
    ) async {
        var cursor: String? = initialCursor
        var seenCursors = Set<String>()
        var emptyPageHops = 0

        while let currentCursor = cursor {
            guard !Task.isCancelled,
                  messageLoadGeneration == generation,
                  selectedTaskID == threadID else {
                return
            }

            guard seenCursors.insert(currentCursor).inserted else {
                nextOlderMessagesCursor = currentCursor
                isLoadingOlderMessages = false
                isSelectingAll = false
                setStatus(nil)
                olderMessagesError = "Codex 返回了重复的分页位置，请重试。"
                olderMessagesTask = nil
                return
            }

            do {
                let page = try await conversations.readSelectableMessagePage(
                    threadId: threadID,
                    cursor: currentCursor,
                    limit: loadAll ? 10 : 3
                )

                guard !Task.isCancelled,
                      messageLoadGeneration == generation,
                      selectedTaskID == threadID else {
                    return
                }

                let insertedMessageCount = prependUniqueMessages(page.messages)
                if page.nextCursor == currentCursor {
                    nextOlderMessagesCursor = currentCursor
                    isLoadingOlderMessages = false
                    isSelectingAll = false
                    setStatus(nil)
                    olderMessagesError = "Codex 返回了重复的分页位置，请重试。"
                    olderMessagesTask = nil
                    return
                }
                cursor = page.nextCursor
                nextOlderMessagesCursor = cursor
                if !loadAll {
                    if insertedMessageCount == 0,
                       page.hasMore,
                       cursor != nil,
                       emptyPageHops < Self.maximumEmptyOlderPageHops {
                        emptyPageHops += 1
                        await Task.yield()
                        continue
                    }
                    isLoadingOlderMessages = false
                    olderMessagesTask = nil
                    return
                }
                await Task.yield()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      messageLoadGeneration == generation,
                      selectedTaskID == threadID else {
                    return
                }
                nextOlderMessagesCursor = currentCursor
                isLoadingOlderMessages = false
                isSelectingAll = false
                setStatus(nil)
                olderMessagesError = friendlyMessage(for: error)
                olderMessagesTask = nil
                return
            }
        }

        guard !Task.isCancelled,
              messageLoadGeneration == generation,
              selectedTaskID == threadID else {
            return
        }
        nextOlderMessagesCursor = nil
        isLoadingOlderMessages = false
        olderMessagesError = nil
        olderMessagesTask = nil
        if isSelectingAll {
            selectedMessageIDs = Set(messages.map(\.id))
            selectionAnchorID = messages.last?.id
            isWholeConversationSelectionActive = true
            isSelectingAll = false
            setStatus(nil)
        }
    }

    @discardableResult
    private func prependUniqueMessages(
        _ selectable: [SelectableMessage]
    ) -> Int {
        var knownIDs = Set(messages.map(\.id))
        let uniqueRows = selectable.compactMap { message -> SelectableMessage? in
            guard knownIDs.insert(message.id).inserted else { return nil }
            return message
        }
        messages.insert(contentsOf: uniqueRows, at: 0)

        // A newest turn can legitimately contain only transient/tool items,
        // which this text-only exporter filters out. Once an older page yields
        // the first selectable text, restore the default “latest visible turn”
        // selection instead of leaving the user with an unexplained empty
        // selection.
        if shouldSelectFirstVisibleTurn, !messages.isEmpty {
            selectLatestTurn()
        }
        return uniqueRows.count
    }

    private func mergeNewestMessages(_ selectable: [SelectableMessage]) {
        let replacements = Dictionary(uniqueKeysWithValues: selectable.map {
            ($0.id, $0)
        })
        messages = messages.map { replacements[$0.id] ?? $0 }
        let knownIDs = Set(messages.map(\.id))
        messages.append(contentsOf: selectable.compactMap {
            knownIDs.contains($0.id) ? nil : $0
        })
    }

    private func resetConversationState(selecting taskID: String? = nil) {
        // Cancellation and a new generation must happen before clearing the
        // visible identity. Otherwise an in-flight page can return through an
        // old guard and leave one of the loading flags permanently enabled.
        cancelMessageLoads()
        selectedTaskID = taskID
        loadedTaskID = nil
        loadingTaskID = nil
        messages = []
        selectedMessageIDs = []
        isWholeConversationSelectionActive = false
        selectionAnchorID = nil
        shouldSelectFirstVisibleTurn = false
        scrollTargetID = nil
        setStatus(nil)
    }

    private func cancelMessageLoads(preservingOlderCursor: Bool = false) {
        cancelRecentMessagesPrefetch()
        olderMessagesTask?.cancel()
        olderMessagesTask = nil
        messageLoadGeneration = UUID()
        loadingTaskID = nil
        isLoadingOlderMessages = false
        isSelectingAll = false
        olderMessagesError = nil
        if !preservingOlderCursor {
            nextOlderMessagesCursor = nil
        }
    }

    private func export(action: ExportAction) async {
        guard canExport else { return }
        let renderMessages = messages
            .filter { selectedMessageIDs.contains($0.id) }
            .map { RenderMessage(role: $0.role, text: $0.text) }
        guard !renderMessages.isEmpty else { return }

        isExporting = true
        setStatus("正在生成图片…")
        defer { isExporting = false }

        do {
            var lastReportedPercent = -1
            let result = try await imageRenderer.render(
                messages: renderMessages,
                progress: { [weak self] fraction in
                    let percent = min(100, max(0, Int((fraction * 100).rounded(.down))))
                    guard percent != lastReportedPercent else { return }
                    lastReportedPercent = percent
                    self?.setStatus("正在生成图片… \(percent)%")
                }
            )

            switch action {
            case .copy:
                try exportDestination.copy(result)
                setStatus(
                    result.warning.map { "已复制图片 · \($0)" }
                        ?? "已复制图片"
                )

            case .save:
                let url = try await exportDestination.save(result)
                setStatus(
                    result.warning.map { "已保存 · \($0)" }
                        ?? "已保存到 \(url.deletingLastPathComponent().lastPathComponent)"
                )
            }
        } catch {
            setStatus(friendlyMessage(for: error), isError: true)
        }
    }

    private func setStatus(_ message: String?, isError: Bool = false) {
        statusNotice = message.map {
            StatusNotice(
                message: $0,
                isError: isError,
                updatedAt: ProcessInfo.processInfo.systemUptime
            )
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "操作失败，请确认 Codex 已安装并重试。"
    }
}
