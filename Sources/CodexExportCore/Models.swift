import Foundation

/// A task displayed in the task picker. Conversation bodies are intentionally
/// absent from this model; the app only loads them after the user chooses one.
public struct TaskSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let updatedAt: Date

    public init(
        id: String,
        title: String,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

/// One page of task summaries for the fixed-height history browser.
///
/// Passing `nextCursor` back to `listTaskPage` continues through older tasks
/// without loading any conversation bodies into the exporter.
public struct TaskSummaryPage: Hashable, Sendable {
    public let tasks: [TaskSummary]
    public let nextCursor: String?

    public init(tasks: [TaskSummary], nextCursor: String?) {
        self.tasks = tasks
        self.nextCursor = nextCursor
    }
}

public enum MessageRole: String, Hashable, Sendable {
    case user
    case assistant
}

/// A text-only conversation item that the user may include in an export.
public struct SelectableMessage: Identifiable, Hashable, Sendable {
    public let id: String
    public let turnId: String
    public let role: MessageRole
    public let text: String

    public init(
        id: String,
        turnId: String,
        role: MessageRole,
        text: String
    ) {
        self.id = id
        self.turnId = turnId
        self.role = role
        self.text = text
    }
}

/// One page of selectable conversation messages.
///
/// App Server returns turn pages newest-first. `messages` is normalized to
/// chronological order within this page so callers can render it directly.
/// Pass `nextCursor` back to `readSelectableMessagePage` to request an older
/// page, then prepend that page's messages to the messages already displayed.
public struct SelectableMessagePage: Hashable, Sendable {
    public let messages: [SelectableMessage]
    public let nextCursor: String?

    public var hasMore: Bool { nextCursor != nil }

    public init(
        messages: [SelectableMessage],
        nextCursor: String?
    ) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}
