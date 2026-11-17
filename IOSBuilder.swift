import Foundation
import PackagePlugin

// Xcode owns iOS bundle layout, extension embedding, asset compilation and
// App Intents extraction. SwiftPM remains the source/dependency manifest.
extension Plugin {
    func buildIOS(context: PluginContext, product: any Product, widgets: [String],
                  simulator: Bool, configuration: String, deployment: String, team: String?) throws {
        guard deployment.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw Error(message: "--deployment-target must be a version such as 17.0")
        }
        guard simulator || !(team ?? "").isEmpty else {
            throw Error(message: "Device builds require --development-team and installed signing credentials/profiles")
        }
        guard !widgets.contains(product.name) else { throw Error(message: "An app cannot embed itself as a widget") }
        let selected = try ([product.name] + widgets).map { name -> ExecutableProduct in
            guard let item = context.package.products.first(where: { $0.name == name }) as? ExecutableProduct,
                  item.mainTarget is SwiftSourceModuleTarget else {
                throw Error(message: "iOS app and widget products must be Swift executables: \(name)")
            }
            return item
        }
        // The generated app embeds extensions, but not dependency frameworks.
        // Reject explicit dynamic libraries anywhere in the runtime graph rather
        // than publishing an app that fails to load them on launch.
        var dependencyTargets: [any Target] = selected.map(\.mainTarget)
        var checkedTargets = Set<String>()
        while let target = dependencyTargets.popLast() {
            guard checkedTargets.insert(target.id).inserted else { continue }
            for dependency in target.dependencies {
                switch dependency {
                case .target(let target): dependencyTargets.append(target)
                case .product(let product):
                    if let library = product as? LibraryProduct, library.kind == .dynamic {
                        throw Error(message: "iOS bundling does not embed dynamic dependency frameworks: \(product.name)")
                    }
                    dependencyTargets += product.targets
                @unknown default: throw Error(message: "Unsupported iOS dependency")
                }
            }
        }
        let files = FileManager.default
        let platform = simulator ? "ios-simulator" : "ios"
        let work = context.pluginWorkDirectoryURL.appendingPathComponent(platform).appendingPathComponent(configuration)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        // Generate into a fresh directory; failed builds never replace the last app.
        let job = work.appendingPathComponent("Build-" + UUID().uuidString)
        try files.createDirectory(at: job, withIntermediateDirectories: true)
        var succeeded = false
        defer { if succeeded { try? files.removeItem(at: job) } }
        let project = PBXProjectWriter()
        let mainGroup = project.add(["isa": "PBXGroup", "children": [String](), "sourceTree": "<group>"])
        let productsGroup = project.add(["isa": "PBXGroup", "name": "Products", "children": [String](), "sourceTree": "<group>"])
        var targets = [String]()
        var productRefs = [String]()
        var identifiers = Set<String>()
        var outputNames = Set<String>()
        var appIdentifier = ""
        var appName = ""
        var packageReferences = [String: String]()
        var allPackages = [context.package]
        var pending = context.package.dependencies.map(\.package)
        while let package = pending.popLast() {
            if !allPackages.contains(where: { $0.id == package.id }) {
                allPackages.append(package)
                pending += package.dependencies.map(\.package)
            }
        }

        for (index, item) in selected.enumerated() {
            let isWidget = index > 0
            let module = item.mainTarget as! SwiftSourceModuleTarget
            guard module.pluginGeneratedSources.isEmpty, module.pluginGeneratedResources.isEmpty else {
                throw Error(message: "iOS entry targets cannot use generated sources/resources; move build plugins into a library dependency")
            }
            let plistURL = try infoPlist(in: context.package, product: item.name, path: nil)
            guard var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
                  let name = plist["CFBundleExecutable"] as? String, validIOSName(name),
                  let identifier = plist["CFBundleIdentifier"] as? String,
                  identifier.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil else {
                throw Error(message: "iOS Info.plist needs a literal CFBundleExecutable (letters, digits, underscore or hyphen) and reverse-DNS CFBundleIdentifier")
            }
            guard identifiers.insert(identifier).inserted, outputNames.insert(name).inserted else {
                throw Error(message: "App and widget executable names and bundle identifiers must be unique")
            }
            if isWidget {
                guard identifier.hasPrefix(appIdentifier + "."),
                      let ext = plist["NSExtension"] as? [String: Any],
                      ext["NSExtensionPointIdentifier"] as? String == "com.apple.widgetkit-extension",
                      ext["NSExtensionPrincipalClass"] == nil, ext["NSExtensionMainStoryboard"] == nil else {
                    throw Error(message: "Widget Info.plist must use an app-prefixed bundle ID and NSExtensionPointIdentifier = com.apple.widgetkit-extension without principal class/storyboard")
                }
            } else {
                appIdentifier = identifier
                appName = name
                guard plist["NSExtension"] == nil else { throw Error(message: "An app Info.plist cannot declare NSExtension") }
            }
            let packageType = isWidget ? "XPC!" : "APPL"
            if let declared = plist["CFBundlePackageType"] as? String, declared != packageType {
                throw Error(message: "\(item.name) must declare CFBundlePackageType = \(packageType)")
            }
            plist["CFBundlePackageType"] = packageType
            plist["CFBundleName"] = plist["CFBundleName"] ?? name
            plist["CFBundleVersion"] = plist["CFBundleVersion"] ?? "1"
            plist["CFBundleShortVersionString"] = plist["CFBundleShortVersionString"] ?? "1.0"
            if !isWidget {
                plist["UILaunchScreen"] = plist["UILaunchScreen"] ?? [String: Any]()
                plist["UISupportedInterfaceOrientations"] = plist["UISupportedInterfaceOrientations"] ?? ["UIInterfaceOrientationPortrait"]
            }
            let generatedPlist = job.appendingPathComponent("\(index)-Info.plist")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: generatedPlist)
            var sourceBuildFiles = [String]()
            let sources = module.sourceFiles.filter { $0.type == .source }
            guard !sources.isEmpty, sources.allSatisfy({ $0.url.pathExtension == "swift" }) else {
                throw Error(message: "iOS entry targets must contain Swift source files")
            }
            for source in sources {
                let ref = project.file(source.url, type: "sourcecode.swift")
                sourceBuildFiles.append(project.add(["isa": "PBXBuildFile", "fileRef": ref]))
            }
            // Resources belong to the native bundle, not a separate SwiftPM
            // resource bundle. Dependency library resources remain SwiftPM-owned.
            let resourceRoot = module.directoryURL.appendingPathComponent("Resources")
            var resourceBuildFiles = [String]()
            if files.fileExists(atPath: resourceRoot.path) {
                let resources = try files.contentsOfDirectory(at: resourceRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                for resource in resources.sorted(by: { $0.path < $1.path }) {
                    let directory = (try resource.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
                    guard !["Info.plist", "Entitlements.plist", "_CodeSignature", "PlugIns", "Frameworks"].contains(resource.lastPathComponent),
                          resource.lastPathComponent != name, resource.pathExtension != "lproj" else {
                        throw Error(message: "Unsupported or reserved entry in iOS Resources: \(resource.lastPathComponent)")
                    }
                    let type = resource.pathExtension == "xcassets" ? "folder.assetcatalog" : (directory ? "folder" : "file")
                    let ref = project.file(resource, type: type)
                    resourceBuildFiles.append(project.add(["isa": "PBXBuildFile", "fileRef": ref]))
                }
            }
            // Match the API entry-target sources use under SwiftPM.
            if !resourceBuildFiles.isEmpty {
                let accessor = job.appendingPathComponent("\(index)-Bundle.swift")
                try """
                import Foundation
                private final class BundlerResourceMarker {}
                extension Foundation.Bundle {
                    static let module = Bundle(for: BundlerResourceMarker.self)
                }
                """.write(to: accessor, atomically: true, encoding: .utf8)
                sourceBuildFiles.append(project.add(["isa": "PBXBuildFile", "fileRef": project.file(accessor, type: "sourcecode.swift")]))
            }
            var productDependencies = [String]()
            var frameworkFiles = [String]()
            var seenDependencies = Set<String>()
            for dependency in module.dependencies {
                let library: LibraryProduct
                let owner: Package
                switch dependency {
                case .target(let target):
                    let candidates = context.package.products.compactMap { $0 as? LibraryProduct }.filter {
                        $0.targets.count == 1 && $0.targets.first?.id == target.id && $0.kind != .dynamic
                    }
                    guard let match = candidates.first else {
                        throw Error(message: "Export local dependency \(target.name) as a single-target automatic/static library product for iOS bundling")
                    }
                    library = match
                    owner = context.package
                case .product(let dependencyProduct):
                    guard let match = dependencyProduct as? LibraryProduct, match.kind != .dynamic,
                          let package = allPackages.first(where: { $0.products.contains(where: { $0.id == dependencyProduct.id }) }) else {
                        throw Error(message: "iOS entry targets require automatic/static library dependencies: \(dependencyProduct.name)")
                    }
                    library = match
                    owner = package
                @unknown default: throw Error(message: "Unsupported iOS dependency")
                }
                guard seenDependencies.insert(library.id).inserted else { continue }
                let reference: String
                if let existing = packageReferences[owner.id] { reference = existing } else {
                    reference = project.add(["isa": "XCLocalSwiftPackageReference", "relativePath": owner.directoryURL.path])
                    packageReferences[owner.id] = reference
                }
                let dep = project.add(["isa": "XCSwiftPackageProductDependency", "package": reference, "productName": library.name])
                productDependencies.append(dep)
                frameworkFiles.append(project.add(["isa": "PBXBuildFile", "productRef": dep]))
            }
            let sourcePhase = project.phase("PBXSourcesBuildPhase", files: sourceBuildFiles)
            let resourcePhase = project.phase("PBXResourcesBuildPhase", files: resourceBuildFiles)
            let frameworkPhase = project.phase("PBXFrameworksBuildPhase", files: frameworkFiles)
            let productRef = project.add(["isa": "PBXFileReference", "explicitFileType": isWidget ? "wrapper.app-extension" : "wrapper.application",
                                          "path": name + (isWidget ? ".appex" : ".app"), "sourceTree": "BUILT_PRODUCTS_DIR"])
            productRefs.append(productRef)
            var settings: [String: Any] = [
                "PRODUCT_NAME": name, "PRODUCT_MODULE_NAME": module.moduleName,
                "PRODUCT_BUNDLE_IDENTIFIER": identifier, "INFOPLIST_FILE": generatedPlist.path,
                "GENERATE_INFOPLIST_FILE": "NO", "IPHONEOS_DEPLOYMENT_TARGET": deployment,
                "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "TARGETED_DEVICE_FAMILY": "1,2",
                "SDKROOT": "iphoneos", "SWIFT_VERSION": "6.0", "CLANG_ENABLE_MODULES": "YES",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": (["$(inherited)", "SWIFT_PACKAGE"] + module.compilationConditions).joined(separator: " "),
                "OTHER_SWIFT_FLAGS": ["$(inherited)", "-parse-as-library"],
                "OTHER_LDFLAGS": ["$(inherited)"] + module.linkedLibraries.map { "-l" + $0 } + module.linkedFrameworks.flatMap { ["-framework", $0] },
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
                "SKIP_INSTALL": isWidget ? "YES" : "NO", "APPLICATION_EXTENSION_API_ONLY": isWidget ? "YES" : "NO",
                "CODE_SIGN_STYLE": "Automatic", "CODE_SIGNING_ALLOWED": "YES",
                "SWIFT_OPTIMIZATION_LEVEL": configuration == "debug" ? "-Onone" : "-O",
            ]
            if simulator { settings["CODE_SIGN_IDENTITY"] = "-" }
            if let team { settings["DEVELOPMENT_TEAM"] = team }
            let entitlements = module.directoryURL.appendingPathComponent("Entitlements.plist")
            if files.fileExists(atPath: entitlements.path) {
                _ = try PropertyListSerialization.propertyList(from: Data(contentsOf: entitlements), format: nil)
                settings["CODE_SIGN_ENTITLEMENTS"] = entitlements.path
            }
            let target = project.add(["isa": "PBXNativeTarget", "name": item.name, "productName": name,
                                      "productType": isWidget ? "com.apple.product-type.app-extension" : "com.apple.product-type.application",
                                      "productReference": productRef, "buildConfigurationList": project.configurations(settings),
                                      "buildPhases": [sourcePhase, frameworkPhase, resourcePhase], "buildRules": [String](),
                                      "dependencies": [String](), "packageProductDependencies": productDependencies])
            targets.append(target)
        }
        let embedFiles = productRefs.dropFirst().map {
            project.add(["isa": "PBXBuildFile", "fileRef": $0, "settings": ["ATTRIBUTES": ["RemoveHeadersOnCopy"]]])
        }
        if !embedFiles.isEmpty {
            let embed = project.add(["isa": "PBXCopyFilesBuildPhase", "buildActionMask": 2147483647,
                                     "dstPath": "", "dstSubfolderSpec": 13, "files": embedFiles,
                                     "name": "Embed App Extensions", "runOnlyForDeploymentPostprocessing": 0])
            let phases = project.objects[targets[0]]?["buildPhases"] as! [String]
            project.objects[targets[0]]?["buildPhases"] = phases + [embed]
        }
        let targetDependencies = targets.dropFirst().map {
            project.add(["isa": "PBXTargetDependency", "target": $0])
        }
        project.objects[targets[0]]?["dependencies"] = targetDependencies
        project.objects[productsGroup]?["children"] = productRefs
        project.objects[mainGroup]?["children"] = [productsGroup] + project.fileReferences
        let root = project.add(["isa": "PBXProject", "attributes": ["BuildIndependentTargetsInParallel": "YES"],
                                "buildConfigurationList": project.configurations([:]), "compatibilityVersion": "Xcode 14.0",
                                "developmentRegion": "en", "knownRegions": ["en", "Base"], "mainGroup": mainGroup,
                                "productRefGroup": productsGroup, "projectDirPath": "", "projectRoot": "",
                                "targets": targets, "packageReferences": packageReferences.values.sorted()])
        let xcodeProject = job.appendingPathComponent("Bundler.xcodeproj")
        try files.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
        try project.write(root: root, to: xcodeProject.appendingPathComponent("project.pbxproj"))
        // An explicit scheme avoids colliding with an executable scheme from
        // the local Swift package (often named exactly like the native app).
        let schemes = xcodeProject.appendingPathComponent("xcshareddata/xcschemes")
        try files.createDirectory(at: schemes, withIntermediateDirectories: true)
        let scheme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="1600" version="1.3">
          <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
            <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
              <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="\(targets[0])" BuildableName="\(appName).app" ReferencedContainer="container:Bundler.xcodeproj"/>
            </BuildActionEntry></BuildActionEntries>
          </BuildAction>
        </Scheme>
        """
        try scheme.write(to: schemes.appendingPathComponent("Bundler.xcscheme"), atomically: true, encoding: .utf8)
        let xcodebuild = try context.tool(named: "xcodebuild").url
        print("Project: \(xcodeProject.path)")
        let buildConfiguration = configuration == "debug" ? "Debug" : "Release"
        try run(xcodebuild, arguments: ["-project", xcodeProject.path, "-scheme", "Bundler",
                                       "-configuration", buildConfiguration, "-destination", simulator ? "generic/platform=iOS Simulator" : "generic/platform=iOS",
                                       "-derivedDataPath", work.appendingPathComponent("DerivedData").path,
                                       "-clonedSourcePackagesDirPath", work.appendingPathComponent("SourcePackages").path,
                                       "CONFIGURATION_BUILD_DIR=" + job.appendingPathComponent("Products").path,
                                       "build"])
        let builtApp = job.appendingPathComponent("Products/\(appName).app")
        guard files.fileExists(atPath: builtApp.appendingPathComponent("Info.plist").path) else {
            throw Error(message: "Xcode did not produce \(builtApp.path)")
        }
        let bundle = work.appendingPathComponent(appName + ".app")
        let staged = job.appendingPathComponent(appName + ".app")
        try files.copyItem(at: builtApp, to: staged)
        if files.fileExists(atPath: bundle.path) { try files.removeItem(at: bundle) }
        try files.moveItem(at: staged, to: bundle)
        succeeded = true
        print("Bundle: \(bundle.path)")
    }

    private func validIOSName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}

private final class PBXProjectWriter {
    var objects: [String: [String: Any]] = [:]
    var fileReferences = [String]()
    private var sequence = 0

    func add(_ object: [String: Any]) -> String {
        sequence += 1
        let id = String(format: "%024X", sequence)
        objects[id] = object
        return id
    }

    func file(_ url: URL, type: String) -> String {
        let id = add(["isa": "PBXFileReference", "lastKnownFileType": type, "path": url.path, "sourceTree": "<absolute>"])
        fileReferences.append(id)
        return id
    }

    func phase(_ isa: String, files: [String]) -> String {
        add(["isa": isa, "buildActionMask": 2147483647, "files": files, "runOnlyForDeploymentPostprocessing": 0])
    }

    func configurations(_ settings: [String: Any]) -> String {
        let configs = ["Debug", "Release"].map { name in
            add(["isa": "XCBuildConfiguration", "name": name, "buildSettings": settings])
        }
        return add(["isa": "XCConfigurationList", "buildConfigurations": configs,
                    "defaultConfigurationIsVisible": 0, "defaultConfigurationName": "Release"])
    }

    func write(root: String, to url: URL) throws {
        let plist: [String: Any] = ["archiveVersion": "1", "objectVersion": "56", "classes": [String: Any](), "objects": objects, "rootObject": root]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}
