import TestIO

try TestIO.runScan(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
