import Foundation

public struct RenderMessage: Hashable, Sendable {
    public let role: MessageRole
    public let text: String

    public init(role: MessageRole, text: String) {
        self.role = role
        self.text = text
    }
}

public struct RenderResult: Sendable {
    public let pngData: Data
    public let width: Int
    public let height: Int
    public let warning: String?

    public init(pngData: Data, width: Int, height: Int, warning: String?) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.warning = warning
    }
}
