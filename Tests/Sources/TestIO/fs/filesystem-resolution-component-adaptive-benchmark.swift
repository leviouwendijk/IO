import Foundation
import IO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension TestIO {
    enum ComponentResolutionLane:
        Hashable
    {
        case foundation
        case readlink_hybrid
        case component_adaptive
    }

    struct ComponentResolutionSummary {
        let minimum: Double
        let median: Double
        let maximum: Double

        init(
            samples: [Double]
        ) throws {
            guard !samples.isEmpty else {
                throw TestFailure(
                    message:
                        "component resolution benchmark requires at least one sample"
                )
            }

            let sorted = samples.sorted()
            let middle = sorted.count / 2

            self.minimum = sorted[0]
            self.median = sorted[middle]
            self.maximum = sorted[sorted.count - 1]
        }
    }

    static func testComponentAdaptiveResolutionCandidate() throws {
        try withFileSystemResolutionFixture {
            _,
            cases in

            for item in cases {
                try expectEqual(
                    resolutionComponentAdaptive(
                        item.input
                    ),
                    FileSystem.foundation.resolve(
                        item.input
                    ),
                    "component-adaptive resolver differs for \(item.name)"
                )
            }
        }
    }

    static func runComponentAdaptiveResolutionBenchmarks(
        heavy: Bool
    ) throws {
        try withFileSystemResolutionFixture {
            _,
            cases in

            print("")
            print("filesystem component-adaptive resolution")
            print("foundation: FileSystem.foundation.resolve")
            print(
                "readlink_hybrid: R0e leaf lstat/readlink + native realpath fallback"
            )
            print(
                "component_adaptive: readlink hybrid unless lexical dot components require component walking"
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
                let candidate =
                    resolutionComponentAdaptive(
                        item.input
                    )

                try expectEqual(
                    candidate,
                    foundation,
                    "component-adaptive resolver differs for \(item.name)"
                )

                try runComponentResolutionCase(
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
    static let componentSlash =
        CChar(47)
    static let componentDot =
        CChar(46)
    static let componentSymlinkLimit =
        40

    static func resolutionComponentAdaptive(
        _ input: URL
    ) -> URL {
        input.withUnsafeFileSystemRepresentation {
            pointer in

            guard let pointer else {
                return input.standardizedFileURL
            }

            guard containsLexicalDotComponent(
                pointer
            ) else {
                return resolutionReadlinkHybrid(
                    input
                )
            }

            return resolutionComponentWalk(
                input,
                pointer: pointer
            )
        }
    }

    static func resolutionComponentWalk(
        _ input: URL,
        pointer: UnsafePointer<CChar>
    ) -> URL {
        withUnsafeTemporaryAllocation(
            of: CChar.self,
            capacity: Int(PATH_MAX)
        ) {
            workA in

            withUnsafeTemporaryAllocation(
                of: CChar.self,
                capacity: Int(PATH_MAX)
            ) {
                workB in

                withUnsafeTemporaryAllocation(
                    of: CChar.self,
                    capacity: Int(PATH_MAX)
                ) {
                    resolved in

                    withUnsafeTemporaryAllocation(
                        of: CChar.self,
                        capacity: Int(PATH_MAX)
                    ) {
                        target in

                        guard copyCString(
                            pointer,
                            into: workA
                        ),
                        !resolved.isEmpty
                        else {
                            return input.standardizedFileURL
                        }

                        resolved[0] =
                            componentSlash

                        guard resolved.count > 1 else {
                            return input.standardizedFileURL
                        }

                        resolved[1] = 0

                        var resolvedLength = 1
                        var pendingIsA = true
                        var cursor = 0
                        var followedLinks = 0

                        while true {
                            let pending =
                                pendingIsA
                                ? workA
                                : workB

                            while pending[cursor]
                                    == componentSlash
                            {
                                cursor += 1
                            }

                            guard pending[cursor] != 0 else {
                                break
                            }

                            let componentStart =
                                cursor

                            while pending[cursor] != 0,
                                  pending[cursor]
                                    != componentSlash
                            {
                                cursor += 1
                            }

                            let componentEnd =
                                cursor
                            let componentLength =
                                componentEnd
                                - componentStart

                            if componentLength == 1,
                               pending[componentStart]
                                == componentDot
                            {
                                continue
                            }

                            if componentLength == 2,
                               pending[componentStart]
                                    == componentDot,
                               pending[
                                componentStart + 1
                               ] == componentDot
                            {
                                popResolvedComponent(
                                    resolved,
                                    length:
                                        &resolvedLength
                                )
                                continue
                            }

                            let parentLength =
                                resolvedLength

                            guard appendComponent(
                                from: pending,
                                range:
                                    componentStart..<componentEnd,
                                to: resolved,
                                length:
                                    &resolvedLength
                            ),
                            let resolvedBase =
                                resolved.baseAddress
                            else {
                                return input.standardizedFileURL
                            }

                            var info = stat()

                            guard lstat(
                                resolvedBase,
                                &info
                            ) == 0
                            else {
                                return input.standardizedFileURL
                            }

                            let fileType =
                                info.st_mode
                                & mode_t(S_IFMT)

                            guard fileType
                                    == mode_t(S_IFLNK)
                            else {
                                continue
                            }

                            followedLinks += 1

                            guard followedLinks
                                    <= componentSymlinkLimit,
                                  let targetBase =
                                    target.baseAddress
                            else {
                                return input.standardizedFileURL
                            }

                            let targetCount =
                                readlink(
                                    resolvedBase,
                                    targetBase,
                                    target.count - 1
                                )

                            guard targetCount >= 0,
                                  targetCount
                                    < target.count
                            else {
                                return input.standardizedFileURL
                            }

                            target[targetCount] = 0

                            resolvedLength =
                                parentLength
                            resolved[
                                resolvedLength
                            ] = 0

                            if targetBase[0]
                                == componentSlash
                            {
                                resolvedLength = 1
                                resolved[0] =
                                    componentSlash
                                resolved[1] = 0
                            }

                            let nextPending =
                                pendingIsA
                                ? workB
                                : workA

                            guard composePending(
                                target: target,
                                current: pending,
                                remainderStart:
                                    componentEnd,
                                into: nextPending
                            ) else {
                                return input.standardizedFileURL
                            }

                            pendingIsA.toggle()
                            cursor = 0
                        }

                        normalizeDarwinPresentation(
                            resolved
                        )

                        guard let resolvedBase =
                            resolved.baseAddress
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
                }
            }
        }
    }

    static func containsLexicalDotComponent(
        _ pointer: UnsafePointer<CChar>
    ) -> Bool {
        var index = 0

        while pointer[index] != 0 {
            while pointer[index]
                    == componentSlash
            {
                index += 1
            }

            guard pointer[index] != 0 else {
                return false
            }

            let start = index

            while pointer[index] != 0,
                  pointer[index]
                    != componentSlash
            {
                index += 1
            }

            let length =
                index - start

            if length == 1,
               pointer[start]
                == componentDot
            {
                return true
            }

            if length == 2,
               pointer[start]
                    == componentDot,
               pointer[
                start + 1
               ] == componentDot
            {
                return true
            }
        }

        return false
    }

    static func appendComponent(
        from source: UnsafeMutableBufferPointer<CChar>,
        range: Range<Int>,
        to destination: UnsafeMutableBufferPointer<CChar>,
        length: inout Int
    ) -> Bool {
        guard !range.isEmpty else {
            return true
        }

        if length > 1 {
            guard length
                    < destination.count - 1
            else {
                return false
            }

            destination[length] =
                componentSlash
            length += 1
        }

        guard length
                + range.count
                < destination.count
        else {
            return false
        }

        var destinationIndex =
            length

        for sourceIndex in range {
            destination[
                destinationIndex
            ] = source[
                sourceIndex
            ]
            destinationIndex += 1
        }

        length = destinationIndex
        destination[length] = 0
        return true
    }

    static func popResolvedComponent(
        _ path: UnsafeMutableBufferPointer<CChar>,
        length: inout Int
    ) {
        guard length > 1 else {
            return
        }

        var index =
            length

        while index > 1,
              path[index - 1]
                != componentSlash
        {
            index -= 1
        }

        length =
            max(
                1,
                index - 1
            )
        path[length] = 0
    }

    static func composePending(
        target: UnsafeMutableBufferPointer<CChar>,
        current: UnsafeMutableBufferPointer<CChar>,
        remainderStart: Int,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard let targetBase =
                target.baseAddress
        else {
            return false
        }

        var outputIndex = 0
        var targetIndex = 0

        while targetBase[targetIndex] != 0 {
            guard outputIndex
                    < output.count - 1
            else {
                return false
            }

            output[outputIndex] =
                targetBase[targetIndex]
            outputIndex += 1
            targetIndex += 1
        }

        var remainderIndex =
            remainderStart

        if current[remainderIndex] != 0,
           outputIndex > 0,
           output[
            outputIndex - 1
           ] != componentSlash,
           current[remainderIndex]
            != componentSlash
        {
            guard outputIndex
                    < output.count - 1
            else {
                return false
            }

            output[outputIndex] =
                componentSlash
            outputIndex += 1
        }

        while current[remainderIndex] != 0 {
            guard outputIndex
                    < output.count - 1
            else {
                return false
            }

            output[outputIndex] =
                current[
                    remainderIndex
                ]
            outputIndex += 1
            remainderIndex += 1
        }

        output[outputIndex] = 0
        return true
    }

    static func copyCString(
        _ source: UnsafePointer<CChar>,
        into destination: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        var index = 0

        while source[index] != 0 {
            guard index
                    < destination.count - 1
            else {
                return false
            }

            destination[index] =
                source[index]
            index += 1
        }

        destination[index] = 0
        return true
    }

    static func runComponentResolutionCase(
        name: String,
        url: URL,
        iterations: Int
    ) throws {
        let lanes: [ComponentResolutionLane] = [
            .foundation,
            .readlink_hybrid,
            .component_adaptive,
        ]
        let sampleCount = 7
        let baseIterations =
            iterations / sampleCount
        let extraIterations =
            iterations % sampleCount

        var samples: [
            ComponentResolutionLane: [Double]
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
                    componentResolutionMeasure(
                        iterations:
                            sampleIterations
                    ) {
                        let resolved: URL

                        switch lane {
                        case .foundation:
                            resolved =
                                FileSystem.foundation.resolve(
                                    url
                                )

                        case .readlink_hybrid:
                            resolved =
                                resolutionReadlinkHybrid(
                                    url
                                )

                        case .component_adaptive:
                            resolved =
                                resolutionComponentAdaptive(
                                    url
                                )
                        }

                        sink &+=
                            resolved.path.count
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
            try ComponentResolutionSummary(
                samples:
                    samples[.foundation]
                    ?? []
            )
        let readlink =
            try ComponentResolutionSummary(
                samples:
                    samples[.readlink_hybrid]
                    ?? []
            )
        let adaptive =
            try ComponentResolutionSummary(
                samples:
                    samples[.component_adaptive]
                    ?? []
            )

        print(name)
        printComponentResolutionSummary(
            name: "foundation",
            summary: foundation
        )
        printComponentResolutionSummary(
            name: "readlink_hybrid",
            summary: readlink
        )
        printComponentResolutionSummary(
            name: "component_adaptive",
            summary: adaptive
        )
        print(
            "  component_adaptive_vs_foundation_x: "
                + componentResolutionRatio(
                    foundation.median
                        / max(
                            adaptive.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print(
            "  component_adaptive_vs_readlink_hybrid_x: "
                + componentResolutionRatio(
                    readlink.median
                        / max(
                            adaptive.median,
                            .leastNonzeroMagnitude
                        )
                )
        )
        print("")
    }

    static func componentResolutionMeasure(
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

    static func printComponentResolutionSummary(
        name: String,
        summary: ComponentResolutionSummary
    ) {
        print(
            "  \(name)_seconds_per_operation_min: "
                + componentResolutionSeconds(
                    summary.minimum
                )
        )
        print(
            "  \(name)_seconds_per_operation_median: "
                + componentResolutionSeconds(
                    summary.median
                )
        )
        print(
            "  \(name)_seconds_per_operation_max: "
                + componentResolutionSeconds(
                    summary.maximum
                )
        )
    }

    static func componentResolutionSeconds(
        _ value: Double
    ) -> String {
        String(
            format: "%.9f",
            value
        )
    }

    static func componentResolutionRatio(
        _ value: Double
    ) -> String {
        String(
            format: "%.3f",
            value
        )
    }
}
