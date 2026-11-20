import TestIO

try TestIO.runFile(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)
