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

}
