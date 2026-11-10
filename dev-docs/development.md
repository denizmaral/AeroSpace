# Development

## Setup

1. Install Xcode with Swift 6.4 (the version in `.swift-version`).
2. For the scripts in the repo root, install [swiftly](https://github.com/swiftlang/swiftly) (it uses exactly the Swift
   version of `.swift-version`) and bash 5: `brew install swiftly bash`. Optional: `brew install xcbeautify` for
   readable Xcode logs.
3. For the app bundle, create a code signing certificate in Keychain Access: Keychain Access › Certificate Assistant ›
   Create a Certificate…, name `aerospace-codesign-certificate`, identity type Self-Signed Root, certificate type Code
   Signing. Or pass your own identity with `--codesign-identity`. Not needed for debug builds.

Without swiftly or bash 5, `swift build --build-tests` and `swift test` still work, as long as Xcode's Swift matches
`.swift-version`.

## Scripts

| Script | What it does |
|---|---|
| `build-debug.sh` | Debug build with SPM into `.debug` |
| `run-debug.sh` | Runs the debug build (a running MarSpace is turned off meanwhile) |
| `run-cli.sh <args>` | Runs the `aerospace` CLI against the running server |
| `swift-test.sh` | The unit tests |
| `test.sh` | Everything a review checks: a build with warnings as errors, the tests, `lint.sh`, `generate.sh`, and no uncommitted generated files |
| `format.sh`, `lint.sh` | swiftformat; swiftformat + swiftlint + periphery (unused code). The tools are downloaded into `.deps` |
| `generate.sh` | Regenerates the generated files: the CLI help from `docs/aerospace-*.adoc`, `xcode/AeroSpace.xcodeproj` from `xcode/project.yml` |
| `build-release.sh` | Signed release build of `MarSpace.app` and the `aerospace` CLI into `.release` |
| `script/clean-project.sh` | Cleans the build when something went wrong |

The app needs the Accessibility permission. Open the bundle (`open .release/MarSpace.app`) rather than running its
binary: otherwise macOS asks for the permission for the parent process.

## Editors

- Xcode: open `Package.swift` (not `xcode/AeroSpace.xcodeproj`, which only wraps the package into an app bundle for the
  release build). In Edit Scheme › Options › Console, choose Terminal: the permission is then asked for Terminal once,
  instead of for every unsigned debug build.
- Any editor with [sourcekit-lsp](https://github.com/apple/sourcekit-lsp).

## Tips

- Accessibility Inspector (comes with Xcode) shows the accessibility properties of windows
- [DeskPad](https://github.com/Stengo/DeskPad) or [BetterDisplay](https://github.com/waydabber/BetterDisplay) emulate
  more monitors
