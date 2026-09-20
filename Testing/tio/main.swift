import TestIO

try TestIO.runAll(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
