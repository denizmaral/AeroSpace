# Contributing to MarSpace

Thank you for taking the time to look at MarSpace! Every contribution is welcome, and you don't need to write code to
help: a clear bug report, an idea with a good use case, a fix in the docs or a screenshot of a layout that goes wrong
helps as much as a pull request.

If you're unsure about anything, open an issue and ask. There are no silly questions.

## Ways to help

- **Report a bug.** Something doesn't tile, focus jumps, a shortcut doesn't fire? Tell us.
- **Suggest a feature.** Start with what you're trying to do; we'll figure out the best way to get there together.
- **Improve the docs.** The README, this guide, and the developer notes in [dev-docs](./dev-docs) can always be clearer.
- **Send a fix or a feature.** Small, focused pull requests are the easiest to review and merge.
- **Spread the word.** Tell a friend, or write about your setup.

## Reporting a bug

Open an issue on [GitHub](https://github.com/denizmaral/MarSpace/issues). These help a lot:

- What you did, what you expected, and what happened instead
- A screenshot or a short screen recording, if it's about windows or the settings window
- The output of `aerospace debug-windows`, if a window is handled wrongly
- The relevant settings: a screenshot of the settings pane is perfect (the settings file is binary, there is no config
  to paste)
- Your MarSpace version (`aerospace --version`) and your macOS version

## Suggesting a feature

The most helpful part of a feature request is the use case: what you do every day and where MarSpace gets in the way.
Alternatives you considered, and how other window managers solve it, are welcome too.

A few principles guide what gets in:

- Practical features first, looks second
- Settings are edited in the settings window, never in a text file
- No "dark magic": MarSpace uses public macOS APIs (and the one private call it already has), and never asks you to
  disable System Integrity Protection
- Changes that break existing setups only with very good reasons and a helpful migration

## Your first code contribution

### Build and run

You need macOS and Xcode with Swift 6.4 (see `.swift-version`).

```sh
swift build   # build everything
swift test    # run the unit tests
```

The scripts in the repo root do the rest. They need [swiftly](https://github.com/swiftlang/swiftly) and bash 5
(`brew install swiftly bash`):

```sh
./run-debug.sh       # run a debug build of the app (a running MarSpace is turned off meanwhile)
./run-cli.sh <args>  # talk to it with the CLI, e.g. ./run-cli.sh list-windows --all
./test.sh            # everything a review checks: warnings as errors, tests, formatting, lint, unused code
```

The first time, macOS asks for the Accessibility permission: MarSpace can't move windows without it. More details are
in [dev-docs/development.md](./dev-docs/development.md).

### Find your way around

- `Sources/AppBundle`: the app. Nearly everything happens here
  - `settings/`: the settings model, its storage, and the settings window (`settings/ui`)
  - `tree/`: workspaces, containers and windows
  - `layout/`: turning the tree into window frames
  - `mouse/`: focus follows mouse, mouse moves and resizes
  - `command/`: the commands behind shortcuts and the `aerospace` CLI
- `Sources/Cli`: the `aerospace` command line client
- `Sources/AppBundleTests`: the tests

[dev-docs/architecture.md](./dev-docs/architecture.md) explains how the pieces fit together.

### Make the change

- **Match the code around you.** Naming, structure, comments and tests should look like what's already there.
- **Add a test** for a behavior change or a bug fix. The tests use Swift Testing; the existing suites are good
  templates.
- **Keep it warning-free.** Release builds treat warnings as errors.
- **Format and lint** with `./format.sh` and `./lint.sh`.
- **Don't edit generated files** (`*Generated.swift`, `xcode/AeroSpace.xcodeproj`): change their source and run
  `./generate.sh`.

### Open the pull request

- One topic per pull request. Several small ones beat one big one.
- Describe what changes for the user, and why. A screenshot helps for anything visible.
- A commit message says what changed and why, like the ones in `git log`.

Don't worry about getting everything perfect: review is a conversation, and we'll get it over the line together.

## Be kind

Be respectful and patient with each other. Everyone here is volunteering their time.

## License

MarSpace is MIT licensed (see [LICENSE.txt](./LICENSE.txt)). By contributing, you agree that your contributions are
licensed under the MIT license too.

MarSpace is built on [AeroSpace](https://github.com/nikitabobko/AeroSpace) by Nikita Bobko and its contributors. If you
find a bug that AeroSpace has too, consider reporting it there as well.
