public extension DirectoryInspector {
    func isEmpty() throws -> Bool {
        try fileSystem
            .directory
            .contents(
                url
            )
            .isEmpty
    }
}
