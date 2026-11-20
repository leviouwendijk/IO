import IO

extension TestIO {
    static func testBorrowedDestinationGuardBytes() throws {
        let leftGuard: UInt8 =
            0xA5
        let rightGuard: UInt8 =
            0x5A
        let ringCapacity =
            8
        let shortDrain =
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

            var expected: [UInt8] =
                []

            try withBorrowedDestination(
                MemoryDestination(
                    maximumChunkSize:
                        shortDrain
                ),
                storage:
                    rawStorage
            ) {
                destination in

                for round in 0..<256 {
                    let count =
                        (round % 7) + 1
                    let chunk =
                        (0..<count).map {
                            index in

                            UInt8(
                                truncatingIfNeeded:
                                    round * 17
                                    + index
                            )
                        }

                    expected +=
                        chunk

                    try expectEqual(
                        try destination.write(
                            chunk
                        ),
                        .complete,
                        "borrowed destination guarded write"
                    )
                    try expectBorrowedDestinationGuards(
                        temporaryStorage,
                        ringCapacity:
                            ringCapacity,
                        leftGuard:
                            leftGuard,
                        rightGuard:
                            rightGuard,
                        label:
                            "after guarded write \(round)"
                    )

                    if round % 5 == 0 {
                        try expectEqual(
                            try destination.flush(),
                            .complete,
                            "borrowed destination guarded flush"
                        )
                        try expectBorrowedDestinationGuards(
                            temporaryStorage,
                            ringCapacity:
                                ringCapacity,
                            leftGuard:
                                leftGuard,
                            rightGuard:
                                rightGuard,
                            label:
                                "after guarded flush \(round)"
                        )
                    }
                }

                try expectEqual(
                    try destination.flush(),
                    .complete,
                    "borrowed destination guarded pre-bypass flush"
                )

                let direct =
                    [UInt8](
                        repeating: 0xCC,
                        count:
                            ringCapacity + 1
                    )
                expected +=
                    direct

                try expectEqual(
                    try destination.write(
                        direct
                    ),
                    .complete,
                    "borrowed destination guarded direct bypass"
                )
                try expectBorrowedDestinationGuards(
                    temporaryStorage,
                    ringCapacity:
                        ringCapacity,
                    leftGuard:
                        leftGuard,
                    rightGuard:
                        rightGuard,
                    label:
                        "after guarded direct bypass"
                )

                try expectEqual(
                    try destination.flush(),
                    .complete,
                    "borrowed destination guarded final flush"
                )
                try expectBorrowedDestinationGuards(
                    temporaryStorage,
                    ringCapacity:
                        ringCapacity,
                    leftGuard:
                        leftGuard,
                    rightGuard:
                        rightGuard,
                    label:
                        "after guarded final flush"
                )

                try expectEqual(
                    destination
                        .inspectBackend()
                        .capturedBytes,
                    expected,
                    "borrowed destination guarded byte sequence"
                )
            }

            try expectBorrowedDestinationGuards(
                temporaryStorage,
                ringCapacity:
                    ringCapacity,
                leftGuard:
                    leftGuard,
                rightGuard:
                    rightGuard,
                label:
                    "after borrowed destination destruction"
            )
        }
    }

    static func testBorrowedDestinationBackendLifecycle() throws {
        let iterationCount =
            2_000
        let counter =
            BorrowedDestinationDestructionCounter()

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

                try withBorrowedDestination(
                    BorrowedDestinationLifetimeBackend(
                        counter:
                            counter
                    ),
                    storage:
                        rawStorage
                ) {
                    destination in

                    try expectEqual(
                        try destination.write(
                            UInt8(
                                truncatingIfNeeded:
                                    value
                            )
                        ),
                        .complete,
                        "borrowed destination lifecycle write"
                    )
                    try expectEqual(
                        try destination.flush(),
                        .complete,
                        "borrowed destination lifecycle flush"
                    )
                }
            }
        }

        try expectEqual(
            counter.destructionCount,
            iterationCount,
            "borrowed destination destroys each uniquely owned backend exactly once"
        )
    }

    private static func expectBorrowedDestinationGuards(
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

private final class BorrowedDestinationDestructionCounter {
    var destructionCount:
        Int = 0
}

private struct BorrowedDestinationLifetimeBackend:
    DestinationBackend,
    ~Copyable
{
    private let counter:
        BorrowedDestinationDestructionCounter

    init(
        counter:
            BorrowedDestinationDestructionCounter
    ) {
        self.counter =
            counter
    }

    deinit {
        counter.destructionCount +=
            1
    }

    mutating func drain(
        _ bytes:
            UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        guard !bytes.isEmpty else {
            return .unavailable
        }

        return .bytes(
            .knownPositive(
                bytes.count
            )
        )
    }
}
