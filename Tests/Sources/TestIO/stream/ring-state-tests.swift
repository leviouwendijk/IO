import IO

extension TestIO {
    static func testRingStateStorageIndependence() throws {
        var state = StreamRingState(capacity: 8)

        try expectEqual(state.capacity, 8, "ring state capacity")
        try expectEqual(state.readableCount, 0, "ring state initial readable")
        try expectEqual(state.writableCount, 8, "ring state initial writable")
        try expectEqual(
            state.readableRanges().first,
            0..<0,
            "ring state initial first readable range"
        )
        try expectEqual(
            state.writableRanges().first,
            0..<8,
            "ring state initial first writable range"
        )

        state.didWrite(6)

        try expectEqual(
            state.readableRanges().first,
            0..<6,
            "ring state first readable range"
        )
        try expectEqual(
            state.readableRanges().second,
            0..<0,
            "ring state second readable range"
        )

        state.consume(5)
        state.didWrite(6)

        let wrappedReadable = state.readableRanges()
        let wrappedWritable = state.writableRanges()

        try expectEqual(
            wrappedReadable.first,
            5..<8,
            "ring state wrapped first readable range"
        )
        try expectEqual(
            wrappedReadable.second,
            0..<4,
            "ring state wrapped second readable range"
        )
        try expectEqual(
            wrappedWritable.first,
            4..<5,
            "ring state wrapped writable range"
        )
        try expectEqual(
            wrappedWritable.second,
            0..<0,
            "ring state wrapped second writable range"
        )
        try expectEqual(
            state.readableCount,
            7,
            "ring state wrapped readable count"
        )
        try expectEqual(
            state.writableCount,
            1,
            "ring state wrapped writable count"
        )

        state.consume(7)

        try expectEqual(
            state.readableRanges().first,
            0..<0,
            "ring state reset readable range"
        )
        try expectEqual(
            state.writableRanges().first,
            0..<8,
            "ring state reset writable range"
        )
        try expectEqual(
            state.isEmpty,
            true,
            "ring state reset empty"
        )
    }
}
