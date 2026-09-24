import TestIO

try await TestIO.runHazard(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
