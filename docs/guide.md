# How MarSpace works

Everything here is set up in the settings window: open it from the menu bar panel, or open MarSpace again while it
runs. Changes apply right away.

## Windows live in a tree

MarSpace arranges the windows of a workspace in a tree, like [i3](https://i3wm.org/docs/userguide.html#tree):

- Each workspace has one root container
- A container holds windows and other containers, as deeply nested as you like
- Every container has a **layout** (tiles or accordion) and an **orientation** (horizontal or vertical)

![Two windows side by side](./assets/h_tiles.png)

![A more complex tree](./assets/tree.png)

You move around the tree in four directions with the **Focus** shortcuts, and change it with **Move** (swap a window
with its neighbor, or move it out of its container) and **Join with** (put two windows into a new container).

### Layouts

- **Tiles**: the windows share the space of the container side by side (horizontal) or on top of each other (vertical)
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

## Shortcuts don't work?

Another app may take the same keys first: check tools that listen to global keys, like Karabiner-Elements, skhd or
Raycast.

## The command line

`aerospace` controls MarSpace from scripts, with AeroSpace's commands: each one is documented in this folder
(`aerospace-<command>.adoc`) and has `--help`. Scripts and other
clients can also talk to MarSpace directly: see the [socket protocol](../dev-docs/socket-protocol.adoc).
