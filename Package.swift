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
            capability: Target.PluginCapability.command(intent: PluginCommandIntent.custom(verb: "build-bundle", description: "Build macOS bundles and iOS apps with widgets")),
            path: ".",
            exclude: ["Checks"]
        ),
    ]
)
