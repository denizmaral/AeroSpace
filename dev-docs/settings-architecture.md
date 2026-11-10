# Settings architecture

Status: done (2026-11-10).

## Why

The settings were bolted onto AeroSpace's TOML configuration, and it shows. Everything that broke in front of the user came
from that seam:

- **Ownership.** The settings window keeps its own copy of the settings and saves it whole. Anything else that writes
  settings (reload, migration, remembered app workspaces) is silently overwritten by the next edit in an open window
- **Identity.** Lists are edited by index. A row removed while its popover was still open read past the end: two crashes
- **Half-made items went live.** "Add a rule" created "any app → workspace 1", active within 250 ms
- **Hidden semantic state.** Where an app opens lived in three places (window rules, a hidden plist, a placement cache).
  The user's Mail → M existed, but nothing showed it, so it looked deleted
- **Wholesale swap.** Every change rebuilt AeroSpace's `Config` and replaced the global `config`: all hotkeys reset and
  registered again (the pause while recording a shortcut had to fight it), and at startup the TOML default config was
  applied first
- **Strings in the middle.** Typed actions became command lines and were parsed again by the CLI parser (comment and quoting
  bugs, an equality that compared nothing)

## Decision

Keep AeroSpace's window engine (tree, layout, commands): it's solid and it isn't the problem. Replace the configuration
layer with MarSpace's own: a typed domain, one owner, derived engine state applied by diff. Simple over clever: no
migration of AeroSpace's configuration, no TOML, defaults written in Swift.

```
 Settings window ─┐                   Settings.compile()                       ┌─▶ hotkeys (diff by chord)
 reload-config ───┼─▶ SettingsStore ─────────────────────▶ Config (snapshot) ──┼─▶ window rules (matcher → commands)
 shortcut moves ──┘   (one owner)     typed actions build                      ├─▶ layout / gaps / border / focus follows mouse
                      │               their commands                           └─▶ login item
                      └─▶ SettingsRepository (file: checksum, atomic, backup)
```

## Invariants

1. **One owner.** `SettingsStore` (`@MainActor @Observable`) is the only holder and the only writer of the settings: the
   settings window, `reload-config`, a window moved to a workspace with a shortcut. Views read it and send it changes;
   they never keep their own copy
2. **Stable identity.** Every element of a list (shortcut, rule, action, monitor assignment) has an id. Views bind, edit,
   delete, open popovers and undo by id, never by index
3. **Complete or not, valid or not, visibly.** An item that isn't complete yet (a rule without an action) is a state of
   the domain: it's shown as such and the engine skips it. A value that the engine can't take (a reserved workspace
   name, a broken regular expression) is a problem of the compiled settings, shown where it is; the rest still applies
4. **Transactions.** `store.update("Delete Rule") { … }` is the only way to change the settings: it registers the undo,
   persists, and publishes the change, in one place
5. **One-way derivation, applied by diff.** Settings → an immutable engine snapshot. Services apply what changed (a
   hotkey added or removed, not all of them again). Nothing else feeds the engine
6. **No hidden semantic state.** Where an app opens is a window rule: visible, editable, undoable. The placement
   cache (windows back to their workspaces after a restart of MarSpace) stays a cache without meaning for the user. Only
   moves made by the user (a shortcut, a menu) are remembered, not moves by window rules or scripts

## What stays AeroSpace's, and why

The line between MarSpace's settings and AeroSpace's engine is `Config`. Everything before it is MarSpace's; what is
after it stays, on purpose:

- **The window engine**: the tree, the normalizations, the layout, the commands and their CLI. It's solid, and the
  commands are the one implementation of every action (the settings don't implement anything twice)
- **`Config` as the snapshot that the engine reads**, with the engine's names (`onWindowDetected`, `persistentWorkspaces`):
  it holds only what the settings can express (phase 6), nothing of the TOML format
- **The CLI for scripts**: `aerospace config --get mode…`, `list-modes`, `reload-config` print and do what AeroSpace's do,
  from the snapshot. The key names that they print are those of the CLI (`ctrl-alt-period`, a US keyboard); the settings
  window shows the keys of the keyboard layout of macOS

Renaming the engine's own concepts would be churn without a benefit: the cleanup stops at the seam.

## Phases

Every phase is one commit and one deploy, and must reproduce the compiled result of the user's real settings
(characterization test over a copy of them).

1. **Store and identity**: `SettingsStore` as the one owner with transactions and undo; ids in every list; views by id;
   complete/incomplete as a domain state
2. **Engine snapshot, applied by diff**: hotkeys, window rules, login item, focus follows mouse; no wholesale `config`
   swap, no reset of all hotkeys
3. **Where an app opens is a window rule**: moving a window to a workspace with a shortcut makes (or changes) the rule of
   its app, "move the window to workspace M", shown and edited like any other rule. Moves by rules or scripts don't
4. **No AeroSpace legacy**: no TOML import at the first launch, no TOML parser and default config at runtime, no
   migration of older settings, no `--config-path`. The default settings are written in Swift
5. **Typed commands**: a typed action builds its engine command from its values, without the parser; its words are
   kept as the arguments that the command prints. Only a custom action is a command line, parsed. A golden test requires
   every typed command to equal the parsed command of its command line, and to print the same
6. **The snapshot is MarSpace's**: `Config` holds only what the settings express. Gaps are numbers (no per-monitor TOML
   values); a window rule has one matcher (no "legacy" and command matchers) and its commands; the environment of
   `exec-and-forget` is a constant; the hidden keyboard layout preset is gone (no control showed it, the key names are
   the CLI's)

## Backlog (UX QA, after phase 1)

The keycaps of the workspace shortcuts (small hit targets), every state of the key recorder (Escape, a key alone, a
conflict), removing a mode, the validation of new names, the monitor assignment row, the lower half of Appearance,
Automation, the menu panel, hover highlights on clickable rows, steppers for exact values
