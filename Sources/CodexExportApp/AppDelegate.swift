import AppKit
import CodexExportCore
import CodexExportFeature
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var outsideClickMonitor: Any?
    private var textSelectionShortcutMonitor: Any?
    private var isFinishingTermination = false
    private var isUpdateInstallationReserved = false
    private let popover = NSPopover()
    private lazy var appServerClient = CodexAppServerClient(
        configuration: .init(clientVersion: Self.bundleVersion)
    )
    private lazy var viewModel = ExportViewModel(
        client: appServerClient,
        imageRenderer: WebMarkdownRenderer(
            resourceDirectory: AppResources.webRendererDirectory
        ),
        exportDestination: MacImageExportDestination()
    )
    private lazy var launchAtLogin = LaunchAtLoginController(
        service: SystemLaunchAtLoginService()
    )
    private lazy var updateConfiguration = SoftwareUpdateConfiguration.load()
    private lazy var updatePreferences = UserDefaultsSoftwareUpdatePreferences()
    private lazy var softwareUpdateService: any SoftwareUpdateServicing = {
        if let updateConfiguration {
            return GitHubSoftwareUpdateService(
                configuration: updateConfiguration
            )
        }
        return UnavailableSoftwareUpdateService()
    }()
    private lazy var softwareUpdate = SoftwareUpdateController(
        currentVersion: Self.bundleVersion,
        currentBuild: Self.bundleBuild,
        isConfigured: updateConfiguration != nil,
        service: softwareUpdateService,
        preferences: updatePreferences,
        reserveInstallation: { [weak self] in
            self?.reserveForSoftwareUpdateInstallation() ?? false
        },
        releaseInstallationReservation: { [weak self] in
            self?.releaseSoftwareUpdateInstallationReservation()
        },
        requestTermination: {
            NSApplication.shared.terminate(nil)
        }
    )

    private static var bundleVersion: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
    }

    private static var bundleBuild: Int {
        let value = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        return value.flatMap(Int.init) ?? 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if RendererSmoke.isRequested {
            RendererSmoke.start()
            return
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = statusIcon(named: "StatusIcon") {
                button.image = image
            } else {
                let fallback = NSImage(
                    systemSymbolName: "rectangle.portrait.and.arrow.right",
                    accessibilityDescription: "Codex Export"
                )
                if let fallback {
                    fallback.isTemplate = true
                    button.image = fallback
                } else {
                    button.title = "CE"
                }
            }
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityLabel("Codex Export")
            button.toolTip = "Codex Export \(Self.bundleVersion)"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = statusItem

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 480, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: ExportPopoverView(
                viewModel: viewModel,
                launchAtLogin: launchAtLogin,
                softwareUpdate: softwareUpdate,
                githubIsConfigured: updateConfiguration != nil,
                onOpenGitHub: { [weak self] in self?.openGitHubRepository() },
                onQuit: { NSApplication.shared.terminate(nil) }
            )
        )
        softwareUpdate.start()
        SoftwareUpdateInstaller.reportHealthIfRequested(
            arguments: ProcessInfo.processInfo.arguments
        )

        let wasExplicitlyRequested = ProcessInfo.processInfo.arguments.contains(
            "--show-popover"
        )
        #if DEBUG
        let debugRequested = ProcessInfo.processInfo.environment[
            "CODEX_EXPORT_SHOW_POPOVER"
        ] == "1"
        #else
        let debugRequested = false
        #endif
        if wasExplicitlyRequested || debugRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showPopover()
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.activate(ignoringOtherApps: true)
        showPopover()
        return false
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !isFinishingTermination else { return .terminateLater }
        isFinishingTermination = true
        removeOutsideClickMonitor()
        removeTextSelectionShortcutMonitor()
        Task { @MainActor in
            await softwareUpdate.shutdown()
            await viewModel.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidResignActive(_ notification: Notification) {
        guard popover.isShown else { return }
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
        removeTextSelectionShortcutMonitor()
        viewModel.dismissTaskBrowser()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        showPopover()
    }

    private func showPopover() {
        guard !isUpdateInstallationReserved else { return }
        guard let button = statusItem?.button else { return }
        launchAtLogin.refreshStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else { return }
        installOutsideClickMonitor()
        installTextSelectionShortcutMonitor()
        popover.contentViewController?.view.window?.makeKey()
        Task { await viewModel.loadIfNeeded() }
    }

    private func reserveForSoftwareUpdateInstallation() -> Bool {
        guard !isFinishingTermination,
              !isUpdateInstallationReserved,
              !popover.isShown,
              viewModel.reserveForSoftwareUpdateRestart() else {
            return false
        }
        isUpdateInstallationReserved = true
        return true
    }

    private func releaseSoftwareUpdateInstallationReservation() {
        guard isUpdateInstallationReserved else { return }
        isUpdateInstallationReserved = false
        viewModel.cancelSoftwareUpdateRestartReservation()
    }

    private func openGitHubRepository() {
        guard let url = updateConfiguration?.repositoryURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.close()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func installTextSelectionShortcutMonitor() {
        guard textSelectionShortcutMonitor == nil else { return }
        textSelectionShortcutMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            let relevantModifiers = event.modifierFlags.intersection(
                [.command, .control, .option, .shift]
            )
            let isSelectAllModifier = relevantModifiers == .command
                || relevantModifiers == .control
            let isAKey = event.charactersIgnoringModifiers?.lowercased() == "a"

            guard isSelectAllModifier,
                  isAKey,
                  popover.isShown,
                  viewModel.isTaskBrowserPresented,
                  event.window === popover.contentViewController?.view.window,
                  let editor = event.window?.firstResponder as? NSTextView,
                  editor.isFieldEditor,
                  editor.isEditable,
                  editor.isSelectable else {
                return event
            }

            editor.selectAll(nil)
            return nil
        }
    }

    private func statusIcon(named name: String) -> NSImage? {
        guard let image = NSImage(named: NSImage.Name(name)) else {
            return nil
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        image.accessibilityDescription = "Codex Export"
        return image
    }

    private func removeTextSelectionShortcutMonitor() {
        guard let textSelectionShortcutMonitor else { return }
        NSEvent.removeMonitor(textSelectionShortcutMonitor)
        self.textSelectionShortcutMonitor = nil
    }
}
