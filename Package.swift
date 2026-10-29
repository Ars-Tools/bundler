// swift-tools-version: 6.4
import PackageDescription

let package: Package = Package(
    name: "Bundler",
    products: [
        .plugin(
            name: "Builder",
            targets: ["Builder"]
        ),
    ],
    targets: [
        .plugin(
            name: "Builder",
            capability: Target.PluginCapability.command(intent: PluginCommandIntent.custom(verb: "build-bundle", description: "Build and sign a macOS loadable bundle")),
            path: "."
        ),
    ]
)
