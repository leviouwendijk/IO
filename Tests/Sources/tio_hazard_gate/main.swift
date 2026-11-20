import TestIO

try await TestIO.runHazardGate(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
