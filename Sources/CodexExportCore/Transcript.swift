import Foundation

struct ThreadListPage: Decodable {
    let data: [AppServerThread]
    let nextCursor: String?
}

struct ThreadSearchPage: Decodable {
    let data: [ThreadSearchResult]
    let nextCursor: String?
}

struct ThreadSearchResult: Decodable {
    let thread: AppServerThread
}

struct ThreadTurnsListPage: Decodable {
    let data: [AppServerTurn]
    let nextCursor: String?
}

struct AppServerThread: Decodable {
    let id: String
    let name: String?
    let preview: String
    let updatedAt: Int64

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case preview
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        preview = try container.decodeIfPresent(String.self, forKey: .preview) ?? ""
        if let integer = try? container.decode(Int64.self, forKey: .updatedAt) {
            updatedAt = integer
        } else if let number = try? container.decode(Double.self, forKey: .updatedAt) {
            updatedAt = Int64(number)
        } else {
            updatedAt = 0
        }
    }
}

struct AppServerTurn: Decodable {
    let id: String
    let items: [AppServerThreadItem]
}

enum AppServerThreadItem: Decodable {
    case userMessage(id: String, textFragments: [String])
    case agentMessage(id: String, text: String, phase: String?)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case content
        case text
        case phase
    }

    private struct UserContent: Decodable {
        let type: String
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type)

        switch type {
        case "userMessage":
            let id = try container.decode(String.self, forKey: .id)
            let content = try container.decodeIfPresent(
                [UserContent].self,
                forKey: .content
            ) ?? []
            self = .userMessage(
                id: id,
                textFragments: content.compactMap { item in
                    item.type == "text" ? item.text : nil
                }
            )

        case "agentMessage":
            self = .agentMessage(
                id: try container.decode(String.self, forKey: .id),
                text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
                phase: try container.decodeIfPresent(String.self, forKey: .phase)
            )

        default:
            self = .ignored
        }
    }
}

enum TranscriptNormalizer {
    static func taskSummary(from thread: AppServerThread) -> TaskSummary {
        let sanitizedPreview = TranscriptTextSanitizer.sanitize(
            thread.preview,
            stripInjectedAttachmentHeader: true
        )
        let explicitTitle = normalizeSummaryText(thread.name ?? "")
        let title = explicitTitle.isEmpty
            ? clippedTitle(firstNonemptyLine(in: sanitizedPreview) ?? "")
            : explicitTitle

        return TaskSummary(
            id: thread.id,
            title: title,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
        )
    }

    static func messages(turns: [AppServerTurn]) -> [SelectableMessage] {
        turns.flatMap { turn in
            turn.items.compactMap { item in
                switch item {
                case .userMessage(let id, let fragments):
                    let text = TranscriptTextSanitizer.sanitize(
                        fragments.joined(separator: "\n"),
                        stripInjectedAttachmentHeader: true
                    )
                    guard !text.isEmpty else {
                        return nil
                    }
                    return SelectableMessage(
                        id: id,
                        turnId: turn.id,
                        role: .user,
                        text: text
                    )

                case .agentMessage(let id, let text, let phase):
                    guard phase == "final_answer" else {
                        return nil
                    }
                    let normalizedText = TranscriptTextSanitizer.sanitize(
                        text,
                        stripInjectedAttachmentHeader: false
                    )
                    guard !normalizedText.isEmpty else {
                        return nil
                    }
                    return SelectableMessage(
                        id: id,
                        turnId: turn.id,
                        role: .assistant,
                        text: normalizedText
                    )

                case .ignored:
                    return nil
                }
            }
        }
    }

    private static func normalizeSummaryText(_ text: String) -> String {
        text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func firstNonemptyLine(in text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func clippedTitle(_ title: String) -> String {
        let normalized = normalizeSummaryText(title)
        guard !normalized.isEmpty else { return "Untitled task" }
        let limit = 100
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
