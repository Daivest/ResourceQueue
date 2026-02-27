//
//  Priority.swift
//  ResourceQueue
//
//  Created by Andrew on 27.02.2026.
//

import Foundation

/// A type that represents a task priority level for use with ``ResourceQueue``.
///
/// Conform your custom types to this protocol to define your own priority system.
/// The only requirements are `Comparable` (to determine ordering) and `Sendable`
/// (for safe use across concurrency domains).
///
/// The queue processes pending tasks in descending priority order: higher-priority
/// tasks are considered for execution first.
///
/// ## Conforming to PriorityProtocol
///
/// At minimum, implement `Comparable` so the queue knows which tasks take precedence:
///
/// ```swift
/// enum MyPriority: PriorityProtocol {
///     case background
///     case normal
///     case urgent
/// }
/// ```
///
public protocol PriorityProtocol: Comparable, Sendable {}

// MARK: - Int + PriorityProtocol

/// `Int` conforms to ``PriorityProtocol`` out of the box.
///
/// Higher values represent higher priority. Use with ``FixedResolver`` for a simple
/// priority-ordered queue, or with ``LaneResolver`` to map integer ranges to capacity levels.
///
/// ```swift
/// let resolver = LaneResolver<Int> { priority in
///     switch priority {
///     case 8...:  10   // high
///     case 4..<8:  5   // medium
///     default:     1   // low
///     }
/// }
/// ```
extension Int: PriorityProtocol {}

/// A simple three-level priority type.
///
/// Cases are declared in ascending order so that synthesized `Comparable`
/// conformance matches the expected semantics: `low < medium < high`.
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
public enum Priority: PriorityProtocol, CaseIterable {
    case low
    case medium
    case high
}

/// A composite priority that adds sub-ordering within a priority level.
///
/// Use this when multiple tasks share the same ``Priority`` level but you need
/// finer control over which one runs first. Tasks are compared by ``level`` first,
/// then by ``order`` — a higher `order` value means higher priority within the same level.
///
/// ### Usage
///
/// ```swift
/// let importantSync   = OrderedPriority(level: .high, order: 10)
/// let routineSync     = OrderedPriority(level: .high, order: 1)
/// let backgroundTask  = OrderedPriority(level: .low, order: 0)
///
/// // importantSync > routineSync > backgroundTask
/// ```
///
/// ### With LaneResolver
///
/// ``OrderedPriority`` works with ``LaneResolver`` by mapping through its ``level``:
///
/// ```swift
/// let resolver = LaneResolver<OrderedPriority> { priority in
///     switch priority.level {
///     case .high:   10
///     case .medium:  5
///     case .low:     1
///     }
/// }
/// ```
public struct OrderedPriority: PriorityProtocol {
    /// The broad priority level that determines the concurrency lane.
    public let level: Priority

    /// The sub-ordering within the same level. Higher values take precedence.
    public let order: Int

    public init(level: Priority, order: Int) {
        self.level = level
        self.order = order
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.level != rhs.level { return lhs.level < rhs.level }
        return lhs.order < rhs.order
    }
}
