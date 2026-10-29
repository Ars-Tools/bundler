# BundleBuilder

SwiftPM command pluginで、Swiftのstatic library productからmacOSのloadable bundleを構築します。
Core AudioやHSPには依存しません。`.bundle`、`.plugin`、Core Audio HALの`.driver`などに利用できます。

## 利用方法

Swift 6.4以降のmacOS用ツールチェーンとSDK、`codesign`が必要です。
利用するpackageの`dependencies`に追加します。

```swift
Package.Dependency.package(url: "https://github.com/Ars-Tools/BundleBuilder.git", branch: "main"),
```

利用側には明示的なstatic library productを定義します。

```swift
Product.library(name: "MyPlugin", type: Product.Library.LibraryType.static, targets: ["MyPlugin"]),
```

package直下に`Info.plist`を置き、`CFBundleExecutable`と`CFBundleIdentifier`を指定します。
ホストが要求するfactoryやその他のmetadataは利用側で実装・指定してください。
`Resources/`があれば、その内容もbundleに含めます。

```sh
swift package build-bundle --product MyPlugin
swift package build-bundle --product MyPlugin --extension driver
```

選択したstatic archiveを`MH_BUNDLE`へリンクし、plist・resourcesを配置してad-hoc署名と署名検証を行います。
生成物はpluginの作業領域内に置き、成功時に絶対パスを表示します。
ソースディレクトリの書き込み権限は要求しません。ビルドしたbundleのロード・インストールは行いません。

## オプション

| オプション | 既定値 | 内容 |
| --- | --- | --- |
| `--product` | 利用側package名 | static library product名 |
| `--extension` | `bundle` | bundleの拡張子 |
| `--configuration` | `release` | `debug`または`release` |
| `--info-plist` | `Info.plist` | packageルートからのplistパス |
| `--resources` | `Resources` | packageルートからのresourcesディレクトリ。既定ディレクトリは省略可 |
| `--verify` | なし | 検証用executable product。複数回指定可 |

bundle名と内部バイナリ名は`CFBundleExecutable`から取得します。
署名identifierは`CFBundleIdentifier`から取得します。
`--verify`は指定したproductをビルドし、完成したbundle内のバイナリの絶対パスを第1引数として渡します。
検証プログラムの終了コードが0以外ならコマンドは失敗します。

現在はSwiftPMが選択した構成・アーキテクチャでビルドします。
配布用の署名、公証、universal binary生成、DriverKitの`.dext`、kernel extensionの生成は対象外です。

## 参考

- [SwiftPM: Writing a command plugin](https://docs.swift.org/latest/documentation/packagemanagerdocs/writingcommandplugin/)
- [Apple: Bundle Structures](https://developer.apple.com/go/?id=bundle-structure)
