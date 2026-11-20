import Dispatch
import IO
import Foundation

extension TestIO {
    static func runVectorIOBenchmarks(
        heavy: Bool
    ) throws {
        let logicalBytes = heavy
            ? 256 * 1024 * 1024
            : 64 * 1024 * 1024
        let capacity = try BufferCapacity(64 * 1024)
        let chunkSize = 4096
        let consumeSize = 3072
        let input = Array(repeating: UInt8(0x5A), count: chunkSize)

        print("ring/vector I/O experiment · in-memory buffer churn")
        print("  logical appended bytes: \(formatBytes(UInt64(logicalBytes)))")
        print("  capacity: 64 KiB · append 4 KiB · consume 3 KiB")
        print("  contiguous compaction uses overlap-safe memmove; ring avoids compaction entirely")
        print("")

        let contiguous = try timeVectorBufferChurn(
            logicalBytes: logicalBytes,
            input: input,
            capacity: capacity,
            consumeSize: consumeSize,
            useRing: false
        )
        let ring = try timeVectorBufferChurn(
            logicalBytes: logicalBytes,
            input: input,
            capacity: capacity,
            consumeSize: consumeSize,
            useRing: true
        )

        print("  contiguous+memmove \(formatMilliseconds(contiguous))")
        print("  ring       \(formatMilliseconds(ring))")
        print(String(format: "  ring/contiguous %.3fx", Double(ring) / Double(contiguous)))
        print("")
        print("  syscall semantics for readv/writev/sendmsg are covered by tio.")
        print("  integrate the ring into Source/Destination only if real streaming workloads also win.")
        print("")
    }
}

private extension TestIO {
    static func timeVectorBufferChurn(
        logicalBytes: Int,
        input: [UInt8],
        capacity: BufferCapacity,
        consumeSize: Int,
        useRing: Bool
    ) throws -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds

        if useRing {
            var buffer = StreamRingBuffer(capacity: capacity)
            var appended = 0

            while appended < logicalBytes {
                let accepted = input.withUnsafeBytes { buffer.append($0) }
                appended += accepted

                if accepted == 0 || buffer.writableCount < input.count {
                    buffer.consume(min(consumeSize, buffer.readableCount))
                }
            }
        } else {
            var buffer = StreamBuffer(capacity: capacity)
            var appended = 0

            while appended < logicalBytes {
                let accepted = input.withUnsafeBytes { buffer.append($0) }
                appended += accepted

                if accepted == 0 || buffer.writableCount < input.count {
                    buffer.consume(min(consumeSize, buffer.readableCount))
                }
            }
        }

        return DispatchTime.now().uptimeNanoseconds - start
    }

    static func formatMilliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f ms", Double(nanoseconds) / 1_000_000.0)
    }
}
