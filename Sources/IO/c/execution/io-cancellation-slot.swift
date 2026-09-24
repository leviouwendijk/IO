import Foundation

/// Bridges Swift task cancellation to a runtime operation token without making
/// blocking runtimes pretend they can interrupt an already-entered syscall.
///
/// Cancellation can race operation registration. The slot records either order
/// and invokes `IORuntime.cancel` once an operation token exists.
final class IOCancellationSlot:
    @unchecked Sendable
{
    private let lock =
        NSLock()
    private var operation:
        IOOperation?
    private var isCancelled =
        false

    func install(
        _ operation: IOOperation?,
        runtime: any IORuntime
    ) {
        guard let operation else {
            return
        }

        lock.lock()

        if isCancelled {
            lock.unlock()
            runtime.cancel(
                operation
            )
            return
        }

        self.operation =
            operation
        lock.unlock()
    }

    func cancel(
        runtime: any IORuntime
    ) {
        lock.lock()
        isCancelled = true
        let operation =
            self.operation
        self.operation =
            nil
        lock.unlock()

        if let operation {
            runtime.cancel(
                operation
            )
        }
    }
}
