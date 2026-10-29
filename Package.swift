// swift-tools-version: 6.4
import PackageDescription

let package: Package = Package(
    name: "BundleBuilder",
    products: [
        Product.plugin(name: "BuildBundle", targets: ["BuildBundle"]),
    ],
    targets: [
        Target.plugin(name: "BuildBundle", capability: Target.PluginCapability.command(
            intent: PluginCommandIntent.custom(verb: "build-bundle", description: "Build and sign a macOS loadable bundle"))),
    ]
)
