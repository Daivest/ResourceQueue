import Testing
@testable import ResourceQueue

// MARK: - Priority Tests

@Suite("Priority ordering")
struct PriorityTests {

    @Test func lowIsLessThanMedium() {
        #expect(Priority.low < Priority.medium)
    }

    @Test func mediumIsLessThanHigh() {
        #expect(Priority.medium < Priority.high)
    }

    @Test func lowIsLessThanHigh() {
        #expect(Priority.low < Priority.high)
    }

    @Test func samePrioritiesAreEqual() {
        #expect(Priority.high == Priority.high)
        #expect(Priority.medium == Priority.medium)
        #expect(Priority.low == Priority.low)
    }

    @Test func sortedArrayMatchesExpectedOrder() {
        let shuffled: [Priority] = [.high, .low, .medium]
        let sorted = shuffled.sorted()
        #expect(sorted == [.low, .medium, .high])
    }
}

// MARK: - OrderedPriority Tests

@Suite("OrderedPriority ordering")
struct OrderedPriorityTests {

    @Test func levelTakesPrecedenceOverOrder() {
        let lowHighOrder = OrderedPriority(level: .low, order: 100)
        let highLowOrder = OrderedPriority(level: .high, order: 0)
        #expect(lowHighOrder < highLowOrder)
    }

    @Test func sameLevel_higherOrderWins() {
        let first = OrderedPriority(level: .medium, order: 1)
        let second = OrderedPriority(level: .medium, order: 10)
        #expect(first < second)
    }

    @Test func sameLevelAndOrder_areEqual() {
        let a = OrderedPriority(level: .high, order: 5)
        let b = OrderedPriority(level: .high, order: 5)
        #expect(a == b)
    }

    @Test func sortedArrayMatchesExpectedOrder() {
        let items = [
            OrderedPriority(level: .high, order: 1),
            OrderedPriority(level: .low, order: 0),
            OrderedPriority(level: .high, order: 10),
            OrderedPriority(level: .medium, order: 5),
        ]
        let sorted = items.sorted()
        #expect(sorted == [
            OrderedPriority(level: .low, order: 0),
            OrderedPriority(level: .medium, order: 5),
            OrderedPriority(level: .high, order: 1),
            OrderedPriority(level: .high, order: 10),
        ])
    }
}

// MARK: - Int as PriorityProtocol Tests

@Suite("Int as PriorityProtocol")
struct IntPriorityTests {

    @Test func intComparison() {
        let low: Int = 1
        let high: Int = 10
        #expect(low < high)
    }

    @Test func intsSortCorrectly() {
        let priorities = [5, 1, 10, 3]
        let sorted = priorities.sorted()
        #expect(sorted == [1, 3, 5, 10])
    }
}

// MARK: - FixedResolver Tests

@Suite("FixedResolver")
struct FixedResolverTests {

    @Test func allowsWhenBelowConcurrency() {
        let resolver = FixedResolver<Priority>(concurrency: 3)
        #expect(resolver.shouldStart(executingCount: 0, priority: .low))
        #expect(resolver.shouldStart(executingCount: 1, priority: .low))
        #expect(resolver.shouldStart(executingCount: 2, priority: .low))
    }

    @Test func blocksWhenAtConcurrency() {
        let resolver = FixedResolver<Priority>(concurrency: 3)
        #expect(!resolver.shouldStart(executingCount: 3, priority: .high))
    }

    @Test func blocksWhenAboveConcurrency() {
        let resolver = FixedResolver<Priority>(concurrency: 3)
        #expect(!resolver.shouldStart(executingCount: 5, priority: .high))
    }

    @Test func ignoresPriority() {
        let resolver = FixedResolver<Priority>(concurrency: 2)
        // Same executingCount, different priorities — same result
        #expect(resolver.shouldStart(executingCount: 1, priority: .low))
        #expect(resolver.shouldStart(executingCount: 1, priority: .high))
        #expect(!resolver.shouldStart(executingCount: 2, priority: .low))
        #expect(!resolver.shouldStart(executingCount: 2, priority: .high))
    }

    @Test func zeroConcurrencyBlocksEverything() {
        let resolver = FixedResolver<Priority>(concurrency: 0)
        #expect(!resolver.shouldStart(executingCount: 0, priority: .high))
    }
}

// MARK: - LaneResolver Tests

@Suite("LaneResolver")
struct LaneResolverTests {

    private func makeResolver() -> LaneResolver<Priority> {
        LaneResolver<Priority> { priority in
            switch priority {
            case .high:   10
            case .medium:  5
            case .low:     2
            }
        }
    }

    @Test func highPriorityUsesFullCapacity() {
        let resolver = makeResolver()
        #expect(resolver.shouldStart(executingCount: 0, priority: .high))
        #expect(resolver.shouldStart(executingCount: 9, priority: .high))
        #expect(!resolver.shouldStart(executingCount: 10, priority: .high))
    }

    @Test func mediumPriorityLimitedToOwnAndLowerSlots() {
        let resolver = makeResolver()
        #expect(resolver.shouldStart(executingCount: 4, priority: .medium))
        #expect(!resolver.shouldStart(executingCount: 5, priority: .medium))
    }

    @Test func lowPriorityOnlyUsesOwnSlots() {
        let resolver = makeResolver()
        #expect(resolver.shouldStart(executingCount: 1, priority: .low))
        #expect(!resolver.shouldStart(executingCount: 2, priority: .low))
    }

    @Test func zeroCapacityDisablesPriority() {
        let resolver = LaneResolver<Priority> { priority in
            switch priority {
            case .high:   5
            case .medium:  0
            case .low:     0
            }
        }
        #expect(!resolver.shouldStart(executingCount: 0, priority: .low))
        #expect(!resolver.shouldStart(executingCount: 0, priority: .medium))
        #expect(resolver.shouldStart(executingCount: 0, priority: .high))
    }

    @Test func dynamicCapacityIsReEvaluated() {
        var constrained = false
        // nonisolated(unsafe) since we're mutating from a single test context
        nonisolated(unsafe) let isConstrained = { constrained }

        let resolver = LaneResolver<Priority> { priority in
            if isConstrained() {
                return priority == .high ? 2 : 0
            }
            return 10
        }

        // Normal mode: medium allowed at 5
        #expect(resolver.shouldStart(executingCount: 5, priority: .medium))

        // Switch to constrained
        constrained = true
        #expect(!resolver.shouldStart(executingCount: 0, priority: .medium))
        #expect(resolver.shouldStart(executingCount: 1, priority: .high))
        #expect(!resolver.shouldStart(executingCount: 2, priority: .high))
    }

    @Test func worksWithIntPriority() {
        let resolver = LaneResolver<Int> { priority in
            switch priority {
            case 8...:   10
            case 4..<8:   5
            default:      1
            }
        }
        #expect(resolver.shouldStart(executingCount: 0, priority: 1))
        #expect(!resolver.shouldStart(executingCount: 1, priority: 1))
        #expect(resolver.shouldStart(executingCount: 4, priority: 5))
        #expect(!resolver.shouldStart(executingCount: 5, priority: 5))
        #expect(resolver.shouldStart(executingCount: 9, priority: 10))
        #expect(!resolver.shouldStart(executingCount: 10, priority: 10))
    }

    @Test func worksWithOrderedPriority() {
        let resolver = LaneResolver<OrderedPriority> { priority in
            switch priority.level {
            case .high:   10
            case .medium:  5
            case .low:     1
            }
        }
        let highTask = OrderedPriority(level: .high, order: 1)
        let lowTask = OrderedPriority(level: .low, order: 1)

        #expect(resolver.shouldStart(executingCount: 9, priority: highTask))
        #expect(!resolver.shouldStart(executingCount: 1, priority: lowTask))
    }
}
