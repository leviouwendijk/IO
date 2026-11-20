import Dispatch
import Foundation
import IO

private enum DispatchVTableError: Error {
    case source_backend
    case destination_backend
}

private struct DispatchVTableSourceTable {
    typealias Refill = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        Int
    ) -> Int64
    typealias Destroy = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void

    let refill: Refill
    let destroy: Destroy
}

private struct DispatchVTableDestinationTable {
    typealias Drain = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeRawPointer?,
        Int
    ) -> Int64
    typealias Flush = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Int32
    typealias Destroy = @convention(c) (
        UnsafeMutableRawPointer?
    ) -> Void

    let drain: Drain
    let flush: Flush
    let destroy: Destroy
}

private func dispatchVTableSourceRefill(
    _ rawContext: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeMutableRawPointer?,
    _ count: Int
) -> Int64 {
    guard let rawContext else {
        return Int64.min
    }

    let context =
        rawContext.assumingMemoryBound(
            to: DeterministicStreamSourceBackend.self
        )

    do {
        let result =
            try context.pointee.refill(
                into: UnsafeMutableRawBufferPointer(
                    start: baseAddress,
                    count: count
                )
            )

        switch result {
        case .bytes(let progress):
            return Int64(progress.value)

        case .final_bytes(let progress):
            return -Int64(progress.value) - 2

        case .end:
            return 0

        case .unavailable:
            return -1

        case .retry:
            return -2
        }
    } catch {
        return Int64.min
    }
}

private func dispatchVTableSourceDestroy(
    _ rawContext: UnsafeMutableRawPointer?
) {
    guard let rawContext else {
        return
    }

    let context =
        rawContext.assumingMemoryBound(
            to: DeterministicStreamSourceBackend.self
        )
    context.deinitialize(count: 1)
    context.deallocate()
}

private func dispatchVTableDestinationDrain(
    _ rawContext: UnsafeMutableRawPointer?,
    _ baseAddress: UnsafeRawPointer?,
    _ count: Int
) -> Int64 {
    guard let rawContext else {
        return Int64.min
    }

    let context =
        rawContext.assumingMemoryBound(
            to: DeterministicStreamDestinationBackend.self
        )

    do {
        let result =
            try context.pointee.drain(
                UnsafeRawBufferPointer(
                    start: baseAddress,
                    count: count
                )
            )

        switch result {
        case .bytes(let progress):
            return Int64(progress.value)

        case .unavailable:
            return 0
        }
    } catch {
        return Int64.min
    }
}

private func dispatchVTableDestinationFlush(
    _ rawContext: UnsafeMutableRawPointer?
) -> Int32 {
    guard let rawContext else {
        return -1
    }

    let context =
        rawContext.assumingMemoryBound(
            to: DeterministicStreamDestinationBackend.self
        )

    do {
        switch try context.pointee.flush() {
        case .complete:
            return 0
        case .unavailable:
            return 1
        }
    } catch {
        return -1
    }
}

private func dispatchVTableDestinationDestroy(
    _ rawContext: UnsafeMutableRawPointer?
) {
    guard let rawContext else {
        return
    }

    let context =
        rawContext.assumingMemoryBound(
            to: DeterministicStreamDestinationBackend.self
        )
    context.deinitialize(count: 1)
    context.deallocate()
}

private let dispatchVTableSourceTable =
    DispatchVTableSourceTable(
        refill: dispatchVTableSourceRefill,
        destroy: dispatchVTableSourceDestroy
    )

private let dispatchVTableDestinationTable =
    DispatchVTableDestinationTable(
        drain: dispatchVTableDestinationDrain,
        flush: dispatchVTableDestinationFlush,
        destroy: dispatchVTableDestinationDestroy
    )

private struct DispatchVTableSourceBackend:
    SourceBackend,
    ~Copyable
{
    private let context: UnsafeMutableRawPointer
    private let table: DispatchVTableSourceTable

    init(
        _ backend: consuming DeterministicStreamSourceBackend
    ) {
        let pointer =
            UnsafeMutablePointer<DeterministicStreamSourceBackend>
                .allocate(capacity: 1)
        pointer.initialize(to: consume backend)

        self.context = UnsafeMutableRawPointer(pointer)
        self.table = dispatchVTableSourceTable
    }

    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        let encoded =
            table.refill(
                context,
                bytes.baseAddress,
                bytes.count
            )

        if encoded == Int64.min {
            throw DispatchVTableError.source_backend
        }

        if encoded > 0 {
            return .bytes(
                try PositiveByteCount(
                    Int(encoded)
                )
            )
        }

        switch encoded {
        case 0:
            return .end
        case -1:
            return .unavailable
        case -2:
            return .retry
        default:
            return .final_bytes(
                try PositiveByteCount(
                    Int(-encoded - 2)
                )
            )
        }
    }

    deinit {
        table.destroy(context)
    }
}

private struct DispatchVTableDestinationBackend:
    DestinationBackend,
    ~Copyable
{
    private let context: UnsafeMutableRawPointer
    private let table: DispatchVTableDestinationTable

    init(
        _ backend: consuming DeterministicStreamDestinationBackend
    ) {
        let pointer =
            UnsafeMutablePointer<DeterministicStreamDestinationBackend>
                .allocate(capacity: 1)
        pointer.initialize(to: consume backend)

        self.context = UnsafeMutableRawPointer(pointer)
        self.table = dispatchVTableDestinationTable
    }

    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        let encoded =
            table.drain(
                context,
                bytes.baseAddress,
                bytes.count
            )

        if encoded == Int64.min {
            throw DispatchVTableError.destination_backend
        }

        guard encoded > 0 else {
            return .unavailable
        }

        return .bytes(
            try PositiveByteCount(
                Int(encoded)
            )
        )
    }

    mutating func flush() throws -> DestinationFlush {
        switch table.flush(context) {
        case 0:
            return .complete
        case 1:
            return .unavailable
        default:
            throw DispatchVTableError.destination_backend
        }
    }

    mutating func inspect() -> DestinationBackendInspection {
        .init()
    }

    deinit {
        table.destroy(context)
    }
}

private protocol DispatchVTableSourceBoundary: ~Copyable {
    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill
}

private struct DispatchVTableExistentialSourceBoundary:
    DispatchVTableSourceBoundary,
    ~Copyable
{
    private var backend: any SourceBackend & ~Copyable

    init<Backend: SourceBackend & ~Copyable>(
        _ backend: consuming Backend
    ) {
        self.backend = consume backend
    }

    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        try backend.refill(into: bytes)
    }
}

private struct DispatchVTableGenericSourceBoundary<
    Backend: SourceBackend & ~Copyable
>:
    DispatchVTableSourceBoundary,
    ~Copyable
{
    private var backend: Backend

    init(
        _ backend: consuming Backend
    ) {
        self.backend = consume backend
    }

    mutating func refill(
        into bytes: UnsafeMutableRawBufferPointer
    ) throws -> SourceRefill {
        try backend.refill(into: bytes)
    }
}

private protocol DispatchVTableDestinationBoundary: ~Copyable {
    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain

    mutating func flush() throws -> DestinationFlush
}

private struct DispatchVTableExistentialDestinationBoundary:
    DispatchVTableDestinationBoundary,
    ~Copyable
{
    private var backend: any DestinationBackend & ~Copyable

    init<Backend: DestinationBackend & ~Copyable>(
        _ backend: consuming Backend
    ) {
        self.backend = consume backend
    }

    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        try backend.drain(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try backend.flush()
    }
}

private struct DispatchVTableGenericDestinationBoundary<
    Backend: DestinationBackend & ~Copyable
>:
    DispatchVTableDestinationBoundary,
    ~Copyable
{
    private var backend: Backend

    init(
        _ backend: consuming Backend
    ) {
        self.backend = consume backend
    }

    mutating func drain(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationDrain {
        try backend.drain(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try backend.flush()
    }
}

private protocol DispatchVTableBufferedSourceDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var compactedByteCount: UInt64 { get }
    var refillCallCount: UInt64 { get }
    var refilledByteCount: UInt64 { get }

    mutating func requestMore() throws -> SourceAvailability
    mutating func consume(_ count: Int) throws
}

private struct DispatchVTableExistentialBufferedSource:
    DispatchVTableBufferedSourceDriver,
    ~Copyable
{
    private var source: ErasedContiguousSource

    init(
        _ backend: consuming DeterministicStreamSourceBackend,
        capacity: BufferCapacity
    ) {
        source =
            ErasedContiguousSource(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        source.bufferedByteCount
    }

    var compactedByteCount: UInt64 {
        source.bufferCompactionStatistics.movedByteCount
    }

    var refillCallCount: UInt64 {
        source.refillCalls
    }

    var refilledByteCount: UInt64 {
        source.refilledBytes
    }

    mutating func requestMore() throws -> SourceAvailability {
        try source.requestMore()
    }

    mutating func consume(_ count: Int) throws {
        try source.consume(count)
    }
}

private struct DispatchVTableGenericBufferedSource<
    Backend: SourceBackend & ~Copyable
>:
    DispatchVTableBufferedSourceDriver,
    ~Copyable
{
    private var source: GenericContiguousSource<Backend>

    init(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        source =
            GenericContiguousSource(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        source.bufferedByteCount
    }

    var compactedByteCount: UInt64 {
        source.bufferCompactionStatistics.movedByteCount
    }

    var refillCallCount: UInt64 {
        source.refillCalls
    }

    var refilledByteCount: UInt64 {
        source.refilledBytes
    }

    mutating func requestMore() throws -> SourceAvailability {
        try source.requestMore()
    }

    mutating func consume(_ count: Int) throws {
        try source.consume(count)
    }
}

private protocol DispatchVTableBufferedDestinationDriver: ~Copyable {
    var bufferedByteCount: Int { get }
    var compactedByteCount: UInt64 { get }
    var drainCallCount: UInt64 { get }
    var drainedByteCount: UInt64 { get }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite

    mutating func flush() throws -> DestinationFlush
}

private struct DispatchVTableExistentialBufferedDestination:
    DispatchVTableBufferedDestinationDriver,
    ~Copyable
{
    private var destination: ErasedContiguousDestination

    init(
        _ backend: consuming DeterministicStreamDestinationBackend,
        capacity: BufferCapacity
    ) {
        destination =
            ErasedContiguousDestination(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        destination.bufferedByteCount
    }

    var compactedByteCount: UInt64 {
        destination.bufferCompactionStatistics.movedByteCount
    }

    var drainCallCount: UInt64 {
        destination.drainCalls
    }

    var drainedByteCount: UInt64 {
        destination.drainedBytes
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        try destination.write(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try destination.flush()
    }
}

private struct DispatchVTableGenericBufferedDestination<
    Backend: DestinationBackend & ~Copyable
>:
    DispatchVTableBufferedDestinationDriver,
    ~Copyable
{
    private var destination: GenericContiguousDestination<Backend>

    init(
        _ backend: consuming Backend,
        capacity: BufferCapacity
    ) {
        destination =
            GenericContiguousDestination(
                consume backend,
                bufferCapacity: capacity
            )
    }

    var bufferedByteCount: Int {
        destination.bufferedByteCount
    }

    var compactedByteCount: UInt64 {
        destination.bufferCompactionStatistics.movedByteCount
    }

    var drainCallCount: UInt64 {
        destination.drainCalls
    }

    var drainedByteCount: UInt64 {
        destination.drainedBytes
    }

    mutating func write(
        _ bytes: UnsafeRawBufferPointer
    ) throws -> DestinationWrite {
        try destination.write(bytes)
    }

    mutating func flush() throws -> DestinationFlush {
        try destination.flush()
    }
}

private enum DispatchVTableLane:
    String,
    CaseIterable
{
    case existential
    case generic
    case explicit_vtable
}

private struct DispatchVTableSample {
    let seconds: Double
    let progress: UInt64
    let callCount: UInt64
    let unavailableCount: UInt64
    let compactedByteCount: UInt64
}

private struct DispatchVTableScheduleCase {
    let name: String
    let schedule: DeterministicStreamSchedule
}

extension TestIO {
    static func testDispatchVTableAdapters() throws {
        let schedule =
            DeterministicStreamSchedule(
                maximumRefillBytes: 4,
                maximumDrainBytes: 3,
                sourceUnavailableEvery: 7,
                destinationUnavailableEvery: 5
            )

        var directSource =
            DeterministicStreamSourceBackend(
                byteCount: 64,
                schedule: schedule
            )
        var explicitSource =
            DispatchVTableSourceBackend(
                DeterministicStreamSourceBackend(
                    byteCount: 64,
                    schedule: schedule
                )
            )

        var directBytes = [UInt8](repeating: 0, count: 8)
        var explicitBytes = [UInt8](repeating: 0, count: 8)

        for _ in 0..<14 {
            let direct =
                try directBytes.withUnsafeMutableBytes {
                    try directSource.refill(into: $0)
                }
            let explicit =
                try explicitBytes.withUnsafeMutableBytes {
                    try explicitSource.refill(into: $0)
                }

            guard direct == explicit,
                  directBytes == explicitBytes
            else {
                throw TestFailure(
                    message:
                        "explicit source vtable diverged from deterministic backend"
                )
            }
        }

        var directDestination =
            DeterministicStreamDestinationBackend(
                schedule: schedule
            )
        var explicitDestination =
            DispatchVTableDestinationBackend(
                DeterministicStreamDestinationBackend(
                    schedule: schedule
                )
            )
        let payload = [UInt8](repeating: 0x5a, count: 8)

        for _ in 0..<10 {
            let direct =
                try payload.withUnsafeBytes {
                    try directDestination.drain($0)
                }
            let explicit =
                try payload.withUnsafeBytes {
                    try explicitDestination.drain($0)
                }

            guard direct == explicit else {
                throw TestFailure(
                    message:
                        "explicit destination vtable diverged from deterministic backend"
                )
            }
        }

        guard try directDestination.flush()
                == explicitDestination.flush()
        else {
            throw TestFailure(
                message:
                    "explicit destination vtable flush diverged from deterministic backend"
            )
        }
    }

    static func runDispatchVTableBenchmarks(
        heavy: Bool
    ) throws {
        let boundaryIterations =
            heavy
                ? 1_000_000
                : 250_000
        let logicalBytes =
            heavy
                ? 512 * 1024 * 1024
                : 128 * 1024 * 1024
        let sampleCount =
            heavy
                ? 7
                : 5
        let capacityBytes =
            64 * 1024
        let capacity =
            try BufferCapacity(
                capacityBytes
            )

        print("dispatch vtable isolation")
        print("  A = Swift existential / witness-table backend")
        print("  B = concrete generic backend")
        print("  E = explicit context pointer + C-ABI function-pointer table")
        print("  boundary allocation/construction timed: false")
        print("  buffered storage: identical contiguous StreamBuffer")
        print("  buffered call shape: scalar only; consume/flush to zero compaction")
        print("  samples per lane: \(sampleCount)")
        print("")

        let boundarySchedules: [DispatchVTableScheduleCase] = [
            .init(
                name: "steady",
                schedule: .init(
                    maximumRefillBytes: 1,
                    maximumDrainBytes: 1
                )
            ),
            .init(
                name: "periodic-backpressure",
                schedule: .init(
                    maximumRefillBytes: 1,
                    maximumDrainBytes: 1,
                    sourceUnavailableEvery: 7,
                    destinationUnavailableEvery: 5
                )
            ),
        ]

        print("BACKEND BOUNDARY ONLY")
        for scheduleCase in boundarySchedules {
            try runDispatchVTableBoundarySourceRow(
                scheduleCase: scheduleCase,
                iterations: boundaryIterations,
                samples: sampleCount
            )
            try runDispatchVTableBoundaryDestinationRow(
                scheduleCase: scheduleCase,
                iterations: boundaryIterations,
                samples: sampleCount
            )
        }

        let bufferedSchedules: [DispatchVTableScheduleCase] = [
            .init(
                name: "full-progress",
                schedule: .init(
                    maximumRefillBytes: capacityBytes,
                    maximumDrainBytes: capacityBytes
                )
            ),
            .init(
                name: "bounded-4k-3k",
                schedule: .init(
                    maximumRefillBytes: 4 * 1024,
                    maximumDrainBytes: 3 * 1024
                )
            ),
            .init(
                name: "periodic-backpressure",
                schedule: .init(
                    maximumRefillBytes: 4 * 1024,
                    maximumDrainBytes: 3 * 1024,
                    sourceUnavailableEvery: 7,
                    destinationUnavailableEvery: 5
                )
            ),
        ]

        print("CONTIGUOUS SOURCE / DESTINATION")
        for scheduleCase in bufferedSchedules {
            try runDispatchVTableBufferedSourceRow(
                scheduleCase: scheduleCase,
                logicalBytes: logicalBytes,
                capacity: capacity,
                samples: sampleCount
            )
            try runDispatchVTableBufferedDestinationRow(
                scheduleCase: scheduleCase,
                logicalBytes: logicalBytes,
                capacityBytes: capacityBytes,
                capacity: capacity,
                samples: sampleCount
            )
        }

        print("interpretation:")
        print("  E≈A: manual vtable has no dispatch case over Swift existential.")
        print("  E≈B and both beat A consistently: explicit runtime erasure may be useful.")
        print("  B beats A/E but E does not: prefer static generic fast paths, keep existential runtime erasure.")
        print("  no stable ordering: keep current existential representation and optimize elsewhere.")
    }

    private static func runDispatchVTableBoundarySourceRow(
        scheduleCase: DispatchVTableScheduleCase,
        iterations: Int,
        samples: Int
    ) throws {
        var measured: [DispatchVTableLane: [DispatchVTableSample]] = [:]

        for sampleIndex in 0..<samples {
            let order =
                rotatedDispatchVTableLanes(
                    offset: sampleIndex
                )

            for lane in order {
                let sample =
                    try measureDispatchVTableBoundarySource(
                        lane: lane,
                        iterations: iterations,
                        schedule: scheduleCase.schedule
                    )
                measured[lane, default: []].append(sample)
            }
        }

        try printDispatchVTableRow(
            label:
                "source · \(scheduleCase.name) · \(iterations) calls",
            measured: measured
        )
    }

    private static func runDispatchVTableBoundaryDestinationRow(
        scheduleCase: DispatchVTableScheduleCase,
        iterations: Int,
        samples: Int
    ) throws {
        var measured: [DispatchVTableLane: [DispatchVTableSample]] = [:]

        for sampleIndex in 0..<samples {
            let order =
                rotatedDispatchVTableLanes(
                    offset: sampleIndex + 1
                )

            for lane in order {
                let sample =
                    try measureDispatchVTableBoundaryDestination(
                        lane: lane,
                        iterations: iterations,
                        schedule: scheduleCase.schedule
                    )
                measured[lane, default: []].append(sample)
            }
        }

        try printDispatchVTableRow(
            label:
                "destination · \(scheduleCase.name) · \(iterations) calls",
            measured: measured
        )
    }

    private static func runDispatchVTableBufferedSourceRow(
        scheduleCase: DispatchVTableScheduleCase,
        logicalBytes: Int,
        capacity: BufferCapacity,
        samples: Int
    ) throws {
        var measured: [DispatchVTableLane: [DispatchVTableSample]] = [:]

        for sampleIndex in 0..<samples {
            let order =
                rotatedDispatchVTableLanes(
                    offset: sampleIndex + 2
                )

            for lane in order {
                let sample =
                    try measureDispatchVTableBufferedSource(
                        lane: lane,
                        logicalBytes: logicalBytes,
                        capacity: capacity,
                        schedule: scheduleCase.schedule
                    )
                measured[lane, default: []].append(sample)
            }
        }

        try printDispatchVTableRow(
            label:
                "buffered source · \(scheduleCase.name) · \(formatDispatchVTableBytes(logicalBytes))",
            measured: measured
        )
    }

    private static func runDispatchVTableBufferedDestinationRow(
        scheduleCase: DispatchVTableScheduleCase,
        logicalBytes: Int,
        capacityBytes: Int,
        capacity: BufferCapacity,
        samples: Int
    ) throws {
        var measured: [DispatchVTableLane: [DispatchVTableSample]] = [:]

        for sampleIndex in 0..<samples {
            let order =
                rotatedDispatchVTableLanes(
                    offset: sampleIndex
                )

            for lane in order {
                let sample =
                    try measureDispatchVTableBufferedDestination(
                        lane: lane,
                        logicalBytes: logicalBytes,
                        capacityBytes: capacityBytes,
                        capacity: capacity,
                        schedule: scheduleCase.schedule
                    )
                measured[lane, default: []].append(sample)
            }
        }

        try printDispatchVTableRow(
            label:
                "buffered destination · \(scheduleCase.name) · \(formatDispatchVTableBytes(logicalBytes))",
            measured: measured
        )
    }

    private static func measureDispatchVTableBoundarySource(
        lane: DispatchVTableLane,
        iterations: Int,
        schedule: DeterministicStreamSchedule
    ) throws -> DispatchVTableSample {
        let byteCount =
            iterations * 2

        switch lane {
        case .existential:
            return try timeDispatchVTableBoundarySource(
                source:
                    DispatchVTableExistentialSourceBoundary(
                        DeterministicStreamSourceBackend(
                            byteCount: byteCount,
                            schedule: schedule
                        )
                    ),
                iterations: iterations
            )

        case .generic:
            return try timeDispatchVTableBoundarySource(
                source:
                    DispatchVTableGenericSourceBoundary(
                        DeterministicStreamSourceBackend(
                            byteCount: byteCount,
                            schedule: schedule
                        )
                    ),
                iterations: iterations
            )

        case .explicit_vtable:
            return try timeDispatchVTableBoundarySource(
                source:
                    DispatchVTableGenericSourceBoundary(
                        DispatchVTableSourceBackend(
                            DeterministicStreamSourceBackend(
                                byteCount: byteCount,
                                schedule: schedule
                            )
                        )
                    ),
                iterations: iterations
            )
        }
    }

    private static func measureDispatchVTableBoundaryDestination(
        lane: DispatchVTableLane,
        iterations: Int,
        schedule: DeterministicStreamSchedule
    ) throws -> DispatchVTableSample {
        switch lane {
        case .existential:
            return try timeDispatchVTableBoundaryDestination(
                destination:
                    DispatchVTableExistentialDestinationBoundary(
                        DeterministicStreamDestinationBackend(
                            schedule: schedule
                        )
                    ),
                iterations: iterations
            )

        case .generic:
            return try timeDispatchVTableBoundaryDestination(
                destination:
                    DispatchVTableGenericDestinationBoundary(
                        DeterministicStreamDestinationBackend(
                            schedule: schedule
                        )
                    ),
                iterations: iterations
            )

        case .explicit_vtable:
            return try timeDispatchVTableBoundaryDestination(
                destination:
                    DispatchVTableGenericDestinationBoundary(
                        DispatchVTableDestinationBackend(
                            DeterministicStreamDestinationBackend(
                                schedule: schedule
                            )
                        )
                    ),
                iterations: iterations
            )
        }
    }

    @inline(never)
    private static func timeDispatchVTableBoundarySource<
        Driver: DispatchVTableSourceBoundary & ~Copyable
    >(
        source initialSource: consuming Driver,
        iterations: Int
    ) throws -> DispatchVTableSample {
        var source = consume initialSource
        let storage =
            UnsafeMutableRawPointer.allocate(
                byteCount: 1,
                alignment: 1
            )
        defer {
            storage.deallocate()
        }

        storage.storeBytes(
            of: UInt8(0),
            as: UInt8.self
        )
        let bytes =
            UnsafeMutableRawBufferPointer(
                start: storage,
                count: 1
            )

        var progress: UInt64 = 0
        var unavailable: UInt64 = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            switch try source.refill(into: bytes) {
            case .bytes(let count),
                 .final_bytes(let count):
                progress += UInt64(count.value)

            case .unavailable:
                unavailable += 1

            case .retry:
                throw TestFailure(
                    message:
                        "dispatch-vtable boundary source unexpectedly returned retry"
                )

            case .end:
                throw TestFailure(
                    message:
                        "dispatch-vtable boundary source unexpectedly reached end"
                )
            }
        }

        let end =
            DispatchTime.now().uptimeNanoseconds

        return .init(
            seconds:
                Double(end - start)
                / 1_000_000_000,
            progress: progress,
            callCount: UInt64(iterations),
            unavailableCount: unavailable,
            compactedByteCount: 0
        )
    }

    @inline(never)
    private static func timeDispatchVTableBoundaryDestination<
        Driver: DispatchVTableDestinationBoundary & ~Copyable
    >(
        destination initialDestination: consuming Driver,
        iterations: Int
    ) throws -> DispatchVTableSample {
        var destination = consume initialDestination
        let storage =
            UnsafeMutableRawPointer.allocate(
                byteCount: 1,
                alignment: 1
            )
        defer {
            storage.deallocate()
        }

        storage.storeBytes(
            of: UInt8(0x5a),
            as: UInt8.self
        )
        let bytes =
            UnsafeRawBufferPointer(
                start: UnsafeRawPointer(storage),
                count: 1
            )

        var progress: UInt64 = 0
        var unavailable: UInt64 = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        for _ in 0..<iterations {
            switch try destination.drain(bytes) {
            case .bytes(let count):
                progress += UInt64(count.value)

            case .unavailable:
                unavailable += 1
            }
        }

        guard try destination.flush() == .complete else {
            throw TestFailure(
                message:
                    "dispatch-vtable boundary destination flush unavailable"
            )
        }

        let end =
            DispatchTime.now().uptimeNanoseconds

        return .init(
            seconds:
                Double(end - start)
                / 1_000_000_000,
            progress: progress,
            callCount: UInt64(iterations),
            unavailableCount: unavailable,
            compactedByteCount: 0
        )
    }

    private static func measureDispatchVTableBufferedSource(
        lane: DispatchVTableLane,
        logicalBytes: Int,
        capacity: BufferCapacity,
        schedule: DeterministicStreamSchedule
    ) throws -> DispatchVTableSample {
        switch lane {
        case .existential:
            return try timeDispatchVTableBufferedSource(
                source:
                    DispatchVTableExistentialBufferedSource(
                        DeterministicStreamSourceBackend(
                            byteCount: logicalBytes,
                            schedule: schedule
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes
            )

        case .generic:
            return try timeDispatchVTableBufferedSource(
                source:
                    DispatchVTableGenericBufferedSource(
                        DeterministicStreamSourceBackend(
                            byteCount: logicalBytes,
                            schedule: schedule
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes
            )

        case .explicit_vtable:
            return try timeDispatchVTableBufferedSource(
                source:
                    DispatchVTableGenericBufferedSource(
                        DispatchVTableSourceBackend(
                            DeterministicStreamSourceBackend(
                                byteCount: logicalBytes,
                                schedule: schedule
                            )
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes
            )
        }
    }

    @inline(never)
    private static func timeDispatchVTableBufferedSource<
        Driver: DispatchVTableBufferedSourceDriver & ~Copyable
    >(
        source initialSource: consuming Driver,
        logicalBytes: Int
    ) throws -> DispatchVTableSample {
        var source = consume initialSource
        var consumed = 0
        var unavailable: UInt64 = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        while consumed < logicalBytes {
            let availability =
                try source.requestMore()

            if availability == .unavailable {
                unavailable += 1
                continue
            }

            if source.bufferedByteCount > 0 {
                let count =
                    min(
                        source.bufferedByteCount,
                        logicalBytes - consumed
                    )
                try source.consume(count)
                consumed += count
                continue
            }

            if availability == .end {
                break
            }

            if availability == .buffer_full {
                throw TestFailure(
                    message:
                        "dispatch-vtable buffered source unexpectedly reported buffer_full"
                )
            }
        }

        let end =
            DispatchTime.now().uptimeNanoseconds

        guard consumed == logicalBytes else {
            throw TestFailure(
                message:
                    "dispatch-vtable buffered source did not consume requested bytes"
            )
        }

        guard source.compactedByteCount == 0 else {
            throw TestFailure(
                message:
                    "dispatch-vtable buffered source unexpectedly compacted storage"
            )
        }

        return .init(
            seconds:
                Double(end - start)
                / 1_000_000_000,
            progress: UInt64(consumed),
            callCount: source.refillCallCount,
            unavailableCount: unavailable,
            compactedByteCount:
                source.compactedByteCount
        )
    }

    private static func measureDispatchVTableBufferedDestination(
        lane: DispatchVTableLane,
        logicalBytes: Int,
        capacityBytes: Int,
        capacity: BufferCapacity,
        schedule: DeterministicStreamSchedule
    ) throws -> DispatchVTableSample {
        switch lane {
        case .existential:
            return try timeDispatchVTableBufferedDestination(
                destination:
                    DispatchVTableExistentialBufferedDestination(
                        DeterministicStreamDestinationBackend(
                            schedule: schedule
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes,
                capacityBytes: capacityBytes
            )

        case .generic:
            return try timeDispatchVTableBufferedDestination(
                destination:
                    DispatchVTableGenericBufferedDestination(
                        DeterministicStreamDestinationBackend(
                            schedule: schedule
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes,
                capacityBytes: capacityBytes
            )

        case .explicit_vtable:
            return try timeDispatchVTableBufferedDestination(
                destination:
                    DispatchVTableGenericBufferedDestination(
                        DispatchVTableDestinationBackend(
                            DeterministicStreamDestinationBackend(
                                schedule: schedule
                            )
                        ),
                        capacity: capacity
                    ),
                logicalBytes: logicalBytes,
                capacityBytes: capacityBytes
            )
        }
    }

    @inline(never)
    private static func timeDispatchVTableBufferedDestination<
        Driver: DispatchVTableBufferedDestinationDriver & ~Copyable
    >(
        destination initialDestination: consuming Driver,
        logicalBytes: Int,
        capacityBytes: Int
    ) throws -> DispatchVTableSample {
        var destination =
            consume initialDestination
        let chunk =
            [UInt8](
                repeating: 0x5a,
                count: capacityBytes
            )

        var accepted = 0
        var unavailable: UInt64 = 0

        let start =
            DispatchTime.now().uptimeNanoseconds

        while accepted < logicalBytes {
            let requestCount =
                min(
                    capacityBytes,
                    logicalBytes - accepted
                )

            let result =
                try chunk.withUnsafeBytes {
                    raw -> DestinationWrite in

                    try destination.write(
                        UnsafeRawBufferPointer(
                            start: raw.baseAddress,
                            count: requestCount
                        )
                    )
                }

            switch result {
            case .complete:
                accepted += requestCount

            case .partial(let count):
                accepted += count.value
                unavailable += 1

            case .unavailable:
                unavailable += 1
            }

            while destination.bufferedByteCount > 0 {
                if try destination.flush()
                    == .unavailable
                {
                    unavailable += 1
                }
            }
        }

        let end =
            DispatchTime.now().uptimeNanoseconds

        guard destination.compactedByteCount == 0 else {
            throw TestFailure(
                message:
                    "dispatch-vtable buffered destination unexpectedly compacted storage"
            )
        }

        return .init(
            seconds:
                Double(end - start)
                / 1_000_000_000,
            progress: UInt64(accepted),
            callCount: destination.drainCallCount,
            unavailableCount: unavailable,
            compactedByteCount:
                destination.compactedByteCount
        )
    }

    private static func rotatedDispatchVTableLanes(
        offset: Int
    ) -> [DispatchVTableLane] {
        let lanes =
            DispatchVTableLane.allCases
        let normalized =
            offset % lanes.count

        return Array(lanes[normalized...])
            + Array(lanes[..<normalized])
    }

    private static func printDispatchVTableRow(
        label: String,
        measured: [DispatchVTableLane: [DispatchVTableSample]]
    ) throws {
        guard let existential =
                measured[.existential],
              let generic =
                measured[.generic],
              let explicit =
                measured[.explicit_vtable],
              let reference =
                existential.first
        else {
            throw TestFailure(
                message:
                    "dispatch-vtable benchmark produced incomplete lane data"
            )
        }

        for (lane, samples) in measured {
            for sample in samples {
                guard sample.progress
                        == reference.progress,
                      sample.callCount
                        == reference.callCount,
                      sample.unavailableCount
                        == reference.unavailableCount,
                      sample.compactedByteCount
                        == reference.compactedByteCount
                else {
                    throw TestFailure(
                        message:
                            "dispatch-vtable lane \(lane.rawValue) did not perform equivalent work for \(label)"
                    )
                }
            }
        }

        let a =
            dispatchVTableMedian(
                existential.map(\.seconds)
            )
        let b =
            dispatchVTableMedian(
                generic.map(\.seconds)
            )
        let e =
            dispatchVTableMedian(
                explicit.map(\.seconds)
            )

        print(label)
        print(
            "  A existential \(formatDispatchVTableMilliseconds(a))"
            + " [\(formatDispatchVTableMilliseconds(existential.map(\.seconds).min()!))…\(formatDispatchVTableMilliseconds(existential.map(\.seconds).max()!))]"
        )
        print(
            "  B generic \(formatDispatchVTableMilliseconds(b))"
            + " [\(formatDispatchVTableMilliseconds(generic.map(\.seconds).min()!))…\(formatDispatchVTableMilliseconds(generic.map(\.seconds).max()!))]"
        )
        print(
            "  E explicit_vtable \(formatDispatchVTableMilliseconds(e))"
            + " [\(formatDispatchVTableMilliseconds(explicit.map(\.seconds).min()!))…\(formatDispatchVTableMilliseconds(explicit.map(\.seconds).max()!))]"
        )
        print(
            String(
                format:
                    "  time ratios B/A %.3fx · E/A %.3fx · E/B %.3fx",
                b / a,
                e / a,
                e / b
            )
        )
        print(
            "  work calls \(reference.callCount)"
            + " · progress \(reference.progress)"
            + " · unavailable \(reference.unavailableCount)"
            + " · compacted \(reference.compactedByteCount)"
        )
        print("")
    }

    private static func dispatchVTableMedian(
        _ values: [Double]
    ) -> Double {
        let sorted =
            values.sorted()
        return sorted[
            sorted.count / 2
        ]
    }

    private static func formatDispatchVTableMilliseconds(
        _ seconds: Double
    ) -> String {
        String(
            format: "%.3f ms",
            seconds * 1_000
        )
    }

    private static func formatDispatchVTableBytes(
        _ bytes: Int
    ) -> String {
        let mib =
            Double(bytes)
            / (1024 * 1024)

        return String(
            format: "%.2f MiB",
            mib
        )
    }
}
