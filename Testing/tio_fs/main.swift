import TestIO

try TestIO.runFS(
    arguments: Array(
        CommandLine.arguments.dropFirst()
    )
)