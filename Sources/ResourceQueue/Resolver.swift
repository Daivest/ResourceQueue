//
//  Resolver.swift
//  ResourceQueue
//
//  Created by Andrew on 27.02.2026.
//

/// Controls whether a pending task is allowed to start execution.
///
/// The queue calls ``shouldStart(executingCount:priority:)`` for the highest-priority
/// pending task each time a slot may become available. If the method returns `true`,
/// the task is launched; otherwise the queue stops dispatching until conditions change.
///
/// ## Built-in Resolvers
///
/// - ``FixedResolver``: Allows a fixed number of concurrent tasks, ignoring priority.
/// - ``BlockResolver``: Delegates the decision to a caller-provided closure.
/// - ``LaneResolver``: Divides concurrency into priority-based lanes where
///   higher-priority tasks can occupy lower-priority slots.
///
/// ## Custom Resolvers
///
/// Implement this protocol to create your own admission strategy:
///
/// ```swift
/// struct ThrottledResolver<P: PriorityProtocol>: Resolver {
///     func shouldStart(executingCount: Int, priority: P) -> Bool {
///         // your custom logic
///     }
/// }
/// ```
public protocol Resolver<P>: Sendable {
    associatedtype P: PriorityProtocol

    /// Decides whether a task with the given priority can be launched.
    ///
    /// - Parameters:
    ///   - executingCount: The total number of tasks currently in execution across all priorities.
    ///   - priority: The priority of the candidate task.
    /// - Returns: `true` if the task should be launched, `false` otherwise.
    func shouldStart(executingCount: Int, priority: P) -> Bool
}

/// A resolver that allows up to a fixed number of concurrent tasks regardless of priority.
///
/// All tasks share the same concurrency pool. Priority affects only the order in which
/// pending tasks are considered, not the number of available slots.
///
/// ```swift
/// // Allow up to 4 tasks to run concurrently
/// let resolver = FixedResolver<Priority>(concurrency: 4)
/// ```
public struct FixedResolver<P: PriorityProtocol>: Resolver, Sendable {

    /// The maximum number of tasks that can execute concurrently.
    public let concurrency: Int

    public init(concurrency: Int) {
        self.concurrency = concurrency
    }

    public func shouldStart(executingCount: Int, priority: P) -> Bool {
        executingCount < concurrency
    }
}

/// A resolver that delegates the start decision to a closure evaluated at call time.
///
/// Use `BlockResolver` when the admission logic depends on external state that may
/// change between evaluations, and you don't want to create a dedicated ``Resolver`` type.
///
/// ```swift
/// let resolver = BlockResolver<Priority> { executingCount, priority in
///     executingCount < currentLimit(for: priority)
/// }
/// ```
public struct BlockResolver<P: PriorityProtocol>: Resolver, Sendable {

    private let block: @Sendable (Int, P) -> Bool

    /// Creates a resolver backed by the given closure.
    ///
    /// - Parameter block: A closure called each time the queue considers starting a task.
    ///   Receives the current executing count and the candidate task's priority.
    ///   Return `true` to allow the task to start.
    public init(_ block: @escaping @Sendable (Int, P) -> Bool) {
        self.block = block
    }

    public func shouldStart(executingCount: Int, priority: P) -> Bool {
        block(executingCount, priority)
    }
}
