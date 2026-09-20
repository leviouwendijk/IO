import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native canonical path resolution.
///
/// The resolver is intentionally byte-oriented at the POSIX boundary:
/// - try the complete leaf with `readlink` first;
/// - follow leaf symlink chains without Foundation normalization;
/// - for ordinary leaves, walk components with `readlink` as the symlink classifier;
/// - resolve `.` / `..` only in filesystem order after preceding symlinks expand;
/// - preserve FileSystem's nonthrowing fallback by returning the standardized original
///   path whenever complete resolution fails.
///
/// The R0h benchmark/semantic suite selected this shape over Foundation's
/// `resolvingSymlinksInPath` on the characterized macOS workload.
enum NativeFileSystemResolution {
    static let rdSlash =
        CChar(47)
    static let rdDot =
        CChar(46)
    static let rdSymlinkLimit =
        40

    static func resolve(
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
                target in

                guard let targetBase =
                    target.baseAddress
                else {
                    return input.standardizedFileURL
                }

                let targetCount =
                    readlink(
                        pointer,
                        targetBase,
                        target.count - 1
                    )

                if targetCount >= 0 {
                    target[targetCount] = 0

                    return rdResolveLeafSymlink(
                        input,
                        source: pointer,
                        firstTarget: target
                    )
                }

                guard errno == EINVAL else {
                    return input.standardizedFileURL
                }

                return rdComponentWalk(
                    input,
                    pointer: pointer,
                    finalLeafKnownNonSymlink: true
                )
            }
        }
    }

    static func rdResolveLeafSymlink(
        _ input: URL,
        source: UnsafePointer<CChar>,
        firstTarget: UnsafeMutableBufferPointer<CChar>
    ) -> URL {
        withUnsafeTemporaryAllocation(
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

                    guard rdComposeSymlinkTarget(
                        current: source,
                        target: firstTarget,
                        into: current
                    )
                    else {
                        return input.standardizedFileURL
                    }

                    var followedLinks = 1

                    while true {
                        guard followedLinks
                                <= rdSymlinkLimit,
                              let currentBase =
                                current.baseAddress,
                              let targetBase =
                                target.baseAddress
                        else {
                            return input.standardizedFileURL
                        }

                        if followedLinks > 1,
                           strcmp(
                            currentBase,
                            source
                           ) == 0
                        {
                            return input.standardizedFileURL
                        }

                        let targetCount =
                            readlink(
                                currentBase,
                                targetBase,
                                target.count - 1
                            )

                        if targetCount < 0 {
                            guard errno == EINVAL else {
                                return input.standardizedFileURL
                            }

                            return rdComponentWalk(
                                input,
                                pointer: currentBase,
                                finalLeafKnownNonSymlink: true
                            )
                        }

                        target[targetCount] = 0
                        followedLinks += 1

                        guard followedLinks
                                <= rdSymlinkLimit,
                              rdComposeSymlinkTarget(
                                current: currentBase,
                                target: target,
                                into: scratch
                              ),
                              let scratchBase =
                                scratch.baseAddress,
                              rdCopyCString(
                                scratchBase,
                                into: current
                              )
                        else {
                            return input.standardizedFileURL
                        }
                    }
                }
            }
        }
    }

    static func rdComponentWalk(
        _ input: URL,
        pointer: UnsafePointer<CChar>,
        finalLeafKnownNonSymlink: Bool
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

                        guard rdCopyCString(
                            pointer,
                            into: workA
                        ),
                        !resolved.isEmpty
                        else {
                            return input.standardizedFileURL
                        }

                        resolved[0] = rdSlash

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
                                    == rdSlash
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
                                    != rdSlash
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
                                == rdDot
                            {
                                continue
                            }

                            if componentLength == 2,
                               pending[componentStart]
                                    == rdDot,
                               pending[
                                componentStart + 1
                               ] == rdDot
                            {
                                rdPopResolvedComponent(
                                    resolved,
                                    length:
                                        &resolvedLength
                                )
                                continue
                            }

                            guard rdAppendComponent(
                                from: pending,
                                range:
                                    componentStart..<componentEnd,
                                to: resolved,
                                length:
                                    &resolvedLength
                            ),
                            let resolvedBase =
                                resolved.baseAddress,
                            let targetBase =
                                target.baseAddress
                            else {
                                return input.standardizedFileURL
                            }

                            let isFinal =
                                rdRemainderIsEmpty(
                                    pending,
                                    from: componentEnd
                                )

                            if isFinal,
                               finalLeafKnownNonSymlink
                            {
                                continue
                            }

                            let targetCount =
                                readlink(
                                    resolvedBase,
                                    targetBase,
                                    target.count - 1
                                )

                            if targetCount < 0 {
                                guard errno == EINVAL else {
                                    return input.standardizedFileURL
                                }

                                continue
                            }

                            followedLinks += 1

                            guard followedLinks
                                    <= rdSymlinkLimit,
                                  targetCount
                                    < target.count
                            else {
                                return input.standardizedFileURL
                            }

                            target[targetCount] = 0

                            let parentLength =
                                rdParentLength(
                                    resolved,
                                    length:
                                        resolvedLength
                                )

                            resolvedLength =
                                parentLength
                            resolved[
                                resolvedLength
                            ] = 0

                            if targetBase[0]
                                == rdSlash
                            {
                                resolvedLength = 1
                                resolved[0] =
                                    rdSlash
                                resolved[1] = 0
                            }

                            let nextPending =
                                pendingIsA
                                ? workB
                                : workA

                            guard rdComposePending(
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

    static func rdComposeSymlinkTarget(
        current: UnsafePointer<CChar>,
        target: UnsafeMutableBufferPointer<CChar>,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard let targetBase =
            target.baseAddress
        else {
            return false
        }

        if targetBase[0] == rdSlash {
            return rdCopyCString(
                targetBase,
                into: output
            )
        }

        let currentLength =
            rdCStringLength(
                current
            )

        guard currentLength > 0 else {
            return false
        }

        var lastSlash =
            currentLength - 1

        while lastSlash > 0,
              current[lastSlash]
                != rdSlash
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
                current[index]
        }

        var writeIndex =
            parentLength

        if writeIndex > 1 {
            guard writeIndex
                    < output.count - 1
            else {
                return false
            }

            output[writeIndex] =
                rdSlash
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

    static func rdNormalizeAbsolutePath(
        _ source: UnsafePointer<CChar>,
        into output: UnsafeMutableBufferPointer<CChar>
    ) -> Bool {
        guard source[0] == rdSlash,
              !output.isEmpty
        else {
            return false
        }

        output[0] = rdSlash

        var readIndex = 1
        var writeIndex = 1

        while source[readIndex] != 0 {
            while source[readIndex]
                    == rdSlash
            {
                readIndex += 1
            }

            guard source[readIndex] != 0 else {
                break
            }

            let start = readIndex

            while source[readIndex] != 0,
                  source[readIndex]
                    != rdSlash
            {
                readIndex += 1
            }

            let length =
                readIndex - start

            if length == 1,
               source[start] == rdDot
            {
                continue
            }

            if length == 2,
               source[start] == rdDot,
               source[start + 1] == rdDot
            {
                while writeIndex > 1,
                      output[writeIndex - 1]
                        != rdSlash
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
                    rdSlash
                writeIndex += 1
            }

            guard writeIndex
                    + length
                    < output.count
            else {
                return false
            }

            for offset in 0..<length {
                output[
                    writeIndex + offset
                ] = source[
                    start + offset
                ]
            }

            writeIndex += length
        }

        guard writeIndex
                < output.count
        else {
            return false
        }

        output[writeIndex] = 0
        return true
    }

    static func rdAppendComponent(
        from source: UnsafeMutableBufferPointer<CChar>,
        range: Range<Int>,
        to destination: UnsafeMutableBufferPointer<CChar>,
        length: inout Int
    ) -> Bool {
        if length > 1 {
            guard length
                    < destination.count - 1
            else {
                return false
            }

            destination[length] =
                rdSlash
            length += 1
        }

        guard length
                + range.count
                < destination.count
        else {
            return false
        }

        var outputIndex =
            length

        for sourceIndex in range {
            destination[outputIndex] =
                source[sourceIndex]
            outputIndex += 1
        }

        length = outputIndex
        destination[length] = 0
        return true
    }

    static func rdPopResolvedComponent(
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
                != rdSlash
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

    static func rdParentLength(
        _ path: UnsafeMutableBufferPointer<CChar>,
        length: Int
    ) -> Int {
        guard length > 1 else {
            return 1
        }

        var index =
            length

        while index > 1,
              path[index - 1]
                != rdSlash
        {
            index -= 1
        }

        return max(
            1,
            index - 1
        )
    }

    static func rdComposePending(
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
           output[outputIndex - 1]
            != rdSlash,
           current[remainderIndex]
            != rdSlash
        {
            guard outputIndex
                    < output.count - 1
            else {
                return false
            }

            output[outputIndex] =
                rdSlash
            outputIndex += 1
        }

        while current[remainderIndex] != 0 {
            guard outputIndex
                    < output.count - 1
            else {
                return false
            }

            output[outputIndex] =
                current[remainderIndex]
            outputIndex += 1
            remainderIndex += 1
        }

        output[outputIndex] = 0
        return true
    }

    static func rdRemainderIsEmpty(
        _ path: UnsafeMutableBufferPointer<CChar>,
        from index: Int
    ) -> Bool {
        var cursor = index

        while path[cursor] == rdSlash {
            cursor += 1
        }

        return path[cursor] == 0
    }

    static func rdCopyCString(
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

    static func rdCStringLength(
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
                        == rdSlash
            else {
                continue
            }

            let remainder =
                baseAddress.advanced(
                    by: 8
                )
            let byteCount =
                rdCStringLength(
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

}
