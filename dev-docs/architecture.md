# Architecture

## Targets (`Package.swift`)

- `Sources/AppBundle`: the server, `MarSpace.app`. Nearly all the code, as an SPM library
- `Sources/AeroSpaceApp`: the tiny entry point that `xcode/AeroSpace.xcodeproj` wraps into the app bundle (SPM can't
  build app bundles). The Xcode project is generated from `xcode/project.yml`
- `Sources/Cli`: the `aerospace` CLI client, built with SPM only
- `Sources/Common`: shared by the client and the server, mostly the parsing of command arguments
- `Sources/PrivateApi`: the one private call, `_AXUIElementGetWindow`
- `Sources/AppBundleTests`: the tests

## Client and server

`aerospace` is the client, `MarSpace.app` the server. They talk over a Unix socket (see
[socket-protocol.adoc](./socket-protocol.adoc)). For every CLI command:

1. The client parses the arguments, reports errors, and prints `--help` itself
1. The arguments are sent to the server, which parses them again and runs the command
1. The server returns stdout, stderr and the exit code, and the client ends with them

## Settings

`Sources/AppBundle/settings`. The settings are a typed, `Codable` model (`Settings`, with `Action` for everything a
shortcut, a window rule or an automation does; `.custom` is the escape hatch for any command line).

- `SettingsRepository`: a checksummed binary property list in `~/Library/Application Support/MarSpace`, written atomically,
  with a backup. A file that can't be read is never overwritten
- `SettingsCompiler`: settings → the runtime `Config`, through the command parser. Invalid parts are reported as
  problems and left out
- `SettingsDefaults`: the settings of the first launch, written in Swift (there is no config file, and no TOML)
- `ui/`: the SwiftUI settings window. `SettingsModel` saves and applies every edit shortly after the last one

## Commands

- `CmdKind` (`Common/cmdArgs/cmdArgsManifest.swift`) lists all commands. Their arguments are parsed in
  `Common/cmdArgs/impl/`, they run in `AppBundle/command/impl/`
- Checklist for a new command:
  - its documentation in `docs/aerospace-<command>.adoc` (the CLI help is generated from it: run `generate.sh`)
  - do `--window-id` and `--workspace` make sense for it?
  - an `Action` case, if it should be pickable in the settings window

## Tree, layout, focus

- `tree/`: workspaces, containers and windows. See the [guide](../docs/guide.md) for the model
- `layout/`: turns the tree into frames. `refresh.swift` has the sessions that keep the model in sync with macOS
- `mouse/`: focus follows mouse, and moving and resizing with the mouse
