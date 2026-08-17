import XCTest
@testable import CodexExportCore

final class LiveAppServerTests: XCTestCase {
    func testListsAndReadsLocalTasksWithoutPrintingContent() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_EXPORT_LIVE_SMOKE"] == "1" else {
            throw XCTSkip("Set CODEX_EXPORT_LIVE_SMOKE=1 to run the local read-only smoke test.")
        }

        let client = CodexAppServerClient(
            // Match production's list size so the JSONL response is large
            // enough to be split across multiple stdout reads.
            configuration: .init(maximumTaskCount: 50, pageSize: 50, requestTimeout: 60)
        )

        do {
            let tasks = try await client.listTasks()
            XCTAssertFalse(tasks.isEmpty)

            let historyPage = try await client.listTaskPage(limit: 20)
            XCTAssertFalse(historyPage.tasks.isEmpty)
            let noMatch = try await client.searchTaskContentPage(
                searchTerm: "codex-export-live-smoke-no-match-7db3c2e9",
                limit: 5
            )
            XCTAssertTrue(noMatch.tasks.isEmpty)

            var foundTextConversation = false
            for task in tasks {
                // Match the menu-bar app's latency-sensitive first paint: one
                // newest turn, not the entire transcript.
                let page = try await client.readSelectableMessagePage(
                    threadId: task.id,
                    limit: 1
                )
                if !page.messages.isEmpty {
                    foundTextConversation = true
                    XCTAssertTrue(page.messages.allSatisfy { !$0.text.isEmpty })
                    XCTAssertTrue(page.messages.allSatisfy {
                        $0.role == .user || $0.role == .assistant
                    })
                    break
                }
            }
            XCTAssertTrue(foundTextConversation)
            await client.shutdown()
        } catch {
            await client.shutdown()
            throw error
        }
    }
}
