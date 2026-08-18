import AppKit

/// Converts AppKit's synchronous termination callback into a two-phase exit.
///
/// The first request is cancelled immediately so the current main-actor job
/// and AppKit call stack can unwind. Cleanup then runs asynchronously. Once it
/// finishes, termination is retried and synchronously accepted.
@MainActor
final class ApplicationTerminationCoordinator {
    private var isPrepared = false
    private var preparationTask: Task<Void, Never>?

    func reply(
        prepare: @escaping @MainActor @Sendable () async -> Void,
        retry: @escaping @MainActor @Sendable () -> Void
    ) -> NSApplication.TerminateReply {
        if isPrepared {
            return .terminateNow
        }

        if preparationTask == nil {
            preparationTask = Task { @MainActor [weak self] in
                await prepare()
                guard let self else { return }
                isPrepared = true
                retry()
            }
        }

        return .terminateCancel
    }
}
