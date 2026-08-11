import Dispatch

public struct IOExecutor: Sendable {
    public let concurrency: IOConcurrency

    public init(
        concurrency: IOConcurrency = .automatic
    ) {
        self.concurrency = concurrency
    }

    public func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        operation: @escaping @Sendable (Input) throws -> Output
    ) async throws -> [Output] {
        guard !inputs.isEmpty else {
            return []
        }

        let limit = concurrency.limit(
            for: inputs.count
        )

        return try await withThrowingTaskGroup(
            of: IndexedIOResult<Output>.self
        ) { group in
            var nextIndex = 0
            var completed: [IndexedIOResult<Output>] = []

            completed.reserveCapacity(
                inputs.count
            )

            while nextIndex < limit {
                let index = nextIndex
                let input = inputs[index]

                nextIndex += 1

                group.addTask {
                    .init(
                        index: index,
                        value: try await Self.execute {
                            try operation(
                                input
                            )
                        }
                    )
                }
            }

            while let result = try await group.next() {
                completed.append(
                    result
                )

                if nextIndex < inputs.count {
                    let index = nextIndex
                    let input = inputs[index]

                    nextIndex += 1

                    group.addTask {
                        .init(
                            index: index,
                            value: try await Self.execute {
                                try operation(
                                    input
                                )
                            }
                        )
                    }
                }
            }

            completed.sort {
                $0.index < $1.index
            }

            return completed.map(\.value)
        }
    }
}

private extension IOExecutor {
    static func execute<Output: Sendable>(
        _ operation: @escaping @Sendable () throws -> Output
    ) async throws -> Output {
        try Task.checkCancellation()

        let result = try await withCheckedThrowingContinuation {
            (
                continuation: CheckedContinuation<Output, Error>
            ) in

            DispatchQueue.global(
                qos: .userInitiated
            ).async {
                do {
                    continuation.resume(
                        returning: try operation()
                    )
                } catch {
                    continuation.resume(
                        throwing: error
                    )
                }
            }
        }

        try Task.checkCancellation()

        return result
    }
}

private struct IndexedIOResult<Value: Sendable>: Sendable {
    let index: Int
    let value: Value
}
