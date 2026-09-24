import Foundation
import IO

extension TestIO {
    static func testMemoryToFileTransfer() throws {
        let url = temporaryURL(
            name: "transfer-memory-to-file"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        let payload = transferMatrixPayload(
            byteCount: 65_537
        )

        var source = Source(
            MemorySource(
                bytes: payload,
                maximumChunkSize:
                    try count(
                        997
                    )
            ),
            bufferCapacity:
                try capacity(
                    4_096
                )
        )

        var destination = Destination(
            try SystemFileDestination(
                path: url.path,
                mode: .truncate
            ),
            bufferCapacity:
                try capacity(
                    3_071
                )
        )

        try expectEqual(
            try source.stream(
                to: &destination
            ),
            .end(
                transferred:
                    UInt64(
                        payload.count
                    )
            ),
            "memory-to-file stream result"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "memory-to-file flush"
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf: url
                )
            ),
            payload,
            "memory-to-file payload"
        )
    }

    static func testFileToMemoryTransfer() throws {
        let url = temporaryURL(
            name: "transfer-file-to-memory"
        )
        defer {
            try? FileManager.default.removeItem(
                at: url
            )
        }

        let payload = transferMatrixPayload(
            byteCount: 73_123
        )
        try Data(
            payload
        ).write(
            to: url
        )

        var source = Source(
            try SystemFileSource(
                path: url.path
            ),
            bufferCapacity:
                try capacity(
                    4_093
                )
        )

        var destination = Destination(
            MemoryDestination(
                maximumChunkSize:
                    try count(
                        701
                    )
            ),
            bufferCapacity:
                try capacity(
                    2_503
                )
        )

        try expectEqual(
            try source.stream(
                to: &destination
            ),
            .end(
                transferred:
                    UInt64(
                        payload.count
                    )
            ),
            "file-to-memory stream result"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "file-to-memory flush"
        )

        try expectEqual(
            destination
                .inspectBackend()
                .capturedBytes,
            payload,
            "file-to-memory payload"
        )
    }

    static func testFileToFileTransfer() throws {
        let sourceURL = temporaryURL(
            name: "transfer-file-to-file-source"
        )
        let destinationURL = temporaryURL(
            name: "transfer-file-to-file-destination"
        )
        defer {
            try? FileManager.default.removeItem(
                at: sourceURL
            )
            try? FileManager.default.removeItem(
                at: destinationURL
            )
        }

        let payload = transferMatrixPayload(
            byteCount: 131_071
        )
        try Data(
            payload
        ).write(
            to: sourceURL
        )
        try Data(
            "stale-destination".utf8
        ).write(
            to: destinationURL
        )

        var source = Source(
            try SystemFileSource(
                path: sourceURL.path
            ),
            bufferCapacity:
                try capacity(
                    8_191
                )
        )

        var destination = Destination(
            try SystemFileDestination(
                path: destinationURL.path,
                mode: .truncate
            ),
            bufferCapacity:
                try capacity(
                    6_143
                )
        )

        try expectEqual(
            try source.stream(
                to: &destination
            ),
            .end(
                transferred:
                    UInt64(
                        payload.count
                    )
            ),
            "file-to-file stream result"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "file-to-file flush"
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf:
                        destinationURL
                )
            ),
            payload,
            "file-to-file payload"
        )
    }

    static func testBoundedFileToFileTransferResume() throws {
        let sourceURL = temporaryURL(
            name: "transfer-bounded-source"
        )
        let destinationURL = temporaryURL(
            name: "transfer-bounded-destination"
        )
        defer {
            try? FileManager.default.removeItem(
                at: sourceURL
            )
            try? FileManager.default.removeItem(
                at: destinationURL
            )
        }

        let payload = transferMatrixPayload(
            byteCount: 32_771
        )
        let firstCount: UInt64 =
            5_003

        try Data(
            payload
        ).write(
            to: sourceURL
        )

        var source = Source(
            try SystemFileSource(
                path: sourceURL.path
            ),
            bufferCapacity:
                try capacity(
                    4_097
                )
        )

        var destination = Destination(
            try SystemFileDestination(
                path: destinationURL.path,
                mode: .truncate
            ),
            bufferCapacity:
                try capacity(
                    3_001
                )
        )

        try expectEqual(
            try source.stream(
                to: &destination,
                maximumCount:
                    firstCount
            ),
            .limit(
                transferred:
                    firstCount
            ),
            "bounded file-to-file first result"
        )

        try expectEqual(
            try source.stream(
                to: &destination
            ),
            .end(
                transferred:
                    UInt64(
                        payload.count
                    ) - firstCount
            ),
            "bounded file-to-file resumed result"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "bounded file-to-file flush"
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf:
                        destinationURL
                )
            ),
            payload,
            "bounded file-to-file resumed payload"
        )
    }

    static func testFileTransferDoesNotImplicitlyFlush() throws {
        let sourceURL = temporaryURL(
            name: "transfer-no-implicit-flush-source"
        )
        let destinationURL = temporaryURL(
            name: "transfer-no-implicit-flush-destination"
        )
        defer {
            try? FileManager.default.removeItem(
                at: sourceURL
            )
            try? FileManager.default.removeItem(
                at: destinationURL
            )
        }

        let payload =
            Array(
                "ninebytes".utf8
            )

        try Data(
            payload
        ).write(
            to: sourceURL
        )

        var source = Source(
            try SystemFileSource(
                path: sourceURL.path
            ),
            bufferCapacity:
                try capacity(
                    4
                )
        )

        // Larger than the complete payload so Destination can retain every streamed
        // byte in its own staging ring without crossing into the file backend.
        var destination = Destination(
            try SystemFileDestination(
                path: destinationURL.path,
                mode: .truncate
            ),
            bufferCapacity:
                try capacity(
                    1_024
                )
        )

        try expectEqual(
            try source.stream(
                to: &destination
            ),
            .end(
                transferred:
                    UInt64(
                        payload.count
                    )
            ),
            "no-implicit-flush stream result"
        )

        try expectEqual(
            destination.bufferedByteCount,
            payload.count,
            "stream leaves destination bytes staged"
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf:
                        destinationURL
                )
            ),
            [],
            "stream does not implicitly flush file destination"
        )

        try expectEqual(
            try destination.flush(),
            .complete,
            "explicit transfer flush"
        )

        try expectEqual(
            Array(
                try Data(
                    contentsOf:
                        destinationURL
                )
            ),
            payload,
            "explicit flush exposes staged file bytes"
        )
    }

    static func transferMatrixPayload(
        byteCount: Int
    ) -> [UInt8] {
        (0..<byteCount).map {
            index in

            UInt8(
                truncatingIfNeeded:
                    index &* 31
                    &+ index / 7
            )
        }
    }
}
