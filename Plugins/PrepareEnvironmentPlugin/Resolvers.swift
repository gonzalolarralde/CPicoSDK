import PackagePlugin

extension PrepareEnvironmentPlugin {
    func resolveProductToBuild(context: PackagePlugin.PluginContext) -> LibraryProduct? {
        let libraryProducts = context.package
            .products(ofType: LibraryProduct.self)
            .filter { $0.kind == .static }
            .filter { product in
                product.targets.contains(where: { target in
                    target.dependencies.contains(where: { dependency in
                        if case let .product(product) = dependency, product.name == "CPicoSDK" {
                            return true
                        } else {
                            return false
                        }
                    })
                })
            }
                
        if libraryProducts.count > 1 {
            print("[CPicoSDK] Warning: More than one static library product depends on CPicoSDK. Multiple targets are not yet supported. Using the first one found: \(libraryProducts.first?.name ?? "unknown"). All targets: [\(libraryProducts.map(\.name).joined(separator: ", "))]")
        }

        return libraryProducts.first
    }

    func resolve(envVars: [String: String]) -> [String: String] {
        var resolvedEnvVars = envVars

        var iterations = 10
        let regex = /\$\{(.*?)\}/

        var varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
        repeat {
            for (key, value) in varsToResolve {
                resolvedEnvVars[key] = value.replacing(regex) { match in
                    if let replacement = resolvedEnvVars[String(match.1)] {
                        replacement
                    } else {
                        String(match.0)
                    }
                }
            }
            varsToResolve = resolvedEnvVars.filter { $0.value.contains("$") }
            iterations -= 1
        } while iterations > 0 && varsToResolve.count > 0

        if varsToResolve.count > 0 {
            let unresolvedVars = varsToResolve.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            fatalError("[CPicoSDK] Couldn't resolve all env variables. The only var replacement format accepted is ${VAR}. Remaining: [\(unresolvedVars)]")
        }

        return resolvedEnvVars
    }
}