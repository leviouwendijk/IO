import TestIO

try TestIO.runStream(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
