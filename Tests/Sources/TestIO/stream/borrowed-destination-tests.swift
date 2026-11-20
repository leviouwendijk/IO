import IO

extension TestIO {
    static func testBorrowedDestinationEquivalence() throws {
        let ringCapacity =
            try capacity(
                8
            )
        let shortDrain =
            try PositiveByteCount(
                3
            )

        var owned =
            Destination(
                MemoryDestination(
                    maximumChunkSize:
                        shortDrain
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

            try withBorrowedDestination(
                MemoryDestination(
                    maximumChunkSize:
                        shortDrain
                ),
                storage:
                    rawStorage
            ) {
                borrowed in

                let first =
                    [UInt8](
                        0..<8
                    )
                let second =
                    [UInt8](
                        8..<16
                    )
                let direct =
                    [UInt8](
                        16..<25
                    )

                try expectEqual(
                    try borrowed.write(
                        first
                    ),
                    try owned.write(
                        first
                    ),
                    "borrowed destination first staged write"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after first staged write"
                )

                try expectEqual(
                    try borrowed.write(
                        second
                    ),
                    try owned.write(
                        second
                    ),
                    "borrowed destination wrapped short-drain write"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after wrapped short-drain write"
                )

                try expectEqual(
                    try borrowed.flush(),
                    try owned.flush(),
                    "borrowed destination first flush"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after first flush"
                )

                try expectEqual(
                    try borrowed.write(
                        direct
                    ),
                    try owned.write(
                        direct
                    ),
                    "borrowed destination direct-bypass write"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after direct-bypass write"
                )

                try expectEqual(
                    try borrowed.write(
                        UInt8(99)
                    ),
                    try owned.write(
                        UInt8(99)
                    ),
                    "borrowed destination byte write"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after byte write"
                )

                try expectEqual(
                    try borrowed.flush(),
                    try owned.flush(),
                    "borrowed destination final flush"
                )
                try expectDestinationEquivalent(
                    owned: &owned,
                    borrowed: &borrowed,
                    label: "after final flush"
                )

                let ownedInspection =
                    owned.inspectBackend()
                let borrowedInspection =
                    borrowed.inspectBackend()

                try expectEqual(
                    borrowedInspection
                        .capturedBytes,
                    ownedInspection
                        .capturedBytes,
                    "borrowed destination captured bytes"
                )
                try expectEqual(
                    borrowedInspection
                        .capturedBytes,
                    first
                        + second
                        + direct
                        + [99],
                    "borrowed destination expected byte sequence"
                )
                try expectEqual(
                    borrowed.directDrainCount
                        > 0,
                    true,
                    "borrowed destination direct bypass exercised"
                )
                try expectEqual(
                    borrowed.splitDrainCount
                        > 0,
                    true,
                    "borrowed destination split drain exercised"
                )
            }
        }
    }

    private static func expectDestinationEquivalent(
        owned: inout Destination,
        borrowed:
            inout BorrowedDestination,
        label: String
    ) throws {
        try expectEqual(
            borrowed.bufferedByteCount,
            owned.bufferedByteCount,
            "\(label): buffered bytes"
        )
        try expectEqual(
            borrowed.statistics,
            owned.statistics,
            "\(label): statistics"
        )
        try expectEqual(
            borrowed.splitDrainCount,
            owned.splitDrainCount,
            "\(label): split drain count"
        )
        try expectEqual(
            borrowed.directDrainCount,
            owned.directDrainCount,
            "\(label): direct drain count"
        )

        let ownedInspection =
            owned.inspectBackend()
        let borrowedInspection =
            borrowed.inspectBackend()

        try expectEqual(
            borrowedInspection
                .capturedBytes,
            ownedInspection
                .capturedBytes,
            "\(label): backend bytes"
        )
    }
}
