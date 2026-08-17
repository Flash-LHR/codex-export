import Foundation

/// Serializes access to the renderer's single mutable DOM. A queued task may
/// leave immediately when cancelled; a task that already owns the permit must
/// release it in `defer` after its active WebKit operation has settled.
@MainActor
final class RenderFIFO {
    private var isHeld = false
    private var order: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func withPermit<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isHeld {
            isHeld = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                order.append(id)
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelQueued(id)
            }
        }
    }

    private func cancelQueued(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else {
            return
        }
        order.removeAll { $0 == id }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while let id = order.first {
            order.removeFirst()
            guard let continuation = waiters.removeValue(forKey: id) else {
                continue
            }
            continuation.resume(returning: ())
            return
        }
        isHeld = false
    }

    var queuedCount: Int { waiters.count }
}

@MainActor
protocol RenderTimeoutToken: AnyObject {
    func cancel()
}

@MainActor
protocol RenderTimeoutScheduling: AnyObject {
    func schedule(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any RenderTimeoutToken
}

@MainActor
final class TaskRenderTimeoutScheduler: RenderTimeoutScheduling {
    private let nanoseconds: UInt64

    init(nanoseconds: UInt64 = 10_000_000_000) {
        self.nanoseconds = nanoseconds
    }

    func schedule(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any RenderTimeoutToken {
        let token = TaskRenderTimeoutToken()
        token.task = Task { @MainActor [weak token] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
            token?.task = nil
        }
        return token
    }
}

@MainActor
private final class TaskRenderTimeoutToken: RenderTimeoutToken {
    var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

@MainActor
private protocol AnyWebOperationGate: AnyObject {
    func requestCancellation()
}

/// Resolves a callback, timeout, or caller cancellation exactly once. Caller
/// cancellation is deliberately deferred until the WebKit callback or timeout:
/// releasing the render permit earlier would let old JavaScript mutate the DOM
/// while a newer export is using it.
@MainActor
private final class WebOperationGate<Value: Sendable>: AnyWebOperationGate {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutToken: (any RenderTimeoutToken)?
    private var cancellationRequested = false
    private var onFinish: (() -> Void)?

    init(
        continuation: CheckedContinuation<Value, Error>,
        onFinish: @escaping () -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func armTimeout(
        scheduler: any RenderTimeoutScheduling,
        error: Error
    ) {
        timeoutToken = scheduler.schedule { [weak self] in
            self?.finish(.failure(error))
        }
    }

    func requestCancellation() {
        cancellationRequested = true
    }

    func complete(_ result: Result<Value, Error>) {
        finish(result)
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutToken?.cancel()
        timeoutToken = nil
        onFinish?()
        onFinish = nil

        if cancellationRequested {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(with: result)
        }
    }
}

@MainActor
final class WebOperationCoordinator {
    private let scheduler: any RenderTimeoutScheduling
    private var gates: [UUID: any AnyWebOperationGate] = [:]

    init(scheduler: (any RenderTimeoutScheduling)? = nil) {
        self.scheduler = scheduler ?? TaskRenderTimeoutScheduler()
    }

    func perform<Value: Sendable>(
        timeoutError: Error,
        start: (
            _ completion: @escaping @Sendable (Result<Value, Error>) -> Void
        ) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let id = UUID()

        do {
            let value = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let gate = WebOperationGate<Value>(
                        continuation: continuation,
                        onFinish: { [weak self] in self?.gates[id] = nil }
                    )
                    gates[id] = gate
                    gate.armTimeout(scheduler: scheduler, error: timeoutError)
                    start { [weak gate] result in
                        Task { @MainActor in
                            gate?.complete(result)
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.gates[id]?.requestCancellation()
                }
            }

            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    var pendingCount: Int { gates.count }
}
