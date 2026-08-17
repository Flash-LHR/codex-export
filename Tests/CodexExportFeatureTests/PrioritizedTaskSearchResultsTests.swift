import CodexExportCore
import Foundation
import XCTest
@testable import CodexExportFeature

final class PrioritizedTaskSearchResultsTests: XCTestCase {
    func testTitleMatchesAlwaysPrecedeContentMatches() {
        var results = PrioritizedTaskSearchResults()

        results.appendTitleMatches([
            task("title-new", updatedAt: 40),
            task("title-old", updatedAt: 30),
        ])
        XCTAssertEqual(results.tasks.map(\.id), ["title-new", "title-old"])

        results.appendContentMatches([
            task("content-new", updatedAt: 50),
            task("content-old", updatedAt: 20),
        ])
        XCTAssertEqual(
            results.tasks.map(\.id),
            ["title-new", "title-old", "content-new", "content-old"]
        )
    }

    func testDuplicateContentMatchIsRemovedAndLaterTitleMatchIsPromoted() {
        var results = PrioritizedTaskSearchResults()

        results.appendContentMatches([
            task("both", updatedAt: 50),
            task("content", updatedAt: 40),
            task("content", updatedAt: 40),
        ])
        results.appendTitleMatches([
            task("title", updatedAt: 30),
            task("both", updatedAt: 50),
            task("both", updatedAt: 50),
        ])

        XCTAssertEqual(results.titleMatches.map(\.id), ["title", "both"])
        XCTAssertEqual(results.contentMatches.map(\.id), ["content"])
        XCTAssertEqual(results.tasks.map(\.id), ["title", "both", "content"])
    }

    private func task(_ id: String, updatedAt: TimeInterval) -> TaskSummary {
        TaskSummary(
            id: id,
            title: id,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
