import Foundation
import PackagePlugin

@main
struct Plugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: Array<String>) throws {
        var options: ArgumentExtractor = ArgumentExtractor(arguments)
        let configurations: Array<String> = options.extractOption(named: "configuration")
        let products: Array<String> = options.extractOption(named: "product")
        let targets: Array<String> = options.extractOption(named: "target")
        let extensions: Array<String> = options.extractOption(named: "extension")
        let plists: Array<String> = options.extractOption(named: "info-plist")
        let resourcePaths: Array<String> = options.extractOption(named: "resources")
        let verifiers: Array<String> = options.extractOption(named: "verify")
        guard configurations.count <= 1, products.count <= 1, targets.count <= 1, extensions.count <= 1,
            plists.count <= 1, resourcePaths.count <= 1,
            let configuration: PackageManager.BuildConfiguration = PackageManager.BuildConfiguration(
                rawValue: configurations.first ?? "release"),
            configuration != PackageManager.BuildConfiguration.inherit,
            options.remainingArguments.isEmpty
        else {
            throw Error(message: "Usage: swift package build-bundle [--product name] [--target name] [--extension bundle] [--configuration release|debug] [--info-plist Info.plist] [--resources Resources] [--verify executable-product]...")
        }
        let product: String
        if let name: String = products.first {
            product = name
        } else if let target: String = targets.first {
            let candidates: Array<LibraryProduct> = context.package.products.compactMap {
                $0 as? LibraryProduct
            }.filter { $0.kind == .static && $0.targets.contains { $0.name == target } }
            guard let selected: LibraryProduct = candidates.first(where: { $0.name == target })
                ?? (candidates.count == 1 ? candidates.first : nil)
            else { throw Error(message: "Cannot select a unique static library product for target \(target); specify --product") }
            product = selected.name
        } else {
            product = context.package.displayName
        }
        let suffix: String = extensions.first ?? "bundle"
        let plist: URL = try infoPlist(in: context.package, product: product, path: plists.first)
        let metadata: Any = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), options: [], format: nil)
        guard let properties: Dictionary<String, Any> = metadata as? Dictionary<String, Any>,
            let name: String = properties["CFBundleExecutable"] as? String,
            let identifier: String = properties["CFBundleIdentifier"] as? String,
            !identifier.isEmpty, !name.isEmpty, name != ".", name != "..", !name.contains("/"),
            !suffix.isEmpty, suffix != ".", suffix != "..", !suffix.contains("/")
        else {
            throw Error(message: "Info.plist must contain CFBundleExecutable and CFBundleIdentifier; executable and extension must be path components")
        }

        let parameters: PackageManager.BuildParameters = PackageManager.BuildParameters(
            configuration: configuration, echoLogs: true)
        let subset: PackageManager.BuildSubset = PackageManager.BuildSubset.product(product)
        let build: PackageManager.BuildResult = try packageManager.build(subset, parameters: parameters)
        guard build.succeeded else { throw Error(message: build.logText) }
        let inputs: Array<String> = try linkInputs(product, in: context.package, build: build)

        let files: FileManager = FileManager.default
        // Xcode may use its active configuration rather than the requested one.
        let builtConfiguration: String = build.builtArtifacts.first?.url
            .deletingLastPathComponent().lastPathComponent.lowercased() ?? ""
        let outputConfiguration: String = ["debug", "release"].contains(builtConfiguration)
            ? builtConfiguration : configuration.rawValue
        let directory: URL = context.pluginWorkDirectoryURL.appendingPathComponent(outputConfiguration)
        let bundle: URL = directory.appendingPathComponent("\(name).\(suffix)")
        let staging: URL = directory.appendingPathComponent(".\(name)-\(UUID().uuidString).\(suffix)")
        let macOS: URL = staging.appendingPathComponent("Contents/MacOS")
        let executable: URL = macOS.appendingPathComponent(name)
        try files.createDirectory(at: macOS, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        // Link the package code as MH_BUNDLE, preserving the exported C factory.
        let swiftc: URL = try context.tool(named: "swiftc").url
        let xcrun: URL = try context.tool(named: "xcrun").url
        let sdkOutput: Pipe = Pipe()
        let sdkQuery: Process = Process()
        sdkQuery.executableURL = xcrun
        sdkQuery.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        sdkQuery.standardOutput = sdkOutput
        try sdkQuery.run()
        let sdk: String = String(decoding: sdkOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sdkQuery.waitUntilExit()
        guard sdkQuery.terminationStatus == 0, !sdk.isEmpty else { throw Error(message: "Cannot locate macOS SDK") }
        try run(swiftc, arguments: [
            "-sdk", sdk, "-emit-executable", "-Xlinker", "-bundle", "-Xlinker", "-all_load",
        ] + inputs + ["-o", executable.path])
        try files.copyItem(at: plist, to: staging.appendingPathComponent("Contents/Info.plist"))
        let resources: URL = context.package.directoryURL.appendingPathComponent(resourcePaths.first ?? "Resources")
        if files.fileExists(atPath: resources.path) {
            try files.copyItem(at: resources, to: staging.appendingPathComponent("Contents/Resources"))
        } else if !resourcePaths.isEmpty {
            throw Error(message: "Resources directory does not exist: \(resources.path)")
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
            guard verification.succeeded else { throw Error(message: verification.logText) }
            try run(artifact(verifier, in: verification), arguments: [bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).path])
        }
    }

    func linkInputs(_ name: String, in package: Package, build: PackageManager.BuildResult) throws -> Array<String> {
        let files: FileManager = .default
        if let archive = build.builtArtifacts.first(where: {
            $0.url.lastPathComponent == "lib\(name).a" && files.fileExists(atPath: $0.url.path)
        }) { return [archive.url.path] }

        // Xcode reports an executable placeholder for package libraries, but
        // emits one merged .o per module. Link only this product's dependencies.
        guard let product = package.products.first(where: { $0.name == name }),
              !build.builtArtifacts.isEmpty else { throw Error(message: "Build returned no artifacts for \(name)") }
        let directories: Array<URL> = build.builtArtifacts.map { $0.url.deletingLastPathComponent() }
        var pending: Array<any Target> = product.targets
        var visited: Set<String> = []
        var inputs: Array<String> = []
        while let target = pending.popLast() {
            guard visited.insert(target.id).inserted else { continue }
            guard let module = target as? any SourceModuleTarget else {
                throw Error(message: "Xcode object linking does not support target \(target.name)")
            }
            let candidates: Array<URL> = directories.map { $0.appendingPathComponent("\(module.moduleName).o") }
            guard let object = candidates.first(where: { files.fileExists(atPath: $0.path) }) else {
                throw Error(message: "Missing Xcode object for \(target.name): \(candidates.map(\.path).joined(separator: "; "))")
            }
            inputs.append(object.path)
            for library in module.linkedLibraries { inputs.append("-l" + library) }
            for framework in module.linkedFrameworks { inputs += ["-framework", framework] }
            for dependency in target.dependencies {
                switch dependency {
                case .target(let target): pending.append(target)
                case .product(let product):
                    guard let library = product as? LibraryProduct, library.kind != .dynamic else {
                        throw Error(message: "Xcode object linking requires static dependencies: \(product.name)")
                    }
                    pending += product.targets
                @unknown default:
                    throw Error(message: "Unsupported target dependency for \(target.name)")
                }
            }
        }
        return inputs
    }

    @inlinable
    @_transparent
    func infoPlist(in package: Package, product name: String, path: String?) throws -> URL {
        if let path: String = path {
            return package.directoryURL.appendingPathComponent(path)
        }
        guard let product: any Product = package.products.first(where: { $0.name == name }) else {
            throw Error(message: "No product named \(name)")
        }
        let candidates: Array<URL> = product.targets.map {
            $0.directoryURL.appendingPathComponent("Info.plist")
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard candidates.count <= 1 else {
            throw Error(message: "Multiple target Info.plist files for \(name); select one with --info-plist")
        }
        if let candidate: URL = candidates.first { return candidate }
        let fallback: URL = package.directoryURL.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw Error(message: "No Info.plist in targets of \(name) or the package root; specify --info-plist")
        }
        return fallback
    }

    @inlinable
    @_transparent
    func artifact(_ name: String, in build: PackageManager.BuildResult) throws -> URL {
        guard let artifact: PackageManager.BuildResult.BuiltArtifact = build.builtArtifacts.first(where: {
            $0.url.lastPathComponent == name
        }) else {
            let returned: String = build.builtArtifacts.map { String(describing: $0.kind) + ": " + $0.url.path }.joined(separator: "; ")
            throw Error(message: "Build did not return \(name). Artifacts: \(returned)")
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
            throw Error(message: "\(executable.lastPathComponent) exited with status \(process.terminationStatus)")
        }
    }
}

@usableFromInline
struct Error: Swift.Error, CustomStringConvertible {
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
extension Error: ExpressibleByStringLiteral {
    @inlinable
    @_transparent
    init(stringLiteral value: StringLiteralType) {
        self.init(message: value)
    }
    @inlinable
    @_transparent
    init(unicodeScalarLiteral value: String) {
        self.init(message: value)
    }
    @inlinable
    @_transparent
    init(extendedGraphemeClusterLiteral value: String) {
        self.init(message: value)
    }
}
