import AppKit
import Darwin

enum ApplicationTerminationSmoke {
    private static let argument = "--termination-smoke"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    @MainActor
    static func start() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + 5
        ) {
            // A successful AppKit termination exits first. Reaching this
            // watchdog means the two-phase handshake stalled.
            Darwin._exit(70)
        }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}
