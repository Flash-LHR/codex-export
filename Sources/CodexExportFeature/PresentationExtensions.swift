import CodexExportCore
import Foundation

extension TaskSummary {
    var displayName: String {
        let candidate = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty, candidate != "Untitled task" {
            return candidate
        }
        return "未命名任务"
    }

    var updatedLabel: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3_600 { return "\(elapsed / 60) 分钟前" }
        if elapsed < 86_400 { return "\(elapsed / 3_600) 小时前" }
        if elapsed < 2_592_000 { return "\(elapsed / 86_400) 天前" }

        let parts = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: updatedAt
        )
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return year == Calendar.current.component(.year, from: Date())
            ? "\(month)月\(day)日"
            : "\(year)/\(month)/\(day)"
    }

    func titleMatches(_ query: String) -> Bool {
        displayName.localizedCaseInsensitiveContains(query)
    }
}

extension SelectableMessage {
    var roleLabel: String { role == .user ? "你" : "Codex" }

    var preview: String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? "（空消息）" : collapsed
    }
}
