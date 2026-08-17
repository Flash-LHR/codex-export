import Foundation

@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published private var status: LaunchAtLoginStatus
    @Published private(set) var errorMessage: String? {
        didSet {
            errorUpdatedAt = errorMessage == nil
                ? nil
                : ProcessInfo.processInfo.systemUptime
        }
    }
    private(set) var errorUpdatedAt: TimeInterval?

    private let service: any LaunchAtLoginServicing

    public init(service: any LaunchAtLoginServicing) {
        self.service = service
        status = .disabled
        refreshStatus()
    }

    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    var canToggle: Bool {
        status != .unavailable
    }

    var accessibilityValue: String {
        switch status {
        case .disabled: return "已关闭"
        case .enabled: return "已开启"
        case .requiresApproval: return "已注册，等待系统批准"
        case .unavailable: return "不可用"
        }
    }

    public func refreshStatus() {
        errorMessage = nil
        status = service.status
        switch status {
        case .disabled, .enabled:
            break
        case .requiresApproval:
            errorMessage = "请在“系统设置 → 通用 → 登录项”中允许 Codex Export。"
        case .unavailable:
            errorMessage = "系统无法找到 Codex Export 的自启服务。请确认应用完整且已正确签名。"
        }
    }

    func toggle() {
        guard canToggle else { return }
        let shouldRegister = !isRegistered
        errorMessage = nil
        do {
            if shouldRegister {
                try service.register()
            } else {
                try service.unregister()
            }
            refreshStatus()
        } catch {
            refreshStatus()
            if status != .unavailable, isRegistered != shouldRegister {
                errorMessage = "无法更改自启设置。请确认应用位于“应用程序”文件夹并已正确签名。"
            }
        }
    }
}
