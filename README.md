# macosdragfix

Native workaround for the window-dragging bug in the macOS 27 (Golden Gate) beta:
on this beta, dragging a window by its title bar stops working for apps with a
custom chrome (Electron, Chromium, and similar), while native AppKit apps keep
working.

`macosdragfix` lets you move any window by dragging its top band, with no
modifier keys, bypassing the broken gesture entirely.

## The bug

- Environment: macOS 27.x beta (for example build `26B5112a`), Apple Silicon.
- Symptom: windows do not move when you drag the title bar. Dragging internal
  tabs still works, so the input is reaching the OS.
- In the WindowServer log, on every drag attempt:
  `[SkyLight:packages] no client initiated window drag trait gesture to activate for mouse`
- It starts after remote or virtual input sessions (remote control, Universal
  Control, Chrome Remote Desktop) and stays until WindowServer restarts.
- It affects only apps that draw their own title bar: Electron/Chromium (Claude,
  Cursor, 1Password, Chrome, Spotify, ...). Native apps (Safari, Finder,
  System Settings, Terminal) are unaffected.

References: Apple Developer Forums thread 834488; Chromium issue 564169077.

## How it works

An event tap (`CGEventTap`) watches the mouse. When you press and drag inside a
window's title band, `macosdragfix` updates the window position through the
Accessibility API (`AXPosition`). That path skips the broken gesture, so the
window moves even where native drag is stuck. A plain click is passed through
to the app. Over buttons, tabs, and text fields the tool stays out of the way.

## Requirements

- macOS on Apple Silicon.
- Swift toolchain (Command Line Tools: `xcode-select --install`).

## Build

    swiftc -O -o macosdragfix macosdragfix.swift \
      -framework ApplicationServices -framework CoreGraphics

## Installation

1. The command is already on PATH via a symlink: `~/bin/macosdragfix` points at
   this project.
2. First launch and the Accessibility permission:

       macosdragfix

   Grant access in System Settings > Privacy & Security > Accessibility (enable
   the entry that appears), then relaunch. It should print
   `macosdragfix active ...`.
3. Start automatically at login (LaunchAgent):

       launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/it.m6i.macosdragfix.plist

   Stop: `launchctl bootout gui/$(id -u)/it.m6i.macosdragfix`
   Log: `/tmp/macosdragfix.log`

## Usage and options

    macosdragfix [--xoffset N] [--yoffset N] [--band N] [--mod ctrl+cmd]

| option        | short | default | meaning                                     |
|---------------|-------|---------|---------------------------------------------|
| `--xoffset N` | `-x`  | 10      | px to keep clear on the left and right      |
| `--yoffset N` | `-y`  | 8       | px to keep clear from the top edge          |
| `--band N`    | `-b`  | 34      | height of the title band from the top edge  |
| `--mod M`     | `-m`  | none    | require a modifier, for example `ctrl+cmd`  |

Environment fallback: `MACOSDRAGFIX_XOFFSET`, `MACOSDRAGFIX_YOFFSET`,
`MACOSDRAGFIX_BAND`, `MACOSDRAGFIX_MOD`.

### Active drag zone

Relative to the window's top-left corner:

- horizontal: from `xoffset` to `width - xoffset` (corners and side edges stay free for resize)
- vertical: from `yoffset` to `band` (the top strip stays free for resize)

To set options at login, add them to the `ProgramArguments` array in the plist
(see `it.m6i.macosdragfix.plist`).

## Tuning and tradeoffs

- It acts on the top band of every window. On native apps it still moves the
  window through AX, and drag events are consumed only while the window is moving.
- In Chrome the top band is the tab bar: empty space moves the window, and
  dragging a tab (an AX control) is left to the app. If the tool grabs too much,
  lower `band` or raise `xoffset`.
- Electron apps expose a sparse AX tree, so control detection is imperfect.
  Raise `band` when the draggable content starts lower.
- A 4 px threshold: a plain click always reaches the app. Only a real drag moves
  the window.

## Uninstall

    launchctl bootout gui/$(id -u)/it.m6i.macosdragfix 2>/dev/null
    rm -f ~/Library/LaunchAgents/it.m6i.macosdragfix.plist ~/bin/macosdragfix
    # then remove the entry in Settings > Privacy & Security > Accessibility

## Notes

- This is a workaround for a beta bug. The real fix is a corrected build from
  Apple, or leaving the beta program.
- Related tools on this system: `wm-fix` (reset WindowManager/surface without
  logging out), `gfx-reset` (GPU surface reset). Logging out is still the full
  WindowServer reset.
