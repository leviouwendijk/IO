import TestIO

try TestIO.runOverhead(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
