import XCTest
@testable import CodexExportCore

final class TranscriptTests: XCTestCase {
    func testTaskTitlePrefersNameThenFallsBackToPreviewOrUntitled() throws {
        let explicit = try decodeTaskSummary([
            "id": "named",
            "name": "  Explicit   title  ",
            "preview": "Prompt fallback",
            "updatedAt": 1,
        ])
        let fallback = try decodeTaskSummary([
            "id": "fallback",
            "preview": "\n  Prompt fallback\nsecond line",
            "updatedAt": 2.0,
        ])
        let untitled = try decodeTaskSummary([
            "id": "empty",
            "updatedAt": 3,
        ])

        XCTAssertEqual(explicit.title, "Explicit title")
        XCTAssertEqual(fallback.title, "Prompt fallback")
        XCTAssertEqual(untitled.title, "Untitled task")
    }

    func testKeepsOnlyUserTextAndFinalAnswer() throws {
        let messages = try decodeMessages(
            thread: [
                "id": "thread",
                "preview": "Preview",
                "updatedAt": 1,
                "turns": [[
                    "id": "turn",
                    "items": [
                        [
                            "id": "user",
                            "type": "userMessage",
                            "content": [
                                ["type": "text", "text": "Hello"],
                                ["type": "image", "url": "file:///tmp/private.png"],
                                ["type": "localImage", "path": "/tmp/private.png"],
                            ],
                        ],
                        [
                            "id": "commentary",
                            "type": "agentMessage",
                            "text": "Working on it",
                            "phase": "commentary",
                        ],
                        [
                            "id": "legacy",
                            "type": "agentMessage",
                            "text": "Unknown phase",
                        ],
                        [
                            "id": "final",
                            "type": "agentMessage",
                            "text": "Done",
                            "phase": "final_answer",
                        ],
                        [
                            "id": "reasoning",
                            "type": "reasoning",
                            "content": ["private reasoning"],
                        ],
                    ],
                ]],
            ]
        )

        XCTAssertEqual(messages.map(\.id), ["user", "final"])
        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Hello", "Done"])
    }

    func testStripsInjectedAttachmentScaffoldAndImageLocations() throws {
        let userText = #"""
        # Files mentioned by the user:

        ## private.png: /Users/someone/Secret/private.png

        ## My request:
        请比较 ![diagram](/Users/someone/Secret/private.png)。
        <image name=[Image #1] path="/Users/someone/Secret/private.png">
        保留 `![literal](/tmp/inline-code.png)`。
        ```md
        ![literal](/tmp/fenced-code.png)
        <image path="/tmp/fenced-code.png">
        ```
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("请比较 diagram。"))
        XCTAssertFalse(text.contains("/Users/someone/Secret"))
        XCTAssertFalse(text.contains("Files mentioned by the user"))
        XCTAssertTrue(text.contains("`![literal](/tmp/inline-code.png)`"))
        XCTAssertTrue(text.contains("![literal](/tmp/fenced-code.png)"))
        XCTAssertTrue(text.contains("<image path=\"/tmp/fenced-code.png\">"))
    }

    func testSanitizesImagesInFinalAnswerWithoutChangingCode() throws {
        let messages = try decodeMessages(
            thread: [
                "id": "thread",
                "preview": "Preview",
                "updatedAt": 1,
                "turns": [[
                    "id": "turn",
                    "items": [[
                        "id": "answer",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "See ![chart](https://example.com/chart.png) <img src=\"/tmp/a.png\"> and `![code](/tmp/b.png)`",
                    ]],
                ]],
            ]
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )
        XCTAssertEqual(text, "See chart  and `![code](/tmp/b.png)`")
    }

    func testRemovesImageReferenceDefinitionsWithoutLeakingLocations() throws {
        let userText = #"""
        Full ![full alt][private-ref].
        Collapsed ![collapsed alt][].
        Shortcut ![shortcut alt].

        [private-ref]: /Users/someone/Secret/full.png "private title"
        [collapsed alt]: <file:///Users/someone/Secret/collapsed.png>
        [SHORTCUT   ALT]: https://secret.example/shortcut.png
        [ordinary-link]: https://example.com/keep
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("Full full alt."))
        XCTAssertTrue(text.contains("Collapsed collapsed alt."))
        XCTAssertTrue(text.contains("Shortcut shortcut alt."))
        XCTAssertTrue(text.contains("[ordinary-link]: https://example.com/keep"))
        XCTAssertFalse(text.contains("/Users/someone/Secret"))
        XCTAssertFalse(text.contains("secret.example"))
        XCTAssertFalse(text.lowercased().contains("[private-ref]:"))
        XCTAssertFalse(text.lowercased().contains("[collapsed alt]:"))
        XCTAssertFalse(text.lowercased().contains("[shortcut   alt]:"))
    }

    func testRemovesMultilineHTMLImagesWithoutChangingInlineOrFencedCode() throws {
        let userText = #"""
        Before <img
          src="/Users/someone/Secret/multiline.png"
          alt="hidden > marker"> after.
        Also <IMAGE
          path='/Users/someone/Secret/image-tag.png'
        > done.
        Keep `<img
          src="/Users/someone/Secret/inline-code.png">` literal.
        ```html
        <image
          path="/Users/someone/Secret/fenced-code.png">
        ```
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("Before  after."))
        XCTAssertTrue(text.contains("Also  done."))
        XCTAssertFalse(text.contains("multiline.png"))
        XCTAssertFalse(text.contains("image-tag.png"))
        XCTAssertTrue(text.contains("`<img\n  src=\"/Users/someone/Secret/inline-code.png\">`"))
        XCTAssertTrue(text.contains("path=\"/Users/someone/Secret/fenced-code.png\""))
    }

    func testLeavesImageLikeReferenceDefinitionsInsideCodeUntouched() throws {
        let userText = #"""
        Outside ![visible][outside].
        [outside]: /Users/someone/Secret/outside.png

        `![inline][inline-ref] [inline-ref]: /Users/someone/Secret/inline.png`

        ```md
        ![fenced][fenced-ref]
        [fenced-ref]: /Users/someone/Secret/fenced.png
        <img
          src="/Users/someone/Secret/fenced-html.png">
        ```
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("Outside visible."))
        XCTAssertFalse(text.contains("outside.png"))
        XCTAssertTrue(text.contains("![inline][inline-ref] [inline-ref]: /Users/someone/Secret/inline.png"))
        XCTAssertTrue(text.contains("![fenced][fenced-ref]"))
        XCTAssertTrue(text.contains("[fenced-ref]: /Users/someone/Secret/fenced.png"))
        XCTAssertTrue(text.contains("src=\"/Users/someone/Secret/fenced-html.png\""))
    }

    func testFenceClosingRequiresAllowedIndentAndOnlyTrailingWhitespace() throws {
        let userText = #"""
        ```md
        ```not-a-closing-fence
        ![trailing text](/tmp/trailing-text.png)
            ```
        ![four space close](/tmp/four-space-close.png)
        ```
        Outside ![removed](/tmp/outside.png).
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("![trailing text](/tmp/trailing-text.png)"))
        XCTAssertTrue(text.contains("![four space close](/tmp/four-space-close.png)"))
        XCTAssertTrue(text.contains("Outside removed."))
        XCTAssertFalse(text.contains("/tmp/outside.png"))
    }

    func testTildeFenceUsesTheSameStrictClosingRules() throws {
        let userText = #"""
        ~~~md
        ~~~not-a-closing-fence
        ![inside](/tmp/inside-tilde.png)
          ~~~
        Outside ![removed](/tmp/outside-tilde.png).
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertTrue(text.contains("![inside](/tmp/inside-tilde.png)"))
        XCTAssertTrue(text.contains("Outside removed."))
        XCTAssertFalse(text.contains("/tmp/outside-tilde.png"))
    }

    func testFourSpaceIndentedFenceMarkerDoesNotHideAttachmentScaffold() throws {
        let userText = #"""
            ```md
        # Files mentioned by the user:

        ## private.png: /Users/someone/Secret/private.png

        ## My request:
        Keep ![alt](/Users/someone/Secret/private.png).
        """#
        let messages = try decodeMessages(
            thread: threadWithSingleUserMessage(userText)
        )

        let text = try XCTUnwrap(
            messages.first?.text
        )

        XCTAssertFalse(text.contains("Files mentioned by the user"))
        XCTAssertFalse(text.contains("/Users/someone/Secret"))
        XCTAssertTrue(text.contains("Keep alt."))
    }

    private func decodeMessages(
        thread: [String: Any]
    ) throws -> [SelectableMessage] {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": thread["turns"] as? [[String: Any]] ?? [],
            "nextCursor": NSNull(),
        ])
        let page = try JSONDecoder().decode(ThreadTurnsListPage.self, from: data)
        return TranscriptNormalizer.messages(turns: page.data)
    }

    private func decodeTaskSummary(
        _ thread: [String: Any]
    ) throws -> TaskSummary {
        let data = try JSONSerialization.data(withJSONObject: thread)
        let decoded = try JSONDecoder().decode(AppServerThread.self, from: data)
        return TranscriptNormalizer.taskSummary(from: decoded)
    }

    private func threadWithSingleUserMessage(_ text: String) -> [String: Any] {
        [
            "id": "thread",
            "preview": text,
            "updatedAt": 1,
            "turns": [[
                "id": "turn",
                "items": [[
                    "id": "user",
                    "type": "userMessage",
                    "content": [["type": "text", "text": text]],
                ]],
            ]],
        ]
    }
}
