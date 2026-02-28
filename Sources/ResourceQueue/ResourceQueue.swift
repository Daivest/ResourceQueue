//
//  ResourceQueue.swift
//  ResourceQueue
//
//  Created by Andrew on 27.02.2026.
//

/// A priority-based concurrent task queue.
///
/// `ResourceQueue` manages the execution of tasks according to a ``Resolver`` that
/// controls how many tasks may run concurrently based on their priority.
///
/// ### Usage
///
/// ```swift
/// let queue = ResourceQueue(resolver: FixedResolver<Priority>(concurrency: 4))
///
/// let handle = try queue.enqueue(priority: .high) {
///     try await fetchData()
/// }
///
/// let data = try await handle.value
/// ```
///
/// ### Task Lifecycle
///
/// 1. A task is **enqueued** and placed in the pending list sorted by priority.
/// 2. The queue's drain loop asks the resolver whether the task can start.
/// 3. When started, the task executes concurrently.
/// 4. On completion, the result is delivered to anyone awaiting `handle.value`.
///
/// ### Cancellation and Priority Updates
///
/// The ``TaskHandle`` returned from ``enqueue(priority:operation:)`` supports:
/// - ``TaskHandle/cancel()`` — removes a pending task or cooperatively cancels a running one.
/// - ``TaskHandle/updatePriority(_:)`` — re-prioritizes a pending task.
public actor ResourceQueue<P: PriorityProtocol, R: Resolver<P>> {

    // MARK: - Internal Types

    struct PendingEntry {
        let id: UInt64
        var priority: P
        let operation: @Sendable () async throws -> any Sendable
    }

    enum EntryState {
        case pending
        case running
        case completed(Result<any Sendable, any Error>)
        case cancelled
    }

    // MARK: - State

    private let resolver: R
    private let pendingLimit: Int

    private var pendingTasks: [PendingEntry] = []
    public private(set) var executingCount: Int = 0

    /// The number of tasks currently waiting to be started.
    public var pendingCount: Int { pendingTasks.count }
    private var nextID: UInt64 = 0

    private var entryStates: [UInt64: EntryState] = [:]
    private var waitingContinuations: [UInt64: [CheckedContinuation<any Sendable, any Error>]] = [:]
    private var runningSwiftTasks: [UInt64: Task<Void, Never>] = [:]

    // MARK: - Init

    /// Creates a new resource queue.
    ///
    /// - Parameters:
    ///   - resolver: The resolver that controls task admission.
    ///   - pendingLimit: Maximum number of tasks waiting in the queue. Default is 8192.
    public init(resolver: R, pendingLimit: Int = 8192) {
        self.resolver = resolver
        self.pendingLimit = pendingLimit
    }

    // MARK: - Enqueue

    /// Enqueues a task for execution.
    ///
    /// The task is placed in the pending list sorted by priority. The queue's drain loop
    /// will start it when the resolver allows.
    ///
    /// - Parameters:
    ///   - priority: The priority of the task.
    ///   - operation: The async work to perform.
    /// - Returns: A ``TaskHandle`` for awaiting the result, cancelling, or updating priority.
    /// - Throws: ``ResourceQueueError/pendingLimitExceeded`` if the pending queue is full.
    @discardableResult
    public func enqueue<T: Sendable>(
        priority: P,
        operation: @escaping @Sendable () async throws -> T
    ) throws -> TaskHandle<T, P, R> {
        guard pendingTasks.count < pendingLimit else {
            throw ResourceQueueError.pendingLimitExceeded
        }

        let id = nextID
        nextID += 1

        let entry = PendingEntry(
            id: id,
            priority: priority,
            operation: operation
        )

        entryStates[id] = .pending
        insertSorted(entry)
        drain()

        return TaskHandle(id: id, queue: self)
    }

    // MARK: - TaskHandle Interface

    func awaitResult(id: UInt64) async throws -> any Sendable {
        // If already completed, return immediately
        if let state = entryStates[id] {
            switch state {
            case .completed(let result):
                cleanup(id: id)
                return try result.get()
            case .cancelled:
                cleanup(id: id)
                throw CancellationError()
            case .pending, .running:
                break
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            waitingContinuations[id, default: []].append(continuation)
        }
    }

    func cancel(id: UInt64) {
        guard let state = entryStates[id] else { return }

        switch state {
        case .pending:
            // Remove from pending list
            pendingTasks.removeAll { $0.id == id }
            entryStates[id] = .cancelled
            resumeContinuations(id: id, with: .failure(CancellationError()))
            drain()

        case .running:
            // Cancel the running Swift Task
            runningSwiftTasks[id]?.cancel()

        case .completed, .cancelled:
            break
        }
    }

    func updatePriority(id: UInt64, to newPriority: P) {
        guard let state = entryStates[id], case .pending = state else { return }
        guard let index = pendingTasks.firstIndex(where: { $0.id == id }) else { return }

        var entry = pendingTasks.remove(at: index)
        entry.priority = newPriority
        insertSorted(entry)
        drain()
    }

    // MARK: - Re-evaluate

    /// Triggers a drain pass, allowing pending tasks to start if conditions have changed.
    ///
    /// Call this method when external factors that affect the resolver's decisions
    /// have changed — for example, updated capacity values in a ``LaneResolver``.
    ///
    /// ```swift
    /// // After updating capacity storage:
    /// await queue.drain()
    /// ```
    public func drain() {
        var toStart: [Int] = []
        let projected = executingCount

        for i in pendingTasks.indices {
            let effectiveCount = projected + toStart.count
            if resolver.shouldStart(executingCount: effectiveCount, priority: pendingTasks[i].priority) {
                toStart.append(i)
            }
        }

        for i in toStart.reversed() {
            let entry = pendingTasks.remove(at: i)
            executingCount += 1
            entryStates[entry.id] = .running
            launch(entry)
        }
    }

    // MARK: - Launch

    private func launch(_ entry: PendingEntry) {
        let task = Task { [weak self] in
            let result: Result<any Sendable, any Error>
            do {
                let value = try await entry.operation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            await self?.taskCompleted(id: entry.id, result: result)
        }
        runningSwiftTasks[entry.id] = task
    }

    // MARK: - Completion

    private func taskCompleted(id: UInt64, result: Result<any Sendable, any Error>) {
        executingCount -= 1
        runningSwiftTasks.removeValue(forKey: id)
        entryStates[id] = .completed(result)
        resumeContinuations(id: id, with: result)
        drain()
    }

    // MARK: - Helpers

    private func insertSorted(_ entry: PendingEntry) {
        // Insert maintaining descending priority order (highest first)
        let index = pendingTasks.firstIndex { $0.priority < entry.priority } ?? pendingTasks.endIndex
        pendingTasks.insert(entry, at: index)
    }

    private func resumeContinuations(id: UInt64, with result: Result<any Sendable, any Error>) {
        guard let continuations = waitingContinuations.removeValue(forKey: id) else { return }
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func cleanup(id: UInt64) {
        entryStates.removeValue(forKey: id)
        waitingContinuations.removeValue(forKey: id)
    }
}
