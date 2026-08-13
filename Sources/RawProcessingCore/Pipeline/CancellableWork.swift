import Foundation

/// Runs blocking work off the calling actor **while still honouring cancellation**.
///
/// `Task.detached` deliberately inherits nothing from its parent — including
/// cancellation. Awaiting its `.value` doesn't help either: that only rethrows
/// the detached task's own error, so a cancelled caller simply waits for the
/// work to finish anyway.
///
/// That matters twice in this module:
///   - spec §6.3 requires an export to be cancellable,
///   - spec §11 requires memory not to grow when the user flicks through photos,
///     which only holds if superseded decodes actually stop.
///
/// Bridging through `withTaskCancellationHandler` keeps the work off the actor
/// and still forwards cancellation, so the `Task.checkCancellation()` calls
/// inside `body` do what they look like they do.
func runOffActor<T: Sendable>(
    priority: TaskPriority,
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority, operation: body)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
