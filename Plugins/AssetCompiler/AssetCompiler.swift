import PackagePlugin

@main
struct AssetCompiler: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else {
            return []
        }
        
        var commands: [Command] = []
        
        for sourceFile in target.sourceFiles where sourceFile.url.pathExtension == "codeasset" {
            let outputFile = context.pluginWorkDirectoryURL
                .appending(component: "\(sourceFile.url.lastPathComponent).swift")
            let contentFile = context.pluginWorkDirectoryURL
                .appending(component: "\(sourceFile.url.lastPathComponent).content.swift")
            
            commands.append(
                .buildCommand(
                    displayName: "Compiling asset \(sourceFile.url.lastPathComponent)",
                    executable: try context.tool(named: "AssetCompilerTool").url,
                    arguments: [
                        sourceFile.url.relativePath,
                        outputFile.relativePath,
                        contentFile.relativePath,
                    ],
                    environment: [:],
                    inputFiles: [sourceFile.url],
                    outputFiles: [outputFile, contentFile]
                )
            )
        }
        
        return commands
    }
}
