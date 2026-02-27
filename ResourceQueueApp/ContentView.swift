//
//  ContentView.swift
//  ResourceQueueApp
//
//  Created by Andrew on 27.02.2026.
//

import SwiftUI
import ResourceQueue
import os

// MARK: - Task Item Model

enum TaskState: Equatable {
    case pending
    case executing
    case completed
    case cancelled
}

struct TaskItem: Identifiable {
    let id: UInt64
    let priority: Priority
    var state: TaskState
}

// MARK: - Shared Capacity Storage

/// Thread-safe storage for capacity values, accessible from any isolation domain.
final class CapacityStorage: Sendable {
    struct Values: Sendable {
        var low: Int
        var medium: Int
        var high: Int
    }

    private let lock: OSAllocatedUnfairLock<Values>

    init(low: Int, medium: Int, high: Int) {
        self.lock = OSAllocatedUnfairLock(initialState: Values(low: low, medium: medium, high: high))
    }

    func cumulativeCapacity(for priority: Priority) -> Int {
        lock.withLock { values in
            switch priority {
            case .low: values.low
            case .medium: values.low + values.medium
            case .high: values.low + values.medium + values.high
            }
        }
    }

    func update(low: Int, medium: Int, high: Int) {
        lock.withLock { values in
            values.low = low
            values.medium = medium
            values.high = high
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class QueueViewModel {

    var tasks: [TaskItem] = []

    var lowCapacity: Int = 1 {
        didSet { syncCapacity() }
    }
    var mediumCapacity: Int = 2 {
        didSet { syncCapacity() }
    }
    var highCapacity: Int = 3 {
        didSet { syncCapacity() }
    }

    var pendingTasks: [TaskItem] { tasks.filter { $0.state == .pending } }
    var executingTasks: [TaskItem] { tasks.filter { $0.state == .executing } }
    var completedTasks: [TaskItem] { tasks.filter { $0.state == .completed || $0.state == .cancelled } }

    private let capacityStorage: CapacityStorage
    private let queue: ResourceQueue<Priority, LaneResolver<Priority>>
    private var handles: [UInt64: TaskHandle<Void, Priority, LaneResolver<Priority>>] = [:]
    private var finishContinuations: [UInt64: CheckedContinuation<Void, any Error>] = [:]

    private var nextID: UInt64 = 0

    init() {
        let storage = CapacityStorage(low: 1, medium: 2, high: 3)
        self.capacityStorage = storage
        let resolver = LaneResolver<Priority> { priority in
            storage.cumulativeCapacity(for: priority)
        }
        self.queue = ResourceQueue(resolver: resolver)
    }

    private func syncCapacity() {
        capacityStorage.update(low: lowCapacity, medium: mediumCapacity, high: highCapacity)
        Task {
            await queue.drain()
        }
    }

    func addTask(priority: Priority) {
        let taskID = nextID
        nextID += 1

        let item = TaskItem(id: taskID, priority: priority, state: .pending)
        tasks.append(item)

        Task {
            do {
                let handle = try await queue.enqueue(priority: priority) { [weak self] in
                    await self?.markExecuting(id: taskID)
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        Task { @MainActor [weak self] in
                            self?.finishContinuations[taskID] = continuation
                        }
                    }
                }
                handles[taskID] = handle

                try await handle.value
                markCompleted(id: taskID)
            } catch is CancellationError {
                markCancelled(id: taskID)
            } catch {
                markCompleted(id: taskID)
            }
        }
    }

    func cancelTask(id: UInt64) {
        Task {
            await handles[id]?.cancel()
        }
        finishContinuations[id]?.resume(throwing: CancellationError())
        finishContinuations.removeValue(forKey: id)
    }

    func finishTask(id: UInt64) {
        finishContinuations[id]?.resume()
        finishContinuations.removeValue(forKey: id)
    }

    private func markExecuting(id: UInt64) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].state = .executing
        }
    }

    private func markCompleted(id: UInt64) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].state = .completed
        }
        cleanup(id: id)
    }

    private func markCancelled(id: UInt64) {
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].state = .cancelled
        }
        cleanup(id: id)
    }

    private func cleanup(id: UInt64) {
        handles.removeValue(forKey: id)
        finishContinuations.removeValue(forKey: id)
    }
}

// MARK: - Views

struct ContentView: View {
    @State private var viewModel = QueueViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controlPanel
                taskList
            }
            .navigationTitle("ResourceQueue")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Priority buttons
            HStack(spacing: 12) {
                Button { viewModel.addTask(priority: .low) } label: {
                    Label("Low", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)

                Button { viewModel.addTask(priority: .medium) } label: {
                    Label("Medium", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.yellow)
                .buttonStyle(.borderedProminent)

                Button { viewModel.addTask(priority: .high) } label: {
                    Label("High", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .tint(.green)
                .buttonStyle(.borderedProminent)
            }

            // Capacity controls
            HStack(spacing: 12) {
                capacityStepper(label: "Low", value: $viewModel.lowCapacity, color: .red)
                capacityStepper(label: "Med", value: $viewModel.mediumCapacity, color: .yellow)
                capacityStepper(label: "High", value: $viewModel.highCapacity, color: .green)
            }
        }
        .padding()
        .background(.bar)
    }

    private func capacityStepper(label: String, value: Binding<Int>, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value.wrappedValue)")
                .font(.title3.monospacedDigit().bold())
                .frame(minWidth: 20)
            Stepper(value: value, in: 0...5) {
                Text("\(value.wrappedValue)")
                    .font(.title3.monospacedDigit())
                    .frame(maxWidth: .infinity)
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity)
    }

    private var taskList: some View {
        List {
            if !viewModel.executingTasks.isEmpty {
                Section("Executing") {
                    ForEach(viewModel.executingTasks) { task in
                        taskRow(task)
                    }
                }
            }

            if !viewModel.pendingTasks.isEmpty {
                Section("Pending") {
                    ForEach(viewModel.pendingTasks) { task in
                        taskRow(task)
                    }
                }
            }

            if !viewModel.completedTasks.isEmpty {
                Section("Completed") {
                    ForEach(viewModel.completedTasks) { task in
                        taskRow(task)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: viewModel.tasks.map { "\($0.id)-\($0.state)" })
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack {
            Circle()
                .fill(task.priority.color)
                .frame(width: 12, height: 12)

            Text(task.priority.displayName)
                .font(.body)

            Text("#\(task.id)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            switch task.state {
            case .pending:
                Button("Cancel", role: .destructive) {
                    viewModel.cancelTask(id: task.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

            case .executing:
                HStack(spacing: 8) {
                    Button("Cancel", role: .destructive) {
                        viewModel.cancelTask(id: task.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Finish") {
                        viewModel.finishTask(id: task.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

            case .cancelled:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .low: .red
        case .medium: .yellow
        case .high: .green
        }
    }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

#Preview {
    ContentView()
}
