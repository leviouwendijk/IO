import TestIO

try await TestIO.runExecution(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
