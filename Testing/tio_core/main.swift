import TestIO

try TestIO.runCore(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
