# macosdragfix

Native workaround for the window-dragging bug in the macOS 27 (Golden Gate) beta.
On this beta, dragging a window by its title bar stops working for apps with a
custom chrome (Electron, Chromium, and similar). `macosdragfix` moves any window
by dragging its top band, with no modifier keys.

Run the commands below from this directory.

## Build

    swiftc -O -o macosdragfix macosdragfix.swift \
      -framework ApplicationServices -framework CoreGraphics
    codesign --force --sign - --identifier it.m6i.macosdragfix macosdragfix

Needs the Swift toolchain (`xcode-select --install`). After a rebuild, macOS
treats the binary as new: in System Settings > Privacy & Security > Accessibility,
remove the old `macosdragfix` row with the minus button and enable the new one.
Toggling the existing switch keeps the previous binary.

## Run

Start in the background:

    launchctl bootout gui/$(id -u)/it.m6i.macosdragfix 2>/dev/null; nohup ./macosdragfix >>/tmp/macosdragfix.log 2>&1 & disown

Stop:

    pkill -x macosdragfix

The start command also unloads the login agent, so two copies are not running.
Log: `/tmp/macosdragfix.log`. A successful start prints `macosdragfix active ...`.

The first launch must be allowed under Accessibility, then started again with
the command above.

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

In Chrome the top band is the tab bar. Each tab, the new-tab button, and the
traffic lights are read from the live accessibility frames, so the empty gap
that moves the window grows and shrinks with the number of tabs.

## Options

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

### Per-app exclusions

`~/.macosdragfix.yml` is created on first launch. The app name is a top-level
key. An exclusion is a rectangle in window points; a click there is left to the
app. `right` and `bottom` measure from the opposite edges. `band`, `xoffset`,
and `yoffset` override the globals for that app. Edits apply on the next click.

Buttons, text fields, and tabs that Accessibility exposes are left to the app
even when they are not listed. Chrome tabs are measured from the live tab
frames. 1Password's search bar is an exclusion in the file, because it often
is not exposed as a text field.

### Tuning

- It acts on the top band of every window. On native apps it still moves the
  window through AX, and drag events are consumed only while the window is moving.
- Electron apps expose a sparse AX tree, so control detection is imperfect.
  Raise `band` when the draggable content starts lower.
- A 4 px threshold: a plain click always reaches the app. Only a real drag moves
  the window.

## Start at login

    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/it.m6i.macosdragfix.plist

Stop: `launchctl bootout gui/$(id -u)/it.m6i.macosdragfix`

To set options at login, add them to the `ProgramArguments` array in
`it.m6i.macosdragfix.plist`. The background command above is the one that
keeps working after an ad-hoc rebuild; the login agent often does not receive
the Accessibility grant for the new binary.

## Uninstall

    launchctl bootout gui/$(id -u)/it.m6i.macosdragfix 2>/dev/null
    pkill -x macosdragfix
    rm -f ~/Library/LaunchAgents/it.m6i.macosdragfix.plist ~/bin/macosdragfix
    # then remove the entry in Settings > Privacy & Security > Accessibility

## Notes

- This is a workaround for a beta bug. The real fix is a corrected build from
  Apple, or leaving the beta program.
- Related tools on this system: `wm-fix` (reset WindowManager/surface without
  logging out), `gfx-reset` (GPU surface reset). Logging out is still the full
  WindowServer reset.
