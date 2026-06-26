import Foundation

/// Thrown when an awaited operation outlasts its time budget. ``label`` names the
/// stage that stalled (e.g. `"transcribe(microphone)"`) so the UI can say what
/// timed out rather than spinning forever.
public struct TimeoutError: Error, Sendable, Equatable {
    public let label: String

    public init(label: String) {
        self.label = label
    }
}

/// Run `operation`, failing with ``TimeoutError`` if it outlasts `budget`.
///
/// A watchdog for the final pass: a wedged engine (we saw FluidAudio's Parakeet
/// deadlock on a cold first multi-window run under the App Sandbox) must surface
/// as a recoverable error, never an infinite spinner. The operation races a
/// sleeper; whichever finishes first wins and the other is cancelled.
///
/// Cancellation is best-effort — a non-cooperative operation (a CoreML inference
/// already in flight on the Neural Engine can't be interrupted mid-call) may keep
/// running detached after we throw, but the caller is freed regardless.
func withTimeout<T: Sendable>(
    _ budget: Duration,
    label: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: budget)
            throw TimeoutError(label: label)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw TimeoutError(label: label)
        }
        return result
    }
}
