import CodexExportCore
import Foundation

/// Small capability boundaries keep feature-state tests independent of the
/// Codex subprocess and avoid all-purpose mocks.
public protocol RecentTaskServing: Sendable {
    func listTasks() async throws -> [TaskSummary]
}

public protocol TaskBrowserServing: Sendable {
    func listTaskPage(
        cursor: String?,
        limit: Int
    ) async throws -> TaskSummaryPage
    func listTaskTitleIndex() async throws -> [TaskSummary]
    func searchTaskContentPage(
        cursor: String?,
        searchTerm: String,
        limit: Int
    ) async throws -> TaskSummaryPage
}

public protocol ConversationServing: Sendable {
    func readSelectableMessagePage(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage
}

public protocol AppServerLifecycle: Sendable {
    func shutdown() async
}

public protocol CodexAppServing:
    RecentTaskServing,
    TaskBrowserServing,
    ConversationServing,
    AppServerLifecycle {}

extension CodexAppServerClient: CodexAppServing {}

@MainActor
public protocol ConversationImageRendering: AnyObject {
    func render(
        messages: [RenderMessage],
        progress: ((Double) -> Void)?
    ) async throws -> RenderResult
}

extension WebMarkdownRenderer: ConversationImageRendering {}

@MainActor
public protocol ImageExportDestination: AnyObject {
    func copy(_ result: RenderResult) throws
    func save(_ result: RenderResult) async throws -> URL
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}
