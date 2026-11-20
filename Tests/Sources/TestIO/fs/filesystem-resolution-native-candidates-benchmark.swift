import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    enum NativeResolutionCandidateLane:
        Hashable
    {
        case foundation
        case current_c
        case native_presentation_realpath
        case readlink_hybrid
    }

    struct NativeResolutionCandidateSummary {
        let minimum: Double
        let median: Double
        let maximum: Double

        init(
            samples: [Double]
        ) throws {
            guard !samples.isEmpty else {
                throw TestFailure(
                    message: "native resolution benchmark requires at least one sample"
                )
            }

            let sorted = samples.sorted()
            let middle = sorted.count / 2

            self.minimum = sorted[0]
            self.median = sorted[middle]
            self.maximum = sorted[sorted.count - 1]
        }
    }

    static func testNativeResolutionCandidates() throws {
        try withFileSystemResolutionFixture {
            _,
            cases in

            for item in cases {
                let foundation =
                    FileSystem.foundation.resolve(
                        item.input
                    )
                let nativeRealpath =
                    resolutionNativePresentationRealpath(
                        item.input
                    )
                let readlinkHybrid =
                    resolutionReadlinkHybrid(
                        item.input
                    )

                try expectEqual(
                    nativeRealpath,
                    foundation,
                    "native-presentation realpath differs for \(item.name)"
                )
                try expectEqual(
                    readlinkHybrid,
                    foundation,
                    "readlink hybrid differs for \(item.name)"
                )
            }
        }
    }

    static func runNativeResolutionCandidateBenchmarks(
        heavy: Bool
    ) throws {
        try withFileSystemResolutionFixture {
            _,
            cases in

            print("")
            print("filesystem native resolution candidates")
            print("foundation: FileSystem.foundation.resolve")
            print("current_c: FileSystem.c.resolve")
            print(
                "native_presentation_realpath: fixed-buffer realpath + native Darwin presentation"
            )
            print(
                "readlink_hybrid: leaf lstat/readlink chain + native-presentation realpath fallback"
            )
            print(
                "iterations_per_lane: "
                    + "\(heavy ? 20_000 : 2_000)"
            )
            print("samples_per_lane: 7")
            print("lane_order: rotating_counterbalanced")
            print("")

            for item in cases {
                let foundation =
                    FileSystem.foundation.resolve(
                        item.input
                    )
                let nativeRealpath =
                    resolutionNativePresentationRealpath(
                        item.input
                    )
                let readlinkHybrid =
                    resolutionReadlinkHybrid(
                        item.input
                    )

                try expectEqual(
                    nativeRealpath,
                    foundation,
                    "native-presentation realpath differs for \(item.name)"
                )
                try expectEqual(
                    readlinkHybrid,
                    foundation,
                    "readlink hybrid differs for \(item.name)"
                )

                try runNativeResolutionCandidateBenchmarkCase(
                    name: item.name,
                    url: item.input,
                    iterations:
                        heavy
                        ? 20_000
                        : 2_000
                )
            }
        }
    }
}

extension TestIO {
    static let resolutionSlash = CChar(47)
    static let resolutionDot = CChar(46)
    static let resolutionSymlinkLimit = 40

    static func runNativeResolutionCandidateBenchmarkCase(
        name: String,
        url: URL,
        iterations: Int
    ) throws {
        let lanes: [NativeResolutionCandidateLane] = [
            .foundation,
            .current_c,
            .native_presentation_realpath,
            .readlink_hybrid,
        ]
        let sampleCount = 7
        let baseIterations =
            iterations / sampleCount
        let extraIterations =
            iterations % sampleCount

        var samples: [
            NativeResolutionCandidateLane: [Double]
        ] = [:]
        var sink = 0

        for sampleIndex in 0..<sampleCount {
            let sampleIterations =
                baseIterations
                + (
                    sampleIndex < extraIterations
                    ? 1
                    : 0
                )
            let rotation =
                sampleIndex % lanes.count
            let order =
                Array(
                    lanes[rotation...]
                )
                + Array(
                    lanes[..<rotation]
                )

            for lane in order {
                let seconds =
                    nativeResolutionMeasure(
                        iterations: sampleIterations
                    ) {
                        let resolved: URL

                        switch lane {
                        case .foundation:
                            resolved =
                                FileSystem.foundation.resolve(
                                    url
                                )

                        case .current_c:
                            resolved =
                                FileSystem.c.resolve(
                                    url
                                )

                        case .native_presentation_realpath:
                            resolved =
                                resolutionNativePresentationRealpath(
                                    url
                                )

                        case .readlink_hybrid:
                            resolved =
                                resolutionReadlinkHybrid(
                                    url
                                )
                        }

                        sink &+= resolved.path.count
                    }

                samples[
                    lane,
                    default: []
                ].append(
                    seconds
                        / Double(
                            sampleIterations
                        )
                )
            }
        }

        withExtendedLifetime(
            sink
        ) {}

        let foundation =
            try NativeResolutionCandidateSummary(
                samples:
                    samples[.foundation]
                    ?? []
            )
        let currentC =
            try NativeResolutionCandidateSummary(
                samples:
                    samples[.current_c]
                    ?? []
            )
        let nativeRealpath =
            try NativeResolutionCandidateSummary(
                samples:
                    samples[
                        .native_presentation_realpath
                    ]
                    ?? []
            )
        let readlinkHybrid =
            try NativeResolutionCandidateSummary(
                samples:
                    samples[.readlink_hybrid]
                    ?? []
            )

        print(name)
        printNativeResolutionSummary(
            name: "foundation",
            summary: foundation
        )
        printNativeResolutionSummary(
            name: "current_c",
            summary: currentC
        )
        printNativeResolutionSummary(
            name: "native_presentation_realpath",
            summary: nativeRealpath
        )
        printNativeResolutionSummary(
            name: "readlink_hybrid",
            summary: readlinkHybrid
        )
        print(
            "  native_realpath_vs_foundation_x: "
                + nativeResolutionFormattedRatio(
                    foundation.median
                        / max(
                            nativeRealpath.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  readlink_hybrid_vs_foundation_x: "
                + nativeResolutionFormattedRatio(
                    foundation.median
                        / max(
                            readlinkHybrid.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  readlink_hybrid_vs_native_realpath_x: "
                + nativeResolutionFormattedRatio(
                    nativeRealpath.median
                        / max(
                            readlinkHybrid.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print("")
    }

    static func resolutionNativePresentationRealpath(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return input.standardizedFileURL
            }

            return withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                output in

                guard let baseAddress =
                        output.baseAddress,
                      realpath(
                        pointer,
                        baseAddress
                      ) != nil
                else {
                    return input.standardizedFileURL
                }

                normalizeDarwinPresentation(
                    output
                )

                return URL(
                    fileURLWithFileSystemRepresentation:
                        baseAddress,
                    isDirectory:
                        input.hasDirectoryPath,
                    relativeTo: nil
                )
            }
        }
    }

    static func resolutionReadlinkHybrid(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return input.standardizedFileURL
            }

            return withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                current in

                withUnsafeTemporaryAllocation(
                    of: CChar.self,
                    capacity: Int(PATH_MAX)
                ) {
                    scratch in

                    withUnsafeTemporaryAllocation(
                        of: CChar.self,
                        capacity: Int(PATH_MAX)
                    ) {
                        target in

                        withUnsafeTemporaryAllocation(
                            of: CChar.self,
                            capacity: Int(PATH_MAX)
                        ) {
                            original in

                            guard normalizeAbsolutePath(
                                pointer,
                                into: current
                            ),
                            copyCString(
                                from: current,
                                to: original
                            )
                            else {
                                return input.standardizedFileURL
                            }

                            var followedLinks = 0

                            while true {
                                guard let currentBase =
                                        current.baseAddress
                                else {
                                    return input.standardizedFileURL
                                }

                                var info = stat()

                                guard lstat(
                                    currentBase,
                                    &info
                                ) == 0
                                else {
                                    return input.standardizedFileURL
                                }

                                let type =
                                    info.st_mode
                                    & mode_t(S_IFMT)

                                guard type
                                        == mode_t(S_IFLNK)
                                else {
                                    if followedLinks == 0 {
                                        return resolutionNativePresentationRealpath(
                                            input
                                        )
                                    }

                                    normalizeDarwinPresentation(
                                        current
                                    )

                                    guard let resolvedBase =
                                            current.baseAddress
                                    else {
                                        return input.standardizedFileURL
                                    }

                                    return URL(
                                        fileURLWithFileSystemRepresentation:
                                            resolvedBase,
                                        isDirectory:
                                            input.hasDirectoryPath,
                                        relativeTo: nil
                                    )
                                }

                                followedLinks += 1

                                guard followedLinks
                                        <= resolutionSymlinkLimit,
                                      let targetBase =
                                        target.baseAddress
                                else {
                                    return input.standardizedFileURL
                                }

                                let targetCount =
                                    readlink(
                                        currentBase,
                                        targetBase,
                                        target.count - 1
                                    )

                                guard targetCount >= 0,
                                      targetCount
                                        < target.count
                                else {
                                    return input.standardizedFileURL
                                }

                                target[
                                    targetCount
                                ] = 0

                                guard composeSymlinkTarget(
                                    current: current,
                                    target: target,
                                    into: scratch
                                ),
                                let scratchBase =
                                    scratch.baseAddress,
                                normalizeAbsolutePath(
                                    scratchBase,
                                    into: current
                                )
                                else {
                                    return input.standardizedFileURL
                                }

                                if followedLinks > 1,
                                   cStringsEqual(
                                    current,
                                    original
                                   )
                                {
                                    return input.standardizedFileURL
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static func composeSymlinkTarget(
        current: UnsafeMutableBufferPointer<CChar>,
        target: UnsafeMutableBufferPointer<CChar>,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard let currentBase =
                current.baseAddress,
              let targetBase =
                target.baseAddress
        else {
            return false
        }

        if targetBase[0]
            == resolutionSlash
        {
            return copyCString(
                from: target,
                to: output
            )
        }

        let currentLength =
            cStringLength(
                currentBase
            )

        guard currentLength > 0 else {
            return false
        }

        var lastSlash =
            currentLength - 1

        while lastSlash > 0,
              currentBase[lastSlash]
                != resolutionSlash
        {
            lastSlash -= 1
        }

        let parentLength =
            lastSlash == 0
            ? 1
            : lastSlash

        guard parentLength
                < output.count
        else {
            return false
        }

        for index in 0..<parentLength {
            output[index] =
                currentBase[index]
        }

        var writeIndex =
            parentLength

        if writeIndex > 1 {
            guard writeIndex
                    < output.count
            else {
                return false
            }

            output[writeIndex] =
                resolutionSlash
            writeIndex += 1
        }

        var targetIndex = 0

        while targetBase[targetIndex] != 0 {
            guard writeIndex
                    < output.count - 1
            else {
                return false
            }

            output[writeIndex] =
                targetBase[targetIndex]
            writeIndex += 1
            targetIndex += 1
        }

        output[writeIndex] = 0
        return true
    }

    static func normalizeAbsolutePath(
        _ source: UnsafePointer<CChar>,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard source[0]
                == resolutionSlash,
              !output.isEmpty
        else {
            return false
        }

        output[0] =
            resolutionSlash

        var readIndex = 1
        var writeIndex = 1

        while source[readIndex] != 0 {
            while source[readIndex]
                    == resolutionSlash
            {
                readIndex += 1
            }

            guard source[readIndex] != 0 else {
                break
            }

            let componentStart =
                readIndex

            while source[readIndex] != 0,
                  source[readIndex]
                    != resolutionSlash
            {
                readIndex += 1
            }

            let componentLength =
                readIndex - componentStart

            if componentLength == 1,
               source[componentStart]
                == resolutionDot
            {
                continue
            }

            if componentLength == 2,
               source[componentStart]
                    == resolutionDot,
               source[
                componentStart + 1
               ] == resolutionDot
            {
                while writeIndex > 1,
                      output[
                        writeIndex - 1
                      ] != resolutionSlash
                {
                    writeIndex -= 1
                }

                if writeIndex > 1 {
                    writeIndex -= 1
                }

                continue
            }

            if writeIndex > 1 {
                guard writeIndex
                        < output.count - 1
                else {
                    return false
                }

                output[writeIndex] =
                    resolutionSlash
                writeIndex += 1
            }

            guard writeIndex
                    + componentLength
                    < output.count
            else {
                return false
            }

            for offset
                in 0..<componentLength
            {
                output[
                    writeIndex + offset
                ] = source[
                    componentStart + offset
                ]
            }

            writeIndex +=
                componentLength
        }

        guard writeIndex
                < output.count
        else {
            return false
        }

        output[writeIndex] = 0
        return true
    }

    static func copyCString(
        from source: UnsafeMutableBufferPointer<CChar>,
        to destination: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard let sourceBase =
                source.baseAddress
        else {
            return false
        }

        var count = 0

        while sourceBase[count] != 0 {
            guard count
                    < destination.count - 1
            else {
                return false
            }

            destination[count] =
                sourceBase[count]
            count += 1
        }

        destination[count] = 0
        return true
    }

    static func cStringsEqual(
        _ lhs: UnsafeMutableBufferPointer<CChar>,
        _ rhs: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard let lhsBase =
                lhs.baseAddress,
              let rhsBase =
                rhs.baseAddress
        else {
            return false
        }

        return strcmp(
            lhsBase,
            rhsBase
        ) == 0
    }

    static func cStringLength(
        _ pointer: UnsafePointer<CChar>
    ) -> Int {
        var count = 0

        while pointer[count] != 0 {
            count += 1
        }

        return count
    }

    static func normalizeDarwinPresentation(
        _ path: UnsafeMutableBufferPointer<CChar>
    ) {
        #if canImport(Darwin)
        guard let baseAddress =
                path.baseAddress
        else {
            return
        }

        let prefixes: [[CChar]] = [
            [
                47, 112, 114, 105, 118, 97, 116, 101,
                47, 118, 97, 114,
            ],
            [
                47, 112, 114, 105, 118, 97, 116, 101,
                47, 116, 109, 112,
            ],
            [
                47, 112, 114, 105, 118, 97, 116, 101,
                47, 101, 116, 99,
            ],
        ]

        for prefix in prefixes {
            var matches = true

            for index in prefix.indices {
                if baseAddress[index]
                    != prefix[index]
                {
                    matches = false
                    break
                }
            }

            guard matches else {
                continue
            }

            let boundary =
                baseAddress[
                    prefix.count
                ]

            guard boundary == 0
                    || boundary
                        == resolutionSlash
            else {
                continue
            }

            let remainder =
                baseAddress.advanced(
                    by: 8
                )
            let byteCount =
                cStringLength(
                    remainder
                ) + 1

            memmove(
                baseAddress,
                remainder,
                byteCount
            )
            return
        }
        #endif
    }

    static func nativeResolutionMeasure(
        iterations: Int,
        operation: () -> Void
    ) -> Double {
        let clock =
            ContinuousClock()
        let started =
            clock.now

        for _ in 0..<iterations {
            operation()
        }

        let duration =
            started.duration(
                to: clock.now
            )
        let components =
            duration.components

        return Double(
            components.seconds
        ) + Double(
            components.attoseconds
        ) / 1_000_000_000_000_000_000
    }

    static func printNativeResolutionSummary(
        name: String,
        summary: NativeResolutionCandidateSummary
    ) {
        print(
            "  \(name)_seconds_per_operation_min: "
                + nativeResolutionFormattedSeconds(
                    summary.minimum
                )
        )
        print(
            "  \(name)_seconds_per_operation_median: "
                + nativeResolutionFormattedSeconds(
                    summary.median
                )
        )
        print(
            "  \(name)_seconds_per_operation_max: "
                + nativeResolutionFormattedSeconds(
                    summary.maximum
                )
        )
    }

    static func nativeResolutionFormattedSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.9f",
            value
        )
    }

    static func nativeResolutionFormattedRatio(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }
}
