//
//  LaneResolver.swift
//  ResourceQueue
//
//  Created by Andrew on 27.02.2026.
//

/// A resolver that divides concurrency into priority-based lanes.
///
/// Each priority level is assigned a number of execution slots. Higher-priority tasks
/// can occupy slots reserved for lower priorities, but not vice versa. This creates
/// a cascading model where the cumulative capacity grows with priority.
///
/// ### Slot Model
///
/// Given three priority levels with the following slot distribution:
///
/// | Priority | Own slots | Cumulative capacity |
/// |----------|-----------|---------------------|
/// | high     | 5         | 10 (5 + 3 + 2)     |
/// | medium   | 3         | 5 (3 + 2)           |
/// | low      | 2         | 2                   |
///
/// A `.high` task can start if fewer than 10 tasks are currently running.
/// A `.low` task can only start if fewer than 2 tasks are running.
///
/// The closure receives a priority and returns its **cumulative capacity** —
/// the maximum number of concurrently executing tasks at which a task of that
/// priority is still allowed to start.
///
/// ### Usage
///
/// ```swift
/// let resolver = LaneResolver<Priority> { priority in
///     switch priority {
///     case .high:   10
///     case .medium:  5
///     case .low:     1
///     }
/// }
/// ```
///
/// ### Dynamic Adjustment
///
/// Because the capacity is resolved via a closure, it can adapt to runtime conditions:
///
/// ```swift
/// let resolver = LaneResolver<Priority> { priority in
///     if SystemResources.isConstrained {
///         return priority == .high ? 2 : 0
///     }
///     return defaultCapacity(for: priority)
/// }
/// ```
///
/// Returning `0` for a priority level effectively disables scheduling for that level.
/// Tasks already in execution are not affected — they will run to completion.
public struct LaneResolver<P: PriorityProtocol>: Resolver, Sendable {

    /// A closure that returns the cumulative execution capacity for a given priority.
    public typealias CapacityResolver = @Sendable (P) -> Int

    private let capacityResolver: CapacityResolver

    /// Creates a lane resolver with the given capacity closure.
    ///
    /// - Parameter capacityResolver: A closure that returns the maximum number of
    ///   concurrently executing tasks allowed when scheduling a task of the given priority.
    public init(_ capacityResolver: @escaping CapacityResolver) {
        self.capacityResolver = capacityResolver
    }

    public func shouldStart(executingCount: Int, priority: P) -> Bool {
        executingCount < capacityResolver(priority)
    }
}

