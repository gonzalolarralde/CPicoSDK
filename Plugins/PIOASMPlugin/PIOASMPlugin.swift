import Foundation
import PackagePlugin

@main
struct PrepareEnvironmentPlugin: BuildToolPlugin {
    func createBuildCommands(context: PackagePlugin.PluginContext, target: any PackagePlugin.Target) async throws -> [PackagePlugin.Command] {
        try target.sourceModule?.sourceFiles
            .filter { $0.url.pathExtension == "pio" }
            .flatMap { file in
                let swiftOutput = context.pluginWorkDirectoryURL.appending(path: file.url.lastPathComponent.appending(".swift"))
                
                return [
                    PackagePlugin.Command
                        .buildCommand(
                            displayName: "pioasm-swift",
                            executable: try context.tool(named: "pioasm-swift").url,
                            arguments: [
                                try context.tool(named: "pioasm").url.relativePath,
                                file.url.relativePath,
                                swiftOutput.relativePath
                            ],
                            environment: [:],
                            inputFiles: [file.url],
                            outputFiles: [swiftOutput]
                        ),
                ]
            } ?? []
    }
}
