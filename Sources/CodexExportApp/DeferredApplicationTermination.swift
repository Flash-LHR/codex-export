import Foundation

/// Enqueues AppKit termination outside the current MainActor job.
///
/// `NSApplication.terminate(_:)` enters a nested event loop while it waits for
/// an asynchronous `applicationShouldTerminate` reply. Calling it directly
/// from a MainActor task would keep that actor job occupied and prevent the
/// reply task from running.
@MainActor
enum DeferredApplicationTermination {
    static func schedule(
        _ terminate: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.main.async {
            terminate()
        }
    }
}
