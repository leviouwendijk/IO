import IO

extension TestIO {
    static func testBorrowedSourceEquivalence() throws {
        let ringCapacity =
            try capacity(
                8
            )
        let shortRefill =
            try PositiveByteCount(
                3
            )
        let payload =
            (0..<37).map {
                UInt8(
                    truncatingIfNeeded:
                        $0
                )
            }

        var owned =
            Source(
                MemorySource(
                    bytes:
                        payload,
                    maximumChunkSize:
                        shortRefill
                ),
                bufferCapacity:
                    ringCapacity
            )

        try withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity:
                ringCapacity.value
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
                MemorySource(
                    bytes:
                        payload,
                    maximumChunkSize:
                        shortRefill
                ),
                storage:
                    rawStorage
            ) {
                borrowed in

                try expectEqual(
                    try borrowed.prepare(),
                    try owned.prepare(),
                    "borrowed source initial prepare"
                )
                try expectSourceEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label:
                        "after initial prepare"
                )

                try owned.consume(
                    2
                )
                try borrowed.consume(
                    2
                )

                try expectEqual(
                    try borrowed.requestMore(),
                    try owned.requestMore(),
                    "borrowed source tail refill"
                )
                try expectSourceEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label:
                        "after tail refill"
                )

                try owned.consume(
                    3
                )
                try borrowed.consume(
                    3
                )

                try expectEqual(
                    try borrowed.requestMore(),
                    try owned.requestMore(),
                    "borrowed source wrapped refill"
                )
                try expectSourceEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label:
                        "after wrapped refill"
                )
                try expectEqual(
                    borrowed.splitRefillCount
                        > 0,
                    true,
                    "borrowed source split refill exercised"
                )

                var step =
                    0

                while !owned.isExhausted {
                    try expectSourceEquivalent(
                        owned: &owned,
                        borrowed: &borrowed,
                        label:
                            "drain step \(step)"
                    )

                    if owned.bufferedByteCount > 0 {
                        let amount =
                            min(
                                2,
                                owned.bufferedByteCount
                            )

                        try owned.consume(
                            amount
                        )
                        try borrowed.consume(
                            amount
                        )
                    }

                    if !owned.hasReachedEnd
                        && owned.bufferedByteCount
                            < ringCapacity.value
                    {
                        try expectEqual(
                            try borrowed.requestMore(),
                            try owned.requestMore(),
                            "borrowed source refill step \(step)"
                        )
                    }

                    step += 1
                    guard step < 256 else {
                        throw TestFailure(
                            message:
                                "borrowed source equivalence did not converge"
                        )
                    }
                }

                try expectSourceEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label:
                        "after exhaustion"
                )
                try expectEqual(
                    try borrowed.prepare(),
                    try owned.prepare(),
                    "borrowed source final end state"
                )
            }
        }
    }

    private static func expectSourceEquivalent(
        owned: inout Source,
        borrowed:
            inout BorrowedSource,
        label: String
    ) throws {
        try expectEqual(
            borrowed.bufferedByteCount,
            owned.bufferedByteCount,
            "\(label): buffered bytes"
        )
        try expectEqual(
            borrowed.hasReachedEnd,
            owned.hasReachedEnd,
            "\(label): reached end"
        )
        try expectEqual(
            borrowed.isExhausted,
            owned.isExhausted,
            "\(label): exhausted"
        )
        try expectEqual(
            borrowed.statistics,
            owned.statistics,
            "\(label): statistics"
        )
        try expectEqual(
            borrowed.splitRefillCount,
            owned.splitRefillCount,
            "\(label): split refill count"
        )
        try expectEqual(
            borrowed.bufferCompactionStatistics,
            owned.bufferCompactionStatistics,
            "\(label): compaction statistics"
        )
        try expectEqual(
            borrowedSourceBytes(
                borrowed
            ),
            bufferedBytes(
                owned
            ),
            "\(label): logical bytes"
        )
    }

    private static func borrowedSourceBytes(
        _ source:
            borrowing BorrowedSource
    ) -> [UInt8] {
        source.withReadableRegions {
            first,
            second in

            Array(first)
                + Array(second)
        }
    }
}
