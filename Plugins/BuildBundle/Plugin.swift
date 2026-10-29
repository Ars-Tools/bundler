import Foundation
import PackagePlugin

@main
struct BuildBundle: CommandPlugin {
    func performCommand(context: PluginContext, arguments: Array<String>) throws {
        var options: ArgumentExtractor = ArgumentExtractor(arguments)
        let configurations: Array<String> = options.extractOption(named: "configuration")
        let products: Array<String> = options.extractOption(named: "product")
        let extensions: Array<String> = options.extractOption(named: "extension")
        let plists: Array<String> = options.extractOption(named: "info-plist")
        let resourcePaths: Array<String> = options.extractOption(named: "resources")
        let verifiers: Array<String> = options.extractOption(named: "verify")
        guard configurations.count <= 1, products.count <= 1, extensions.count <= 1,
            plists.count <= 1, resourcePaths.count <= 1,
            let configuration: PackageManager.BuildConfiguration = PackageManager.BuildConfiguration(
                rawValue: configurations.first ?? "release"),
            configuration != PackageManager.BuildConfiguration.inherit,
            options.remainingArguments.isEmpty
        else {
            throw BundleBuildError(message: "Usage: swift package build-bundle [--product name] [--extension bundle] [--configuration release|debug] [--info-plist Info.plist] [--resources Resources] [--verify executable-product]...")
        }
        let product: String = products.first ?? context.package.displayName
        let suffix: String = extensions.first ?? "bundle"
        let plist: URL = context.package.directoryURL.appendingPathComponent(plists.first ?? "Info.plist")
        let metadata: Any = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil)
        guard let properties: Dictionary<String, Any> = metadata as? Dictionary<String, Any>,
            let name: String = properties["CFBundleExecutable"] as? String,
            let identifier: String = properties["CFBundleIdentifier"] as? String,
            !identifier.isEmpty, !name.isEmpty, name != ".", name != "..", !name.contains("/"),
            !suffix.isEmpty, suffix != ".", suffix != "..", !suffix.contains("/")
        else {
            throw BundleBuildError(message: "Info.plist must contain CFBundleExecutable and CFBundleIdentifier; executable and extension must be path components")
        }

        let parameters: PackageManager.BuildParameters = PackageManager.BuildParameters(
            configuration: configuration, echoLogs: true)
        let subset: PackageManager.BuildSubset = PackageManager.BuildSubset.product(product)
        let build: PackageManager.BuildResult = try packageManager.build(subset, parameters: parameters)
        guard build.succeeded else { throw BundleBuildError(message: build.logText) }
        let archive: URL = try artifact("lib\(product).a", in: build)

        let files: FileManager = FileManager.default
        let directory: URL = context.pluginWorkDirectoryURL.appendingPathComponent(configuration.rawValue)
        let bundle: URL = directory.appendingPathComponent("\(name).\(suffix)")
        let staging: URL = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).\(suffix)")
        let macOS: URL = staging.appendingPathComponent("Contents/MacOS")
        let executable: URL = macOS.appendingPathComponent(name)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        // Link the package archive as MH_BUNDLE, preserving the exported C factory.
        let swiftc: URL = try context.tool(named: "swiftc").url
        try run(swiftc, arguments: [
            "-emit-executable", "-Xlinker", "-bundle", "-Xlinker", "-all_load",
            archive.path, "-o", executable.path,
        ])
        try files.copyItem(at: plist, to: staging.appendingPathComponent("Contents/Info.plist"))
        let resources: URL = context.package.directoryURL.appendingPathComponent(resourcePaths.first ?? "Resources")
        if files.fileExists(atPath: resources.path) {
            try files.copyItem(at: resources, to: staging.appendingPathComponent("Contents/Resources"))
        } else if !resourcePaths.isEmpty {
            throw BundleBuildError(message: "Resources directory does not exist: \(resources.path)")
        }

        let codesign: URL = try context.tool(named: "codesign").url
        try run(codesign, arguments: [
            "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier, staging.path,
        ])
        try run(codesign, arguments: ["--verify", "--strict", staging.path])
        if files.fileExists(atPath: bundle.path) { try files.removeItem(at: bundle) }
        try files.moveItem(at: staging, to: bundle)
        print("Bundle: \(bundle.path)")

        for verifier: String in verifiers {
            let verification: PackageManager.BuildResult = try packageManager.build(
                PackageManager.BuildSubset.product(verifier), parameters: parameters)
            guard verification.succeeded else { throw BundleBuildError(message: verification.logText) }
            try run(artifact(verifier, in: verification), arguments: [bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).path])
        }
    }

    @inlinable
    @_transparent
    func artifact(_ name: String, in build: PackageManager.BuildResult) throws -> URL {
        guard let artifact: PackageManager.BuildResult.BuiltArtifact = build.builtArtifacts.first(where: {
            $0.url.lastPathComponent == name
        }) else {
            throw BundleBuildError(message: "Build did not return \(name)")
        }
        return artifact.url
    }

    @inlinable
    @_transparent
    func run(_ executable: URL, arguments: Array<String>) throws {
        let process: Process = try Process.run(executable, arguments: arguments)
        process.waitUntilExit()
        guard process.terminationReason == Process.TerminationReason.exit,
            process.terminationStatus == 0
        else {
            throw BundleBuildError(message: "\(executable.lastPathComponent) exited with status \(process.terminationStatus)")
        }
    }
}

@usableFromInline
struct BundleBuildError: Error, CustomStringConvertible {
    @usableFromInline
    let message: String

    @inlinable
    @_transparent
    init(message: String) {
        self.message = message
    }

    @inlinable
    @_transparent
    var description: String { message }
}
