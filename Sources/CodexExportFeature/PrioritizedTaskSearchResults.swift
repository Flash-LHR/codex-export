import CodexExportCore

/// Keeps title matches ahead of conversation-body matches while search pages
/// arrive independently. A task returned by both sources appears once, in the
/// title bucket.
struct PrioritizedTaskSearchResults {
    private(set) var titleMatches: [TaskSummary] = []
    private(set) var contentMatches: [TaskSummary] = []

    var tasks: [TaskSummary] {
        titleMatches + contentMatches
    }

    mutating func appendTitleMatches(_ tasks: [TaskSummary]) {
        let promotedIDs = Set(tasks.map(\.id))
        if !promotedIDs.isEmpty {
            contentMatches.removeAll { promotedIDs.contains($0.id) }
        }

        var knownIDs = Set(titleMatches.map(\.id))
        for task in tasks where knownIDs.insert(task.id).inserted {
            titleMatches.append(task)
        }
    }

    mutating func appendContentMatches(_ tasks: [TaskSummary]) {
        var knownIDs = Set(titleMatches.map(\.id))
        knownIDs.formUnion(contentMatches.map(\.id))
        for task in tasks where knownIDs.insert(task.id).inserted {
            contentMatches.append(task)
        }
    }
}
