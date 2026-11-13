# Bundler

A SwiftPM command plugin that builds a macOS loadable bundle from a Swift static library product.
It has no dependency on Core Audio or HSP and supports bundles such as `.bundle`, `.plugin`, and Core Audio HAL `.driver` plug-ins.

## Requirements

- A macOS Swift toolchain supporting Swift 6.4 or later, with a macOS SDK.
- The macOS `codesign` tool.

## Usage

Add Bundler as a direct dependency of your package:

```swift
Package.Dependency.package(url: "https://github.com/Ars-Tools/bundler.git", branch: "release"),
```

Declare an explicitly static library product in the consuming package:

```swift
Product.library(name: "MyPlugin", type: Product.Library.LibraryType.static, targets: ["MyPlugin"]),
```

Place an `Info.plist` in the selected product's target directory (the target's `path` in `Package.swift`)
with `CFBundleExecutable` and `CFBundleIdentifier` entries. Exclude this file from the target's sources using `exclude: ["Info.plist"]`.
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

The plugin builds the selected static library and links it into a Mach-O loadable bundle (`MH_BUNDLE`),
copies the property list and resources, then applies and verifies an ad-hoc code signature.
It prints the absolute path to the completed bundle.

In Xcode, choose Builder from the package's context menu and select one target.
Xcode passes that selection as `--target`. Builder selects the static library
product containing that target, preferring a product with the same name. If the
selection is ambiguous, provide `--product` explicitly. For a HAL driver, enter
`--extension=driver` as one Arguments row; `--product` is unnecessary for a unique match.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--product` | Selected target's product, otherwise consuming package name | Static library product to build; overrides `--target` inference. |
| `--target` | None | One target selected in Xcode, or supplied explicitly; selects its static library product. |
| `--extension` | `bundle` | Output bundle extension. |
| `--configuration` | `release` | Build configuration: `debug` or `release`. |
| `--info-plist` | Automatic lookup | Override the property list path, relative to the package root. |
| `--resources` | `Resources` | Resources directory relative to the package root. The default directory may be absent; an explicitly supplied path must exist. |
| `--verify` | None | Executable product to build and run after bundle creation. May be repeated. |

Without `--info-plist`, Bundler searches the selected product's target directories for `Info.plist`,
then falls back to the package root. If multiple targets contain a property list, specify `--info-plist` explicitly.

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

In Xcode, output is under its plugin work directory, typically:

```text
~/Library/Developer/Xcode/DerivedData/<workspace>/Build/Intermediates.noindex/
  CommandPluginIntermediates/Builder.output/debug/MyPlugin.driver
```

Xcode may use its active build configuration even when a different configuration
is requested through the plugin API. When the returned product directory is
`Debug` or `Release`, Builder uses that configuration name for its output folder.
The final `Bundle:` log line is the authoritative output path.

SwiftPM normally returns a `lib<Product>.a` archive. Xcode can instead report an
executable placeholder while emitting merged `<Module>.o` files. In that case,
Builder links the selected product's source modules and transitive static source
dependencies from the reported products directory. It does not include unrelated
objects from that directory. Binary targets and explicit dynamic-product
dependencies are not supported by this Xcode fallback; missing objects fail with
a diagnostic. Module link libraries and frameworks are forwarded to the linker.
The macOS SDK is resolved using `xcrun` and passed explicitly to `swiftc`.
The command does not request permission to modify package sources.
It does not load or install the resulting bundle automatically; optional verifiers run only when requested.

## Scope

Bundler uses the configuration and architecture selected by SwiftPM.
Distribution signing, notarization, universal binary assembly, DriverKit `.dext` bundles, and kernel extensions are outside its current scope.

## References

- [SwiftPM: Writing a command plugin](https://docs.swift.org/latest/documentation/packagemanagerdocs/writingcommandplugin/)
- [Apple: Bundle Structures](https://developer.apple.com/go/?id=bundle-structure)
