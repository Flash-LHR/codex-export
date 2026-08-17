import Foundation

enum TranscriptTextSanitizer {
    static func sanitize(
        _ text: String,
        stripInjectedAttachmentHeader: Bool
    ) -> String {
        let headerStripped = stripInjectedAttachmentHeader
            ? removingInjectedAttachmentHeader(from: text)
            : text
        return sanitizingMarkdownOutsideCode(headerStripped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingInjectedAttachmentHeader(from text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var filesMarker: Int?
        var fence: Fence?

        for index in lines.indices {
            let line = lines[index]
            if let currentFence = fence {
                if currentFence.closes(line) { fence = nil }
                continue
            }
            if let openingFence = Fence.opening(line) {
                fence = openingFence
                continue
            }

            let marker = normalizedInjectedMarker(line)
            if marker == "files mentioned by the user:" {
                filesMarker = index
            } else if marker == "my request:", let start = filesMarker {
                lines.removeSubrange(start...index)
                return lines.joined(separator: "\n")
            }
        }
        return text
    }

    private static func normalizedInjectedMarker(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sanitizingMarkdownOutsideCode(_ text: String) -> String {
        let segments = codeProtectedSegments(in: text)
        let imageReferenceLabels = segments.reduce(into: Set<String>()) { labels, segment in
            guard !segment.isCode else { return }
            labels.formUnion(referencedImageLabels(in: segment.text))
        }

        return segments.map { segment in
            guard !segment.isCode else { return segment.text }
            return sanitizePlainMarkdown(
                segment.text,
                imageReferenceLabels: imageReferenceLabels
            )
        }.joined()
    }

    private static func codeProtectedSegments(in text: String) -> [ProtectedSegment] {
        let lines = text.components(separatedBy: "\n")
        var fencedSegments: [ProtectedSegment] = []
        var fence: Fence?

        func append(_ text: String, isCode: Bool, to result: inout [ProtectedSegment]) {
            guard !text.isEmpty else { return }
            if let last = result.indices.last, result[last].isCode == isCode {
                result[last].text += text
            } else {
                result.append(ProtectedSegment(text: text, isCode: isCode))
            }
        }

        func appendInlineSegments(
            from text: String,
            to result: inout [ProtectedSegment]
        ) {
            var plainStart = text.startIndex
            var cursor = text.startIndex

            while cursor < text.endIndex {
                guard text[cursor] == "`", !isEscaped(at: cursor, in: text) else {
                    cursor = text.index(after: cursor)
                    continue
                }

                var delimiterEnd = cursor
                while delimiterEnd < text.endIndex, text[delimiterEnd] == "`" {
                    delimiterEnd = text.index(after: delimiterEnd)
                }
                let delimiter = String(text[cursor..<delimiterEnd])
                guard let closing = text.range(
                    of: delimiter,
                    range: delimiterEnd..<text.endIndex
                ) else {
                    cursor = delimiterEnd
                    continue
                }

                append(String(text[plainStart..<cursor]), isCode: false, to: &result)
                append(String(text[cursor..<closing.upperBound]), isCode: true, to: &result)
                cursor = closing.upperBound
                plainStart = cursor
            }
            append(String(text[plainStart..<text.endIndex]), isCode: false, to: &result)
        }

        for (index, line) in lines.enumerated() {
            let terminatedLine = line + (index < lines.count - 1 ? "\n" : "")
            if let currentFence = fence {
                append(terminatedLine, isCode: true, to: &fencedSegments)
                if currentFence.closes(line) { fence = nil }
            } else if let openingFence = Fence.opening(line) {
                fence = openingFence
                append(terminatedLine, isCode: true, to: &fencedSegments)
            } else {
                append(terminatedLine, isCode: false, to: &fencedSegments)
            }
        }

        var result: [ProtectedSegment] = []
        for segment in fencedSegments {
            if segment.isCode {
                append(segment.text, isCode: true, to: &result)
            } else {
                appendInlineSegments(from: segment.text, to: &result)
            }
        }
        return result
    }

    private static func sanitizePlainMarkdown(
        _ text: String,
        imageReferenceLabels: Set<String>
    ) -> String {
        let withoutHTMLImages = replacingHTMLImageTags(in: text)
        let withoutReferenceDefinitions = removingImageReferenceDefinitions(
            from: withoutHTMLImages,
            labels: imageReferenceLabels
        )
        return replacingMarkdownImages(in: withoutReferenceDefinitions)
    }

    private static func replacingHTMLImageTags(in text: String) -> String {
        var output = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard text[cursor] == "<",
                  let tagEnd = htmlImageTagEnd(in: text, startingAt: cursor) else {
                output.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            cursor = tagEnd
        }
        return output
    }

    private static func htmlImageTagEnd(
        in text: String,
        startingAt opening: String.Index
    ) -> String.Index? {
        var nameStart = text.index(after: opening)
        if nameStart < text.endIndex, text[nameStart] == "/" {
            nameStart = text.index(after: nameStart)
        }

        var nameEnd: String.Index?
        for name in ["image", "img"] {
            guard let candidateEnd = text.index(
                nameStart,
                offsetBy: name.count,
                limitedBy: text.endIndex
            ), String(text[nameStart..<candidateEnd]).lowercased() == name else {
                continue
            }
            nameEnd = candidateEnd
            break
        }
        guard var cursor = nameEnd else { return nil }
        if cursor < text.endIndex {
            let boundary = text[cursor]
            guard boundary.isWhitespace || boundary == "/" || boundary == ">" else {
                return nil
            }
        }

        var quote: Character?
        while cursor < text.endIndex {
            let character = text[cursor]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }

        // Once a real image tag has started, discard an unterminated remainder
        // rather than leaking a local path from malformed input.
        return text.endIndex
    }

    private static func referencedImageLabels(in text: String) -> Set<String> {
        var labels = Set<String>()
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let image = markdownImage(in: text, startingAt: cursor) else {
                cursor = text.index(after: cursor)
                continue
            }
            if let referenceLabel = image.referenceLabel {
                let normalized = normalizeReferenceLabel(referenceLabel)
                if !normalized.isEmpty { labels.insert(normalized) }
            }
            cursor = image.end
        }
        return labels
    }

    private static func removingImageReferenceDefinitions(
        from text: String,
        labels: Set<String>
    ) -> String {
        guard !labels.isEmpty else { return text }
        return text.components(separatedBy: "\n").filter { line in
            guard let label = referenceDefinitionLabel(in: line) else {
                return true
            }
            return !labels.contains(normalizeReferenceLabel(label))
        }.joined(separator: "\n")
    }

    private static func referenceDefinitionLabel(in line: String) -> String? {
        let leadingSpaces = line.prefix(while: { $0 == " " }).count
        guard leadingSpaces <= 3 else { return nil }
        let start = line.index(line.startIndex, offsetBy: leadingSpaces)
        guard start < line.endIndex, line[start] == "[",
              let close = closingBracket(in: line, after: start) else {
            return nil
        }
        let colon = line.index(after: close)
        guard colon < line.endIndex, line[colon] == ":" else { return nil }
        return String(line[line.index(after: start)..<close])
    }

    private static func normalizeReferenceLabel(_ label: String) -> String {
        var unescaped = ""
        var cursor = label.startIndex
        while cursor < label.endIndex {
            if label[cursor] == "\\" {
                let next = label.index(after: cursor)
                if next < label.endIndex {
                    unescaped.append(label[next])
                    cursor = label.index(after: next)
                    continue
                }
            }
            unescaped.append(label[cursor])
            cursor = label.index(after: cursor)
        }
        return unescaped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func replacingMarkdownImages(in text: String) -> String {
        var output = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let image = markdownImage(in: text, startingAt: cursor) else {
                output.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            output += image.alt
            cursor = image.end
        }
        return output
    }

    private static func markdownImage(
        in text: String,
        startingAt cursor: String.Index
    ) -> MarkdownImage? {
        guard cursor < text.endIndex,
              text[cursor] == "!",
              !isEscaped(at: cursor, in: text) else {
            return nil
        }
        let openBracket = text.index(after: cursor)
        guard openBracket < text.endIndex,
              text[openBracket] == "[",
              let closeBracket = closingBracket(in: text, after: openBracket) else {
            return nil
        }

        let alt = String(text[text.index(after: openBracket)..<closeBracket])
        var suffix = text.index(after: closeBracket)
        while suffix < text.endIndex, text[suffix] == " " || text[suffix] == "\t" {
            suffix = text.index(after: suffix)
        }

        if suffix < text.endIndex, text[suffix] == "(",
           let close = closingParenthesis(in: text, after: suffix) {
            return MarkdownImage(
                alt: alt,
                end: text.index(after: close),
                referenceLabel: nil
            )
        }

        if suffix < text.endIndex, text[suffix] == "[",
           let close = closingBracket(in: text, after: suffix) {
            let explicitLabel = String(text[text.index(after: suffix)..<close])
            return MarkdownImage(
                alt: alt,
                end: text.index(after: close),
                referenceLabel: explicitLabel.isEmpty ? alt : explicitLabel
            )
        }

        return MarkdownImage(
            alt: alt,
            end: text.index(after: closeBracket),
            referenceLabel: alt
        )
    }

    private static func closingBracket(
        in text: String,
        after opening: String.Index
    ) -> String.Index? {
        var depth = 1
        var cursor = text.index(after: opening)
        while cursor < text.endIndex {
            if !isEscaped(at: cursor, in: text) {
                if text[cursor] == "[" { depth += 1 }
                if text[cursor] == "]" {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func closingParenthesis(
        in text: String,
        after opening: String.Index
    ) -> String.Index? {
        var depth = 1
        var cursor = text.index(after: opening)
        while cursor < text.endIndex {
            if !isEscaped(at: cursor, in: text) {
                if text[cursor] == "(" { depth += 1 }
                if text[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(at index: String.Index, in text: String) -> Bool {
        var slashes = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            slashes += 1
            cursor = previous
        }
        return slashes.isMultiple(of: 2) == false
    }

    private struct ProtectedSegment {
        var text: String
        let isCode: Bool
    }

    private struct MarkdownImage {
        let alt: String
        let end: String.Index
        let referenceLabel: String?
    }

    private struct Fence {
        let marker: Character
        let count: Int

        static func opening(_ line: String) -> Fence? {
            guard let content = contentAfterAllowedIndent(in: line),
                  let first = content.first,
                  first == "`" || first == "~" else {
                return nil
            }
            let count = content.prefix(while: { $0 == first }).count
            guard count >= 3 else { return nil }
            return Fence(marker: first, count: count)
        }

        func closes(_ line: String) -> Bool {
            guard let content = Self.contentAfterAllowedIndent(in: line) else {
                return false
            }
            let markerCount = content.prefix(while: { $0 == marker }).count
            guard markerCount >= count else { return false }
            return content.dropFirst(markerCount).allSatisfy(\.isWhitespace)
        }

        private static func contentAfterAllowedIndent(
            in line: String
        ) -> Substring? {
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            guard leadingSpaces <= 3 else { return nil }
            return line.dropFirst(leadingSpaces)
        }
    }
}
