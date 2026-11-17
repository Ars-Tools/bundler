# Bundler

A SwiftPM command plugin that builds macOS apps and loadable bundles, and iOS apps with embedded WidgetKit extensions.
It has no dependency on Core Audio or HSP and supports bundles such as `.bundle`, `.plugin`, and Core Audio HAL `.driver` plug-ins, as well as `.app` applications with embedded helper executables.

## Requirements

- A macOS Swift toolchain supporting Swift 6.4 or later, with a macOS SDK.
- The macOS `codesign` tool.
- For iOS: full Xcode with the iOS SDK; Simulator runtime for installation/testing. Device builds also require signing credentials and provisioning profiles.

## iOS apps and WidgetKit extensions

Use a normal SwiftPM manifest with one executable product for the settings app
and one executable product for each widget extension. An extension can expose
multiple widget types using `WidgetBundle`. Bundler generates a temporary native
Xcode project and invokes `xcodebuild`; you do not maintain an `.xcodeproj`.
Full Xcode on macOS is required. This does not add extension building to the
Swift Playgrounds app or to the standard `AppleProductTypes.iOSApplication` build.

```text
Package.swift
Bundle/
  Info.plist
  Entitlements.plist           # optional
  Sources/App.swift           # @main struct conforming to App
  Resources/                  # optional; compiled/copied into the app
FC/
  Info.plist
  Entitlements.plist           # optional
  Sources/Widgets.swift       # @main Widget or WidgetBundle, AppIntents, provider
  Resources/                  # optional; compiled/copied into the extension
Shared/Sources/Settings.swift
```

```swift
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Widgets",
    platforms: [.iOS(.v17)],
    products: [
        .executable(name: "Widgets", targets: ["SettingsApp"]),
        .executable(name: "FC", targets: ["FC"]),
        .library(name: "Shared", targets: ["Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ars-tools/bundler", branch: "release"),
    ],
    targets: [
        .executableTarget(name: "SettingsApp", dependencies: ["Shared"],
            path: "Bundle", exclude: ["Info.plist", "Entitlements.plist", "Resources"]),
        .executableTarget(name: "FC", dependencies: ["Shared"],
            path: "FC", exclude: ["Info.plist", "Entitlements.plist", "Resources"]),
        .target(name: "Shared", path: "Shared/Sources"),
    ]
)
```

Only exclude optional paths that actually exist. Use a local `.package(path:)`
dependency while testing unreleased Bundler changes.

The app `Info.plist` requires literal `CFBundleExecutable` and
`CFBundleIdentifier` values, for example `Widgets` and `tools.ars.widgets`.
The extension plist requires different values, for example `FCWidget` and
`tools.ars.widgets.fc`, plus:

```xml
<key>NSExtension</key>
<dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
</dict>
```

Do not set `NSExtensionPrincipalClass` or `NSExtensionMainStoryboard` for a
WidgetKit extension. Extension bundle identifiers must start with the app's ID
followed by a dot. Executable names must be unique path components consisting
of letters, digits, underscores or hyphens. Bundle package type defaults to
`APPL` for the app and `XPC!` for extensions; build/display versions default to
`1` / `1.0`. Custom values in each plist are preserved.

For shared settings, put matching App Group entitlements in each target's
`Entitlements.plist` and use the same group with `UserDefaults(suiteName:)` or
the shared container API. Device provisioning profiles must authorize the group.
Bundler forwards these entitlements to Xcode; it does not register App Groups
or create signing assets on the developer portal.

Build a Simulator app, adding `--embed-widget` once per extension product:

```sh
swift package --disable-sandbox build-bundle --platform ios-simulator \
  --product Widgets --embed-widget FC --configuration debug \
  --deployment-target 17.0
```

The command plugin launches Xcode and its build services, which need access to
SDK caches and build services outside the SwiftPM plugin sandbox. Use
`--disable-sandbox` with trusted packages when invoking this iOS path from the CLI.
App and extension sources compile as native Swift targets so Xcode extracts
App Intents metadata directly from those sources. Each target needs its own
`@main` entry point. The app can consist entirely of settings UI.

The final `Bundle:` line is the authoritative `.app` output. With a booted
Simulator, install it with `xcrun simctl install booted /absolute/path/Widgets.app`,
then add its widget from the Home Screen widget gallery. Simulator builds use
ad-hoc signing and need no developer team.

For a device build:

```sh
swift package --disable-sandbox build-bundle --platform ios \
  --product Widgets --embed-widget FC --development-team YOURTEAMID
```

Device builds use Xcode Automatic signing with locally available signing assets.
The command does not pass `-allowProvisioningUpdates`, install an app, upload,
archive or export an IPA. Signing/installation on a physical device must be
validated with your developer account. App Store distribution is not provided.

### iOS source and resource boundaries

- The selected products must have Swift executable entry targets. Bundler takes
  their source file lists, compilation conditions and linked libraries/frameworks
  from SwiftPM. Source paths such as `Bundle/Sources` and `FC/Sources` are supported.
- Local target dependencies must be exported as single-target automatic/static
  library products. Product dependencies must be automatic/static libraries.
  Xcode builds these as Swift packages, including their transitive dependencies
  and SwiftPM resource bundles. Embedding dynamic dependency frameworks is not
  supported by this initial iOS path.
- Entry-target resources use a `Resources` directory directly inside the target
  directory (`path:` in the manifest). Its immediate entries are native Xcode
  resources: asset catalogs compile with `actool`, plain files copy to the bundle
  root, and other directories copy as folders. `Bundle.module` in entry-target
  sources resolves to that native bundle. Library dependencies retain normal
  SwiftPM resource behavior. Localized `.lproj` resource groups are not supported
  in entry targets yet; place localized resources in a package library instead.
- Keep package build plugins, macros and custom compiler settings in library
  dependencies. Entry-target generated files are rejected; arbitrary SwiftPM
  unsafe flags/settings and platform-conditioned manifest behavior are not a
  complete replacement for native Xcode build settings. This path uses Swift 6.
- Per-target `Info.plist` lookup uses the same rules as macOS. Put each plist
  inside its entry target directory to avoid sharing the root fallback accidentally.
  The macOS `--info-plist`, `--resources`, `--contents`, `--embed-executable`,
  `--extension` and `--verify` options are rejected for iOS.
- Output is under the command plugin work directory in
  `ios-simulator/<configuration>/<name>.app` or `ios/<configuration>/<name>.app`.
  A build uses fresh products so removed extensions cannot survive from an older
  build. A failed build leaves the previous published app intact and retains its
  generated project for diagnosis. Run one build per platform/configuration at a time.

Run the iOS integration check with `python3 Checks/check_ios.py`. It builds two
real extensions (including a button-backed `AppIntent`) and verifies Mach-O
platform/type, bundle layout, asset compilation, package resources, metadata,
input validation and removal of stale extensions. Set `BUNDLER_CHECK_KEEP=1` to
retain its fixture for manual Simulator testing. The check does not require or
claim physical-device provisioning validation.

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

For a static library, the plugin builds the selected product and links it into a Mach-O loadable bundle (`MH_BUNDLE`),
copies the property list and resources, then applies and verifies an ad-hoc code signature.
It prints the absolute path to the completed bundle.

In Xcode, choose Builder from the package's context menu and select one target.
Xcode passes that selection as `--target`. Builder selects the static library
or executable product containing that target, preferring a product with the same name. If the
selection is ambiguous, provide `--product` explicitly. For a HAL driver, enter
`--extension=driver` as one Arguments row; `--product` is unnecessary for a unique match.

## Applications and background-service helpers

Declare the app and its helpers as executable products. Set the app's
`CFBundlePackageType` to `APPL` and provide `CFBundleExecutable` and
`CFBundleIdentifier` in its target's `Info.plist` (excluded from Swift sources).
Bundler defaults to `.app` for executable products and copies the built executable
without relinking it as `MH_BUNDLE`. The product name may differ from
`CFBundleExecutable`.

```sh
swift package build-bundle --product RTCControl \
  --embed-executable RTCSyncService --contents RTCControl/Contents
```

`--embed-executable` builds an executable product from the consuming package and
copies it to `Contents/MacOS/<product-name>`. It may be repeated for distinct
helpers. Helpers do not require their own `Info.plist`. They receive an ad-hoc
signature with identifier `<app-bundle-identifier>.<product-name>` before the
outer app is signed. The completed app and its nested signatures are verified.

`--contents` copies a directory's immediate entries into the output's `Contents`
directory, preserving their subtrees. For example, an input tree:

```text
RTCControl/Contents/
  Library/
    LaunchDaemons/
      ars.audio.RTCSyncService.plist
```

produces `RTCControl.app/Contents/Library/LaunchDaemons/ars.audio.RTCSyncService.plist`.
The plist can refer to `Contents/MacOS/RTCSyncService` using `BundleProgram`.
Bundler copies the plist verbatim; the consuming app supplies its launchd settings
and uses `SMAppService` at runtime to register/unregister the helper.

`MacOS`, `Info.plist`, and `_CodeSignature` entries are reserved. Existing entries
such as a `Resources` directory supplied by `--resources` cannot be overwritten
or merged by `--contents`; choose one source for each top-level entry. Use
`--contents` for additional data/configuration, and `--embed-executable` for built
helper code. Automatic packaging/signing of `.xpc` bundles, frameworks, dependency
resource bundles, or other nested code is not provided.

These options require an executable app product. Executable products cannot be
packaged as `.driver`/`.bundle`, and static libraries cannot be packaged as `.app`.
Service installation, registration, approval, and persistent execution are separate
from building. Ad-hoc signature verification does not establish that Service
Management will accept the app on a particular Mac; distribution signing and
service registration must be validated separately.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `--product` | Selected target's product, otherwise consuming package name | Static library or executable product to build; overrides `--target` inference. |
| `--target` | None | One target selected in Xcode, or supplied explicitly; selects its static library or executable product. |
| `--extension` | `app` for executables, otherwise `bundle` | Output bundle extension. |
| `--configuration` | `release` | Build configuration: `debug` or `release`. |
| `--info-plist` | Automatic lookup | Override the property list path, relative to the package root. |
| `--resources` | `Resources` | Resources directory relative to the package root. The default directory may be absent; an explicitly supplied path must exist. |
| `--embed-executable` | None | Executable product to build, copy into `Contents/MacOS`, and sign before the app. Repeatable; apps only. |
| `--contents` | None | Additional Contents directory relative to the package root. Apps only; no overwriting existing entries. |
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

The package contains the `Builder` command plugin, implemented at the package root:

```text
Package.swift
Plugin.swift
IOSBuilder.swift
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
It does not launch, load, install, or register the resulting bundle or service automatically; optional verifiers run only when requested.

## Checks

Run the integration checks on macOS with Swift 6.4+, Python 3, and the command-line
tools available:

```sh
python3 Checks/check.py
```

They generate a temporary consuming package and verify real executable app/helper
builds, Contents/resource placement, nested signatures, static-library bundle and
driver loading, and invalid combinations. They do not register a service or launch
a GUI. The temporary package is removed on completion.

## Scope

Bundler uses the configuration and architecture selected by SwiftPM.
Distribution signing, notarization, universal binary assembly, DriverKit `.dext` bundles, and kernel extensions are outside its current scope.

## References

- [SwiftPM: Writing a command plugin](https://docs.swift.org/latest/documentation/packagemanagerdocs/writingcommandplugin/)
- [Apple: Bundle Structures](https://developer.apple.com/go/?id=bundle-structure)

- [Apple: App-bundled launch agents and daemons](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple: Signing nested code](https://developer.apple.com/library/archive/technotes/tn2206/)
