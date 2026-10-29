# Bundler

A SwiftPM command plugin that builds a macOS loadable bundle from a Swift static library product.
It has no dependency on Core Audio or HSP and supports bundles such as `.bundle`, `.plugin`, and Core Audio HAL `.driver` plug-ins.

## Requirements

- A macOS Swift toolchain supporting Swift 6.4 or later, with a macOS SDK.
- The macOS `codesign` tool.

## Usage

Add Bundler as a direct dependency of your package:

```swift
Package.Dependency.package(url: "https://github.com/Ars-Tools/bundler.git", branch: "main"),
```

Declare an explicitly static library product in the consuming package:

```swift
Product.library(name: "MyPlugin", type: Product.Library.LibraryType.static, targets: ["MyPlugin"]),
```

Place an `Info.plist` at the package root with `CFBundleExecutable` and `CFBundleIdentifier` entries.
Implement the entry points and supply any additional metadata required by the host application.
An optional `Resources/` directory at the package root is copied into the bundle.

Run the command from the consuming package directory:

```sh
swift package build-bundle --product MyPlugin
```

For a Core Audio HAL driver, select the `driver` extension:

```sh
swift package build-bundle --product MyPlugin --extension driver
```

The plugin builds the selected static library, links its archive into a Mach-O loadable bundle (`MH_BUNDLE`),
copies the property list and resources, then applies and verifies an ad-hoc code signature.
It prints the absolute path to the completed bundle.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--product` | Consuming package name | Static library product to build. |
| `--extension` | `bundle` | Output bundle extension. |
| `--configuration` | `release` | Build configuration: `debug` or `release`. |
| `--info-plist` | `Info.plist` | Property list path relative to the package root. |
| `--resources` | `Resources` | Resources directory relative to the package root. The default directory may be absent; an explicitly supplied path must exist. |
| `--verify` | None | Executable product to build and run after bundle creation. May be repeated. |

The bundle name and its internal binary name come from `CFBundleExecutable`.
The code-signing identifier comes from `CFBundleIdentifier`.
Each verifier receives the absolute path to the completed bundle's binary as its first argument.
A nonzero verifier exit status causes the command to fail.

For example:

```sh
swift package build-bundle --product MyPlugin --extension driver \
  --configuration debug --verify DriverCheck
```

## Layout and output

The package contains the `Builder` command plugin, whose implementation is `Plugin.swift` at the package root:

```text
Package.swift
Plugin.swift
README.md
```

The generated bundle is stored in the plugin's SwiftPM work directory. A typical output path is:

```text
.build/plugins/Builder/outputs/release/MyPlugin.bundle
```

`MyPlugin` here is the value of `CFBundleExecutable`.
The command does not request permission to modify package sources.
It does not load or install the resulting bundle automatically; optional verifiers run only when requested.

## Scope

Bundler uses the configuration and architecture selected by SwiftPM.
Distribution signing, notarization, universal binary assembly, DriverKit `.dext` bundles, and kernel extensions are outside its current scope.

## References

- [SwiftPM: Writing a command plugin](https://docs.swift.org/latest/documentation/packagemanagerdocs/writingcommandplugin/)
- [Apple: Bundle Structures](https://developer.apple.com/go/?id=bundle-structure)
