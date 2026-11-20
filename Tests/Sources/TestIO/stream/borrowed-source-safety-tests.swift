import IO

extension TestIO {
    static func testBorrowedSourceGuardBytes() throws {
        let leftGuard: UInt8 =
            0xA5
        let rightGuard: UInt8 =
            0x5A
        let ringCapacity =
            8
        let payload =
            (0..<200).map {
                UInt8(
                    truncatingIfNeeded:
                        $0
                )
            }
        let shortRefill =
            try PositiveByteCount(
                3
            )

        try withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity:
                ringCapacity + 2
        ) {
            temporaryStorage in

            temporaryStorage.initialize(
                repeating: 0
            )
            temporaryStorage[0] =
                leftGuard
            temporaryStorage[
                ringCapacity + 1
            ] =
                rightGuard

            let rawStorage =
                UnsafeMutableRawBufferPointer(
                    start:
                        temporaryStorage
                            .baseAddress?
                            .advanced(
                                by: 1
                            ),
                    count:
                        ringCapacity
                )

            try withBorrowedSource(
                MemorySource(
                    bytes:
                        payload,
                    maximumChunkSize:
                        shortRefill
                ),
                storage:
                    rawStorage
            ) {
                source in

                var consumedOffset =
                    0
                var round =
                    0

                while true {
                    if !source.hasReachedEnd
                        && source.bufferedByteCount
                            < ringCapacity
                    {
                        let availability =
                            try source.requestMore()

                        switch availability {
                        case .bytes,
                             .end:
                            break

                        case .unavailable,
                             .buffer_full:
                            throw TestFailure(
                                message:
                                    "borrowed source guarded fixture unexpectedly stalled"
                            )
                        }

                        try expectBorrowedSourceGuards(
                            temporaryStorage,
                            ringCapacity:
                                ringCapacity,
                            leftGuard:
                                leftGuard,
                            rightGuard:
                                rightGuard,
                            label:
                                "after guarded refill \(round)"
                        )
                    }

                    let buffered =
                        source.withReadableRegions {
                            first,
                            second in

                            Array(first)
                                + Array(second)
                        }

                    let upperBound =
                        consumedOffset
                            + buffered.count

                    try expectEqual(
                        buffered,
                        Array(
                            payload[
                                consumedOffset
                                    ..< upperBound
                            ]
                        ),
                        "borrowed source guarded logical bytes"
                    )

                    if buffered.isEmpty {
                        if source.hasReachedEnd {
                            break
                        }
                    } else {
                        let amount =
                            min(
                                (round % 5) + 1,
                                buffered.count
                            )

                        try source.consume(
                            amount
                        )
                        consumedOffset +=
                            amount

                        try expectBorrowedSourceGuards(
                            temporaryStorage,
                            ringCapacity:
                                ringCapacity,
                            leftGuard:
                                leftGuard,
                            rightGuard:
                                rightGuard,
                            label:
                                "after guarded consume \(round)"
                        )
                    }

                    round += 1
                    guard round < 2_000 else {
                        throw TestFailure(
                            message:
                                "borrowed source guarded fixture did not converge"
                        )
                    }
                }

                try expectEqual(
                    consumedOffset,
                    payload.count,
                    "borrowed source guarded payload consumed"
                )
                try expectEqual(
                    source.isExhausted,
                    true,
                    "borrowed source guarded exhaustion"
                )
            }

            try expectBorrowedSourceGuards(
                temporaryStorage,
                ringCapacity:
                    ringCapacity,
                leftGuard:
                    leftGuard,
                rightGuard:
                    rightGuard,
                label:
                    "after borrowed source destruction"
            )
        }
    }

    static func testBorrowedSourceBackendLifecycle() throws {
        let iterationCount =
            2_000
        let counter =
            BorrowedSourceDestructionCounter()

        for value in 0..<iterationCount {
            try withUnsafeTemporaryAllocation(
                of: UInt8.self,
                capacity: 8
            ) {
                temporaryStorage in

                temporaryStorage.initialize(
                    repeating: 0
                )

                let rawStorage =
                    UnsafeMutableRawBufferPointer(
                        start:
                            temporaryStorage.baseAddress,
                        count:
                            temporaryStorage.count
                    )

                try withBorrowedSource(
                    BorrowedSourceLifetimeBackend(
                        byte:
                            UInt8(
                                truncatingIfNeeded:
                                    value
                            ),
                        counter:
                            counter
                    ),
                    storage:
                        rawStorage
                ) {
                    source in

                    try expectEqual(
                        try source.prepare(),
                        .bytes,
                        "borrowed source lifecycle prepare"
                    )
                    try source.consume(
                        1
                    )
                    try expectEqual(
                        try source.prepare(),
                        .end,
                        "borrowed source lifecycle end"
                    )
                }
            }
        }

        try expectEqual(
            counter.destructionCount,
            iterationCount,
            "borrowed source destroys each uniquely owned backend exactly once"
        )
    }

    private static func expectBorrowedSourceGuards(
        _ storage:
            UnsafeMutableBufferPointer<UInt8>,
        ringCapacity: Int,
        leftGuard: UInt8,
        rightGuard: UInt8,
        label: String
    ) throws {
        try expectEqual(
            storage[0],
            leftGuard,
            "\(label): left guard"
        )
        try expectEqual(
            storage[
                ringCapacity + 1
            ],
            rightGuard,
            "\(label): right guard"
        )
    }
}

private final class BorrowedSourceDestructionCounter {
    var destructionCount:
        Int = 0
}

private struct BorrowedSourceLifetimeBackend:
    SourceBackend,
    ~Copyable
{
    private let byte:
        UInt8
    private let counter:
        BorrowedSourceDestructionCounter
    private var emitted:
        Bool

    init(
        byte: UInt8,
        counter:
            BorrowedSourceDestructionCounter
    ) {
        self.byte =
            byte
        self.counter =
            counter
        self.emitted =
            false
    }

    deinit {
        counter.destructionCount +=
            1
    }

    mutating func refill(
        into bytes:
            UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        guard !emitted else {
            return .end
        }

        guard !bytes.isEmpty else {
            return .unavailable
        }

        bytes[0] =
            byte
        emitted =
            true

        return .final_bytes(
            .knownPositive(
                1
            )
        )
    }
}
