import IO

extension TestIO {
    static func testBorrowedRingStorageEquivalence() throws {
        let ringCapacity =
            try capacity(
                8
            )
        var externalStorage =
            [UInt8](
                repeating: 0,
                count: ringCapacity.value
            )

        try withBorrowedStreamRingBuffer(
            storage: &externalStorage
        ) {
            borrowed in

            var owned =
                StreamRingBuffer(
                    capacity: ringCapacity
                )

            try exerciseBorrowedRingEquivalence(
                owned: &owned,
                borrowed: &borrowed
            )
        }
    }

    static func testBorrowedTemporaryRingStorageEquivalence() throws {
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

            try withBorrowedStreamRingBuffer(
                storage: rawStorage
            ) {
                borrowed in

                var owned =
                    StreamRingBuffer(
                        capacity:
                            try capacity(
                                8
                            )
                    )

                try exerciseBorrowedRingEquivalence(
                    owned: &owned,
                    borrowed: &borrowed
                )
            }
        }
    }

    private static func exerciseBorrowedRingEquivalence(
        owned: inout StreamRingBuffer,
        borrowed: inout BorrowedStreamRingBuffer
    ) throws {
        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "initial"
        )

        let first =
            [UInt8](
                0..<6
            )

        let ownedAccepted =
            first.withUnsafeBytes {
                owned.append(
                    $0
                )
            }
        let borrowedAccepted =
            first.withUnsafeBytes {
                borrowed.append(
                    $0
                )
            }

        try expectEqual(
            borrowedAccepted,
            ownedAccepted,
            "borrowed ring first append count"
        )
        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after first append"
        )

        owned.consume(
            5
        )
        borrowed.consume(
            5
        )

        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after consume"
        )

        let second:
            [UInt8] =
            [
                10,
                11,
                12,
                13,
                14,
                15,
            ]

        let ownedWrappedAccepted =
            second.withUnsafeBytes {
                owned.append(
                    $0
                )
            }
        let borrowedWrappedAccepted =
            second.withUnsafeBytes {
                borrowed.append(
                    $0
                )
            }

        try expectEqual(
            borrowedWrappedAccepted,
            ownedWrappedAccepted,
            "borrowed ring wrapped append count"
        )
        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after wrapped append"
        )

        let ownedDirectWritten =
            owned.withWritableRegions {
                first,
                second -> Int in

                guard let pointer =
                        first.baseAddress
                        ?? second.baseAddress
                else {
                    return 0
                }

                pointer.storeBytes(
                    of: UInt8(99),
                    as: UInt8.self
                )
                return 1
            }
        let borrowedDirectWritten =
            borrowed.withWritableRegions {
                first,
                second -> Int in

                guard let pointer =
                        first.baseAddress
                        ?? second.baseAddress
                else {
                    return 0
                }

                pointer.storeBytes(
                    of: UInt8(99),
                    as: UInt8.self
                )
                return 1
            }

        try expectEqual(
            borrowedDirectWritten,
            ownedDirectWritten,
            "borrowed ring direct region write count"
        )

        owned.didWrite(
            ownedDirectWritten
        )
        borrowed.didWrite(
            borrowedDirectWritten
        )

        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after direct writable-region commit"
        )
        try expectEqual(
            owned.isFull,
            true,
            "owned ring full after direct write"
        )
        try expectEqual(
            borrowed.isFull,
            true,
            "borrowed ring full after direct write"
        )

        let ownedFullAppend =
            owned.append(
                42
            )
        let borrowedFullAppend =
            borrowed.append(
                42
            )

        try expectEqual(
            borrowedFullAppend,
            ownedFullAppend,
            "borrowed ring full append result"
        )

        owned.consume(
            4
        )
        borrowed.consume(
            4
        )

        let ownedByteAppend =
            owned.append(
                42
            )
        let borrowedByteAppend =
            borrowed.append(
                42
            )

        try expectEqual(
            borrowedByteAppend,
            ownedByteAppend,
            "borrowed ring byte append result"
        )
        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after byte append"
        )

        let remaining =
            owned.readableCount

        owned.consume(
            remaining
        )
        borrowed.consume(
            remaining
        )

        try expectBorrowedRingEquivalent(
            owned: &owned,
            borrowed: &borrowed,
            label: "after drain to empty"
        )
        try expectEqual(
            borrowed.isEmpty,
            true,
            "borrowed ring empty after drain"
        )
    }

    private static func expectBorrowedRingEquivalent(
        owned: inout StreamRingBuffer,
        borrowed: inout BorrowedStreamRingBuffer,
        label: String
    ) throws {
        try expectEqual(
            borrowed.capacity,
            owned.capacity,
            "\(label): capacity"
        )
        try expectEqual(
            borrowed.readableCount,
            owned.readableCount,
            "\(label): readable count"
        )
        try expectEqual(
            borrowed.writableCount,
            owned.writableCount,
            "\(label): writable count"
        )
        try expectEqual(
            borrowed.isEmpty,
            owned.isEmpty,
            "\(label): empty state"
        )
        try expectEqual(
            borrowed.isFull,
            owned.isFull,
            "\(label): full state"
        )

        let ownedLogical =
            owned.withReadableRegions {
                first,
                second in

                Array(
                    first
                )
                    + Array(
                        second
                    )
            }
        let borrowedLogical =
            borrowed.withReadableRegions {
                first,
                second in

                Array(
                    first
                )
                    + Array(
                        second
                    )
            }

        try expectEqual(
            borrowedLogical,
            ownedLogical,
            "\(label): logical readable bytes"
        )

        let ownedReadableShape =
            owned.withReadableRegions {
                first,
                second in

                [
                    first.count,
                    second.count,
                ]
            }
        let borrowedReadableShape =
            borrowed.withReadableRegions {
                first,
                second in

                [
                    first.count,
                    second.count,
                ]
            }

        try expectEqual(
            borrowedReadableShape,
            ownedReadableShape,
            "\(label): readable region shape"
        )

        let ownedWritableShape =
            owned.withWritableRegions {
                first,
                second in

                [
                    first.count,
                    second.count,
                ]
            }
        let borrowedWritableShape =
            borrowed.withWritableRegions {
                first,
                second in

                [
                    first.count,
                    second.count,
                ]
            }

        try expectEqual(
            borrowedWritableShape,
            ownedWritableShape,
            "\(label): writable region shape"
        )
    }
}
