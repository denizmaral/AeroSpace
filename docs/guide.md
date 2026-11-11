# How MarSpace works

Everything here is set up in the settings window: open it from the menu bar panel, or open MarSpace again while it
runs. Changes apply right away.

## The shortcuts you start with

A new installation starts with these shortcuts. All of them use ⌃⌥ (Control and Option), and ⇧ for what moves a
window. Change them in Settings › Shortcuts; settings that exist already keep their shortcuts.

| Shortcut | What it does |
|---|---|
| ⌃⌥ ← ↓ ↑ → | Focus the window in that direction |
| ⌃⌥⇧ ← ↓ ↑ → | Move the window in that direction |
| ⌃⌥ and 1 … 9 or A … Z | Go to the workspace with that name |
| ⌃⌥⇧ and 1 … 9 or A … Z | Move the window to that workspace |
| ⌃⌥ ⇥ | Go back to the previous workspace |
| ⌃⌥⇧ ⇥ | Move the workspace to the next monitor |
| ⌃⌥ − and ⌃⌥ = | Make the window smaller or bigger, again and again while the keys are held |
| ⌃⌥ / | Tiles: side by side, or on top of each other |
| ⌃⌥ , | Accordion: horizontal or vertical |
| ⌃⌥⇧ Space | Make the window floating, or tiling again |
| ⌃⌥⇧ ⌫ | Reset the layout of the workspace: its windows side by side again |

−, =, / and , are the keys at these places of a US keyboard: the settings window shows every shortcut with the labels
of your keyboard layout.

## Windows live in a tree

MarSpace arranges the windows of a workspace in a tree, like [i3](https://i3wm.org/docs/userguide.html#tree):

- Each workspace has one root container
- A container holds windows and other containers, as deeply nested as you like
- Every container has a **layout** (tiles or accordion) and an **orientation** (horizontal or vertical)

![Two windows side by side](./assets/h_tiles.png)

![A more complex tree](./assets/tree.png)

You move around the tree in four directions with the **Focus** shortcuts, and change it with **Move** (swap a window
with its neighbor, or move it out of its container) and **Join with** (put two windows into a new container).

Shortcuts can also do what Hyprland users know by other names (Settings › Shortcuts, the action menu):

- **Cycle through the windows**: the next or the previous window of the workspace, and around at the end (`cyclenext`)
- **Focus the last focused window**: back to the window that had the focus before, and forth again (`focuscurrentorlast`)
- **Swap with a window**: the window and its neighbor change places, their containers stay as they are (`swapwindow`)
- **Move the window to a workspace**, with **Go there too**: the window goes and you follow it (`movetoworkspace`), or
  it goes and you stay (`movetoworkspacesilent`)

### Layouts

- **Tiles**: the windows share the space of the container side by side (horizontal) or on top of each other (vertical).
  Some apps refuse the size of their tile: App Store is at least 1000 wide and covers a part of the tile next to it,
  System Settings is at most 740 wide and leaves a part of its tile free. If the windows fit next to each other as they
  are, they are moved off each other. If they don't fit, they overlap
- **Accordion**: the windows are stacked, and a small padding on the sides shows that there are more. Focus left and
  right (or up and down) goes through them

![Horizontal accordion](./assets/h_accordion.png)

![Vertical accordion](./assets/v_accordion.png)

### Normalization

Two rules keep the tree easy to read from what you see on the screen. Both are on by default (Settings › General):

- A container with a single child is flattened (the root container may hold a single window)
- A container inside another one has the opposite orientation

### Where new windows go

Settings › General › New window placement:

- **Dwindle**: the new window takes half of the focused window, like Hyprland. Wide windows split side by side, tall
  ones top to bottom, so the windows spiral
- **Balanced**: like dwindle, but the largest window is split, so the windows stay about the same size (four windows
  make a 2×2 grid)
- **i3**: the new window goes next to the focused one, and all windows of the container share the space equally

A window that leaves the layout for a while (macOS fullscreen, minimized, its app hidden) comes back to its place.
When MarSpace itself is restarted, the windows go back to their workspaces and to their places and sizes in the layout
(until the Mac is restarted: macOS gives the windows new ids then).

### Gaps

Settings › Appearance sets the gap between the windows and the gaps at the screen edges. With **No gaps around a single
window**, a workspace with one tiling window gives it the whole screen: the gaps come back with the second window (like
Hyprland's smart gaps).

### Floating windows

Floating windows aren't part of the tree, but Focus still reaches them: a floating window belongs to the smallest
container that holds its center.

A floating window can be **pinned** (the action "Pin the floating window", or `aerospace pin`): it stays on the screen
when you go to another workspace, like a small video or a note that you want everywhere. It comes along without taking
the focus. A window rule can pin the windows of an app: make them floating first (Change the layout › Floating), then
pin them.

When windows were made floating by mistake, the action "Tile all floating windows" (`aerospace tile-floating-windows`)
makes every floating window of the workspace tiling again. A window that you made
floating goes back to its place in the layout, with its size (also when you tile it alone, with Change the layout ›
Tiling); a window that never had a place, like a dialog, is placed like a new window.

With focus follows the mouse, a focused floating window keeps the focus while the mouse is over the tiled windows behind
it: focusing a window in macOS brings it to the front, and the floating window would disappear behind it. Click the
tiled window, or use a shortcut, to focus it.

## Workspaces

macOS Spaces are slow to switch, limited in number, and can't be controlled by apps. MarSpace has its own workspaces
instead: the windows of a workspace that isn't shown are moved to a corner of the screen, and come back when you switch
to it. The menu bar shows the current workspace.

Use a single macOS Space (one per monitor if "Displays have separate Spaces" is on) and let MarSpace do the rest. When
MarSpace quits, all windows are put back on screen.

macOS doesn't let a window go completely off screen: a line of one pixel of the hidden windows stays visible in a
bottom corner. Putting the Dock at the bottom (and hiding it automatically) makes it nearly invisible.

### Arrange your monitors so that hidden windows have room

Every monitor needs free space at its bottom right or bottom left corner (System Settings › Displays › Arrange…).
Otherwise, parts of hidden windows show up on another monitor.

![Bad: monitor 2 has no free bottom corner](./assets/monitor-arrangement-1-bad.svg)
![Good: every monitor has a free bottom corner](./assets/monitor-arrangement-1-good.svg)

![Bad: monitor 1 has no free bottom corner](./assets/monitor-arrangement-2-bad.svg)
![Good: every monitor has a free bottom corner](./assets/monitor-arrangement-2-good.svg)

### Mission Control

Mission Control shows windows too small when many of them sit in a corner. Turning on System Settings › Desktop & Dock
› Group windows by application helps.

### "Displays have separate Spaces"

macOS behaves better with this setting off (System Settings › Desktop & Dock; you need to log out and in again). With it
on, moving windows between monitors also moves them between Spaces, which the public APIs handle badly: focus can go to
the wrong window and things get slow.

| | Separate Spaces on | Separate Spaces off |
|---|---|---|
| A window across two monitors | No | Yes |
| Stability and speed | Focus and speed problems happen | Better |
| A monitor in macOS fullscreen | The other monitor still works | The other monitor is black |
| The menu bar | On every monitor | Only on the main monitor |

### There and back with one shortcut

With **Press it again to go back to the previous workspace** (Settings › Shortcuts, under the
workspace shortcuts), pressing the shortcut of a workspace twice looks at it and comes back, like Hyprland's
`workspace_back_and_forth`. A single shortcut can do the same for one workspace (the action "Go to a workspace", with
**Again goes back**): a workspace for the things that you only look at for a moment, like a scratchpad.

## Multiple monitors

- All monitors share one pool of workspaces, and each monitor shows one of them
- Two monitors can't show the same workspace
- Every workspace belongs to a monitor, the main one unless you assign another (Settings › Workspaces)

Going to a workspace shows it on its monitor and focuses it. You can also move the focused workspace to the next or
previous monitor.

This fits the way most people use a second monitor: a few dedicated workspaces there (a browser, logs, a dashboard),
and everything else on the main monitor.

## Dialogs

Apps can tell macOS which of their windows are dialogs, but many don't, or get it wrong. MarSpace asks, and also guesses:
for example, a window without a fullscreen button is treated as a dialog (except in terminal apps). Dialogs float.

If a window floats or tiles when it shouldn't, add a window rule for its app (Settings › Window Rules) that makes it
tiling or floating. Improvements to the guess are welcome: see `isDialogHeuristic` in the sources.

## Shortcuts that repeat

A shortcut can run again and again while its keys are held, like a key that types (Hyprland's `binde`), with the key
repeat delay and rate of macOS (System Settings › Keyboard). Shortcuts that make the window bigger or smaller do so from
the start: hold them until the size is right. Any other shortcut can: Settings › Shortcuts, the shortcut, **Repeat while
the keys are held**.

## Shortcuts don't work?

Another app may take the same keys first: check tools that listen to global keys, like Karabiner-Elements, skhd or
Raycast.

## The command line

`aerospace` controls MarSpace from scripts, with AeroSpace's commands: each one is documented in this folder
(`aerospace-<command>.adoc`) and has `--help`. Scripts and other
clients can also talk to MarSpace directly: see the [socket protocol](../dev-docs/socket-protocol.adoc).
