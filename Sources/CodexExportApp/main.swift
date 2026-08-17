import AppKit

if let status = SoftwareUpdateInstaller.runIfRequested(
    arguments: CommandLine.arguments
) {
    exit(status)
}

let appDelegate = MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()

    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    return appDelegate
}

NSApplication.shared.run()
withExtendedLifetime(appDelegate) {}
