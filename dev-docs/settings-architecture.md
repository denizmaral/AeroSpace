# Settings architecture

Status: phases 1 to 4 done (2026-11-10), phase 5 next.

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
 Settings window ─┐                                    ┌─▶ HotkeyService        (diff by chord)
 reload-config ───┼─▶ SettingsStore ──▶ EngineSnapshot ─┼─▶ WindowRules         (typed match → typed actions)
 app moves ───────┘   (one owner)       (immutable)     ├─▶ layout / gaps / border / focus follows mouse
                      │                                  └─▶ login item
                      └─▶ SettingsRepository (file: checksum, atomic, backup)
```

## Invariants

1. **One owner.** `SettingsStore` (`@MainActor @Observable`) is the only holder and the only writer of the settings: the
   settings window, `reload-config`, the migration, remembered app workspaces. Views read it and send it changes; they
   never keep their own copy
2. **Stable identity.** Every element of a list (shortcut, rule, action, monitor assignment) has an id. Views bind, edit,
   delete, open popovers and undo by id, never by index
3. **Valid by construction.** Workspace names and bundle ids are types that can only hold valid values. An item that isn't
   complete yet (a rule without an action) is a state of the domain: it's shown as such and the engine skips it
4. **Transactions.** `store.update("Delete Rule") { … }` is the only way to change the settings: it registers the undo,
   persists, and publishes the change, in one place
5. **One-way derivation, applied by diff.** Settings → an immutable engine snapshot. Services apply what changed (a
   hotkey added or removed, not all of them again). Nothing else feeds the engine
6. **No hidden semantic state.** Where an app opens is a window rule: visible, editable, undoable. The placement
   cache (windows back to their workspaces after a restart of MarSpace) stays a cache without meaning for the user. Only
   moves made by the user (a shortcut, a menu) are remembered, not moves by window rules or scripts

## Trade-offs

- The engine still reads its configuration through AeroSpace's `Config` type during the migration: the seam changes
  first (one snapshot, applied by diff), the TOML-only fields are removed after
- `aerospace config --get …` (AeroSpace's CLI) keeps working from the snapshot, for scripts
- Typed commands instead of command lines come late, behind a golden test: a typed command must equal the parsed one,
  including its description (logs and `list-modes` print it)

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
5. **Typed commands** (if still worth it then): actions run as typed commands, the command line stays for custom actions

## Backlog (UX QA, after phase 1)

The keycaps of the workspace shortcuts (small hit targets), every state of the key recorder (Escape, a key alone, a
conflict), removing a mode, the validation of new names, the monitor assignment row, the lower half of Appearance,
Automation, the menu panel, hover highlights on clickable rows, steppers for exact values
