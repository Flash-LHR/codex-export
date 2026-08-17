import AppKit
import SwiftUI

private enum MessageScrollMarker: Hashable {
    case bottom
}

public struct ExportPopoverView: View {
    @ObservedObject private var viewModel: ExportViewModel
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
    @ObservedObject private var softwareUpdate: SoftwareUpdateController
    private let githubIsConfigured: Bool
    private let onOpenGitHub: () -> Void
    private let onQuit: () -> Void
    @State private var taskSearchText = ""
    @State private var shouldPinMessagesToBottom = true
    @FocusState private var taskSearchIsFocused: Bool

    public init(
        viewModel: ExportViewModel,
        launchAtLogin: LaunchAtLoginController,
        softwareUpdate: SoftwareUpdateController,
        githubIsConfigured: Bool,
        onOpenGitHub: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.launchAtLogin = launchAtLogin
        self.softwareUpdate = softwareUpdate
        self.githubIsConfigured = githubIsConfigured
        self.onOpenGitHub = onOpenGitHub
        self.onQuit = onQuit
    }

    public var body: some View {
        ZStack {
            normalMode
                .allowsHitTesting(!viewModel.isTaskBrowserPresented)
                .disabled(viewModel.isTaskBrowserPresented)
                .accessibilityHidden(viewModel.isTaskBrowserPresented)

            if viewModel.isTaskBrowserPresented {
                taskBrowserMode
                    .zIndex(1)
            }
        }
        .frame(width: 480, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: viewModel.selectedTaskID) { _ in
            shouldPinMessagesToBottom = true
        }
        .onChange(of: viewModel.isTaskBrowserPresented) { isPresented in
            if isPresented {
                DispatchQueue.main.async {
                    guard viewModel.isTaskBrowserPresented else { return }
                    taskSearchIsFocused = true
                }
            } else {
                taskSearchIsFocused = false
            }
        }
    }

    private var normalMode: some View {
        VStack(spacing: 0) {
            taskSelector
            content
            Divider()
            footer
        }
    }

    private var taskSelector: some View {
        Button {
            taskSearchText = ""
            viewModel.presentTaskBrowser()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(viewModel.selectedTaskDisplayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.085))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help("浏览或搜索历史任务")
        .disabled(viewModel.isExporting || viewModel.isLoadingTasks)
        .opacity(viewModel.isExporting || viewModel.isLoadingTasks ? 0.46 : 1)
        .accessibilityLabel("选择任务")
        .accessibilityValue(viewModel.selectedTaskDisplayName)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var taskBrowserMode: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    viewModel.dismissTaskBrowser()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.075))
                        )
                }
                .buttonStyle(.plain)
                .help("返回会话")
                .accessibilityLabel("返回会话")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("搜索任务标题和对话内容", text: $taskSearchText)
                        .textFieldStyle(.plain)
                        .focused($taskSearchIsFocused)
                        .onChange(of: taskSearchText) { query in
                            viewModel.updateTaskBrowserQuery(query)
                        }
                        .onSubmit {
                            if !viewModel.isLoadingTaskBrowser,
                               let first = viewModel.taskBrowserResults.first {
                                viewModel.selectTaskFromBrowser(first)
                            }
                        }
                    if !taskSearchText.isEmpty {
                        Button {
                            taskSearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.075))
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .frame(height: 56)

            Divider()

            taskBrowserResults
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: handleTaskBrowserExit)
    }

    private func handleTaskBrowserExit() {
        if taskSearchText.isEmpty {
            viewModel.dismissTaskBrowser()
        } else {
            taskSearchText = ""
        }
    }

    @ViewBuilder
    private var taskBrowserResults: some View {
        if viewModel.taskBrowserResults.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                if viewModel.isLoadingTaskBrowser {
                    ProgressView()
                    Text("正在读取任务…")
                        .foregroundStyle(.secondary)
                } else if let error = viewModel.taskBrowserError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("重试") { viewModel.retryTaskBrowser() }
                } else {
                    Image(systemName: "text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(taskSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "还没有可导出的任务"
                        : "没有找到相关任务")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.taskBrowserResults) { task in
                        Button {
                            viewModel.selectTaskFromBrowser(task)
                        } label: {
                            HStack(alignment: .center, spacing: 10) {
                                Image(systemName: viewModel.selectedTaskID == task.id
                                    ? "checkmark.circle.fill"
                                    : "circle")
                                    .foregroundStyle(viewModel.selectedTaskID == task.id
                                        ? Color.accentColor
                                        : Color.secondary)

                                Text(task.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(task.displayName)

                                Text(task.updatedLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(task.displayName)
                        .accessibilityValue(viewModel.selectedTaskID == task.id
                            ? "已选择，\(task.updatedLabel)"
                            : "未选择，\(task.updatedLabel)")
                        .onAppear {
                            viewModel.loadMoreTaskBrowserResults(
                                approaching: task.id
                            )
                        }

                        Divider().padding(.leading, 42)
                    }

                    if viewModel.isLoadingTaskBrowser {
                        ProgressView()
                            .controlSize(.small)
                            .padding(12)
                    } else if let error = viewModel.taskBrowserError {
                        HStack(spacing: 8) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            Button("重试") { viewModel.retryTaskBrowser() }
                                .buttonStyle(.link)
                        }
                        .padding(12)
                    }
                }
            }
            .id(viewModel.taskBrowserQuery)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = viewModel.errorMessage, viewModel.messages.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 340)
                Button("重试") { Task { await viewModel.refresh() } }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.messages.isEmpty {
            ScrollView {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Image(systemName: "text.bubble")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(
                        viewModel.isLoadingMessages
                            || viewModel.isPrefetchingRecentMessages
                            || viewModel.isLoadingOlderMessages
                            ? "正在读取消息…"
                            : (viewModel.hasMoreMessages
                                ? "向上滚动以查找更早的问答"
                                : "这个任务没有可导出的问答")
                    )
                        .foregroundStyle(.secondary)
                    if let error = viewModel.olderMessagesError {
                        Text("更早消息加载失败：\(error)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)
                        Button("重试") { viewModel.loadMoreOlderMessages() }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 520)
                .background {
                    UpwardHistoryLoadObserver(
                        isEnabled: viewModel.canAutomaticallyLoadOlderMessages,
                        canQueueWhileBusy: viewModel.canQueueAutomaticOlderMessages,
                        onUserScroll: {},
                        onApproachingTop: {
                            viewModel.loadMoreOlderMessagesAutomatically()
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("已选 \(viewModel.selectedCount) 条")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if viewModel.isSelectingAll {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                            Text("全选中…")
                                .foregroundStyle(.secondary)
                            Button("取消") {
                                viewModel.cancelLoadingOlderMessages()
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                    } else {
                        Button(
                            viewModel.isWholeConversationSelectionActive
                                ? "取消全选"
                                : "全选"
                        ) {
                            viewModel.toggleSelectAllMessages()
                        }
                        .buttonStyle(.link)
                        .disabled(!viewModel.canSelectAll)
                        .help(
                            viewModel.isWholeConversationSelectionActive
                                ? "恢复为仅选择最新一轮"
                                : (viewModel.hasMoreMessages
                                    ? "读取完整历史后全选"
                                    : "选择完整会话")
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                historyLoadingStatus

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.messages) { message in
                                MessageSelectionRow(
                                    message: message,
                                    isSelected: viewModel.isSelected(message.id)
                                ) {
                                    viewModel.toggleMessage(
                                        message.id,
                                        extendingRange: NSEvent.modifierFlags.contains(.shift)
                                    )
                                }
                                .id(message.id)
                                .disabled(viewModel.isExporting || viewModel.isSelectingAll)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(MessageScrollMarker.bottom)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background {
                            UpwardHistoryLoadObserver(
                                isEnabled: viewModel.canAutomaticallyLoadOlderMessages,
                                canQueueWhileBusy: viewModel.canQueueAutomaticOlderMessages,
                                onUserScroll: {
                                    messageListDidReceiveUserScroll()
                                },
                                onApproachingTop: {
                                    viewModel.loadMoreOlderMessagesAutomatically()
                                }
                            )
                        }
                    }
                    .onChange(of: viewModel.scrollTargetID) { target in
                        guard target != nil else { return }
                        shouldPinMessagesToBottom = true
                        queueMessageScrollToBottom(using: proxy)
                        viewModel.clearScrollTarget()
                    }
                    .onChange(of: viewModel.messages.count) { count in
                        guard count > 0 else { return }
                        queueMessageScrollToBottom(using: proxy)
                    }
                    .onAppear {
                        if viewModel.scrollTargetID != nil {
                            shouldPinMessagesToBottom = true
                            viewModel.clearScrollTarget()
                        }
                        queueMessageScrollToBottom(using: proxy)
                    }
                }
            }
        }
    }

    private func messageListDidReceiveUserScroll() {
        guard !viewModel.isTaskBrowserPresented else { return }
        shouldPinMessagesToBottom = false
    }

    private func queueMessageScrollToBottom(using proxy: ScrollViewProxy) {
        guard shouldPinMessagesToBottom else { return }
        DispatchQueue.main.async {
            guard shouldPinMessagesToBottom else { return }
            proxy.scrollTo(MessageScrollMarker.bottom, anchor: .bottom)
        }
    }

    @ViewBuilder
    private var historyLoadingStatus: some View {
        if let error = viewModel.olderMessagesError {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("更早消息加载失败：\(error)")
                    .lineLimit(2)
                Spacer()
                Button("重试") { viewModel.loadMoreOlderMessages() }
                    .buttonStyle(.link)
                    .disabled(viewModel.isExporting)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let status = footerStatus {
                HStack(spacing: 6) {
                    if status.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: status.isError
                            ? "exclamationmark.circle"
                            : "checkmark.circle")
                    }
                    Text(status.message).lineLimit(2)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(status.isError ? Color.red : Color.secondary)
                .accessibilityElement(children: .combine)
            }

            HStack(spacing: 6) {
                FooterActionTile(
                    title: "刷新",
                    icon: .system("arrow.clockwise"),
                    isBusy: viewModel.isLoadingTasks || viewModel.isLoadingMessages,
                    appearance: .regular,
                    isDisabled: !canRefresh
                ) {
                    Task { await viewModel.refresh() }
                }
                .help("重新读取任务和当前会话")

                FooterActionTile(
                    title: "自启",
                    icon: .system(launchAtLogin.requiresApproval
                        ? "exclamationmark.circle.fill"
                        : (launchAtLogin.isRegistered
                            ? "checkmark.circle.fill"
                            : "circle")),
                    isBusy: false,
                    appearance: launchAtLogin.isRegistered ? .selected : .regular,
                    isDisabled: !launchAtLogin.canToggle
                ) {
                    launchAtLogin.toggle()
                }
                .help(launchAtLogin.requiresApproval
                    ? "已注册；需要在系统设置中批准"
                    : "登录 macOS 后自动运行")
                .accessibilityValue(launchAtLogin.accessibilityValue)
                .accessibilityHint("切换登录时自动启动")

                FooterActionTile(
                    title: "更新",
                    icon: .system("arrow.triangle.2.circlepath"),
                    isBusy: softwareUpdate.isBusy,
                    appearance: updateAppearance,
                    isDisabled: !softwareUpdate.canToggle
                ) {
                    softwareUpdate.toggle()
                }
                .accessibilityLabel("自动更新")
                .accessibilityValue(softwareUpdate.accessibilityValue)
                .accessibilityHint("切换自动更新")
                .help(softwareUpdate.helpText)

                FooterActionTile(
                    title: "GitHub",
                    icon: .asset("GitHubMark"),
                    isBusy: false,
                    appearance: .regular,
                    isDisabled: !githubIsConfigured
                ) {
                    onOpenGitHub()
                }
                .accessibilityLabel("GitHub")
                .accessibilityValue(
                    githubIsConfigured ? "打开公开仓库" : "公开仓库尚未配置"
                )
                .help(
                    githubIsConfigured ? "打开 Codex Export GitHub 仓库" : "公开仓库尚未配置"
                )

                FooterActionTile(
                    title: "退出",
                    icon: .system("power"),
                    isBusy: false,
                    appearance: .exit,
                    isDisabled: viewModel.isExporting
                ) {
                    onQuit()
                }
                .help("退出 Codex Export")

                FooterActionTile(
                    title: "保存",
                    icon: .system("square.and.arrow.down"),
                    isBusy: false,
                    appearance: .secondary,
                    isDisabled: !viewModel.canExport
                ) {
                    Task { await viewModel.saveImage() }
                }
                .help("保存所选消息的图片")

                FooterActionTile(
                    title: "复制",
                    icon: .system("doc.on.doc"),
                    isBusy: false,
                    appearance: .prominent,
                    isDisabled: !viewModel.canExport
                ) {
                    Task { await viewModel.copyImage() }
                }
                .help("复制所选消息的图片")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
    }

    private var canRefresh: Bool {
        !viewModel.isLoadingTasks
            && !viewModel.isLoadingMessages
            && !viewModel.isPrefetchingRecentMessages
            && !viewModel.isLoadingOlderMessages
            && !viewModel.isSelectingAll
            && !viewModel.isExporting
            && !viewModel.isQuiescingForSoftwareUpdate
    }

    private var updateAppearance: FooterActionAppearance {
        if softwareUpdate.hasAvailableUpdate { return .updateAvailable }
        if softwareUpdate.isEnabled, softwareUpdate.isConfirmedUpToDate {
            return .upToDate
        }
        return .regular
    }

    private var footerStatus: (message: String, isError: Bool, isBusy: Bool)? {
        if viewModel.isExporting {
            return (
                viewModel.statusMessage ?? "正在生成图片…",
                false,
                true
            )
        }
        if viewModel.isSelectingAll {
            return nil
        }
        if let message = viewModel.statusMessage,
           viewModel.statusUpdatedAt ?? 0 >= launchAtLogin.errorUpdatedAt ?? 0 {
            return (message, viewModel.statusIsError, false)
        }
        if let message = launchAtLogin.errorMessage {
            return (message, true, false)
        }
        return nil
    }

}
